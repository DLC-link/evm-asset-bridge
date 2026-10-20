#!/usr/bin/env bash
#
# verify.sh — submits the source of every recorded contract to a block explorer.
#
# It reads the records that script/record.sh wrote. It submits the stored
# compiler input, so the explorer compiles the exact input that produced the
# deployed bytes and reaches an exact match. It needs no local build.
#
# It skips a contract that already has verified source, so it is safe to repeat.
#
# Usage:
#   DEPLOYMENT=BETH CHAIN_ID=11155111 ./script/verify.sh
#
# Environment:
#   DEPLOYMENT                  required. The deployment name.
#   CHAIN_ID                    required. Picks the record files.
#   ETHERSCAN_API_KEY_<id>      the key for that chain. Read first.
#   ETHERSCAN_API_KEY           the fallback key.
#   VERIFIER_URL_<id>           that chain's explorer host.
#   VERIFIER_URL                the fallback host. Defaults to Etherscan V2.
#   CONTRACT                    optional. One recorded role, such as proxy.
#   DRY_RUN=1                   print the request and send nothing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NAME="${DEPLOYMENT:-}"
CHAIN="${CHAIN_ID:-}"
ONLY="${CONTRACT:-}"
DRY="${DRY_RUN:-}"

[ -n "$NAME" ]  || { echo "verify.sh: DEPLOYMENT is not set. Example: DEPLOYMENT=BETH" >&2; exit 2; }
[ -n "$CHAIN" ] || { echo "verify.sh: CHAIN_ID is not set. Example: CHAIN_ID=11155111" >&2; exit 2; }

for tool in jq curl; do
  command -v "$tool" >/dev/null || { echo "verify.sh: $tool is not installed" >&2; exit 2; }
done

# The record schema this script reads. script/record.sh stamps the same number
# on every record it writes. A record with any other version stops its role.
READS_SCHEMA_VERSION=2

# A curl config file holds one directive per line, so a newline inside a value
# would start a new directive. cfg_escape cannot escape that, and the values
# below come from a record file and from the explorer. So the script refuses
# such a value instead.
has_line_break() { # has_line_break <value>
  case "$1" in
    *$'\n'* | *$'\r'*) return 0 ;;
    *) return 1 ;;
  esac
}

is_solc_input_hash() { # is_solc_input_hash <value>
  case "$1" in
    *[!0-9a-f]*) return 1 ;;
  esac
  [ "${#1}" -eq 16 ]
}

# ---- the API key ------------------------------------------------------------
# The per-chain variable wins. The script prints which one it used, so the
# fallback is never silent. It never prints the value.
KEY_VAR="ETHERSCAN_API_KEY_$CHAIN"
KEY=$(printenv "$KEY_VAR" || true)
if [ -z "$KEY" ]; then
  KEY_VAR="ETHERSCAN_API_KEY"
  KEY=$(printenv "$KEY_VAR" || true)
fi
if [ -z "$KEY" ]; then
  echo "verify.sh: no API key. Set ETHERSCAN_API_KEY_$CHAIN, or ETHERSCAN_API_KEY." >&2
  exit 1
fi

# ---- the explorer host ------------------------------------------------------
HOST=$(printenv "VERIFIER_URL_$CHAIN" || true)
[ -n "$HOST" ] || HOST="${VERIFIER_URL:-}"
[ -n "$HOST" ] || HOST="https://api.etherscan.io/v2/api?chainid=$CHAIN"

if has_line_break "$HOST$KEY$CHAIN"; then
  echo "verify.sh: the host, the key, or the chain id holds a line break" >&2
  exit 2
fi

echo "verify.sh: deployment $NAME, chain $CHAIN, key from $KEY_VAR"
echo "verify.sh: explorer $HOST"

# ---- which roles ------------------------------------------------------------
# The role is a free label that the deploy script chooses. A fixed list would
# miss a standalone contract, such as a timelock. So the script reads the roles
# from the record files on disk.
ALL_ROLES=""
for RECORD_FILE in "deployments/$NAME."*".$CHAIN.json"; do
  [ -e "$RECORD_FILE" ] || continue
  ROLE_NAME=$(basename "$RECORD_FILE" ".$CHAIN.json")
  ALL_ROLES="$ALL_ROLES ${ROLE_NAME#"$NAME."}"
done
ALL_ROLES="${ALL_ROLES# }"

# One record is enough. No record means the whole deployment is absent.
if [ -z "$ALL_ROLES" ]; then
  echo "verify.sh: no record at deployments/$NAME.<role>.$CHAIN.json" >&2
  echo "verify.sh: run 'make record DEPLOYMENT=$NAME' after a deploy" >&2
  exit 1
fi

# CONTRACT limits the run to one role. An undiscovered role is a typo, or a
# deploy that nobody recorded.
if [ -n "$ONLY" ]; then
  case " $ALL_ROLES " in
    *" $ONLY "*) ROLES="$ONLY" ;;
    *)
      echo "verify.sh: CONTRACT must name a recorded role. Got '$ONLY'." >&2
      echo "verify.sh: this deployment records: $ALL_ROLES" >&2
      exit 2
      ;;
  esac
else
  ROLES="$ALL_ROLES"
fi

echo "verify.sh: roles $ROLES"

# `?` or `&` depends on whether the host already carries a query string.
sep() { case "$1" in *\?*) printf '&' ;; *) printf '?' ;; esac; }

# This escapes backslash and double quote for curl's quoted config-file syntax.
cfg_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# curl_get reads the URL from stdin, not argv, so a local `ps` cannot show the key.
curl_get() { # curl_get <url> <max-time>
  curl -sS --connect-timeout 10 --max-time "$2" -K - <<CFG || true
url = "$(cfg_escape "$1")"
CFG
}

# json_field prints one field of a JSON body. It prints the default instead when
# the body is not JSON, or when the field is absent or null.
#
# An explorer can answer with an HTML error page or an empty body. `jq` then
# exits non-zero, and inside an assignment that status stops the whole script.
# So every read of a reply and of a record goes through this function.
json_field() { # json_field <text> <filter> <default>
  local out
  out=$(printf '%s' "$1" | jq -r "$2 // empty" 2>/dev/null || true)
  if [ -n "$out" ]; then printf '%s' "$out"; else printf '%s' "$3"; fi
}

# explorer_reason prints why one call failed. A JSON reply names the reason. Any
# other body, such as a rate-limit page, gives its first 200 characters.
explorer_reason() { # explorer_reason <text>
  local reason
  reason=$(json_field "$1" '.result // .message' "")
  if [ -n "$reason" ]; then
    printf '%s' "$reason"
  elif [ -z "$1" ]; then
    printf '%s' "the explorer sent an empty reply"
  else
    printf 'the explorer sent no JSON: %s' "$(printf '%s' "$1" | tr '\n\r\t' '   ' | cut -c1-200)"
  fi
}

FAILED=0

for ROLE in $ROLES; do
  RECORD="deployments/$NAME.$ROLE.$CHAIN.json"
  if [ ! -f "$RECORD" ]; then
    # A missing record means this role was never recorded. That is a
    # failure, not a skip, because nothing was checked or verified.
    echo "  FAIL $ROLE: no record at $RECORD"
    FAILED=$((FAILED + 1))
    continue
  fi

  # One read proves the record parses. A separate `jq` call per field would stop
  # the whole run on a truncated file, part way through the roles.
  if ! RECORD_JSON=$(jq -c . "$RECORD" 2>/dev/null); then
    echo "  FAIL $ROLE: $RECORD holds no valid JSON"
    FAILED=$((FAILED + 1))
    continue
  fi

  # The writer stamps every record with a schema version. A version this script
  # does not know means the fields below may have changed meaning.
  SCHEMA=$(json_field "$RECORD_JSON" .schemaVersion "")
  if [ "$SCHEMA" != "$READS_SCHEMA_VERSION" ]; then
    echo "  FAIL $ROLE: $RECORD has schemaVersion '$SCHEMA'; this script reads $READS_SCHEMA_VERSION"
    FAILED=$((FAILED + 1))
    continue
  fi

  ADDRESS=$(json_field "$RECORD_JSON" .address "")
  CONTRACT_NAME=$(json_field "$RECORD_JSON" .contractName "")
  SOURCE_PATH=$(json_field "$RECORD_JSON" .sourcePath "")
  ARGS=$(json_field "$RECORD_JSON" .encodedConstructorArgs "")
  SOLC_HASH=$(json_field "$RECORD_JSON" .solcInputHash "")
  COMPILER=$(json_field "$RECORD_JSON" .compiler.version "")

  # The explorer needs all six. `jq -r` prints the word "null" for an absent
  # field, and a request carrying that word gets a confusing rejection.
  MISSING=""
  [ -n "$ADDRESS" ] || MISSING="$MISSING address"
  [ -n "$CONTRACT_NAME" ] || MISSING="$MISSING contractName"
  [ -n "$SOURCE_PATH" ] || MISSING="$MISSING sourcePath"
  [ -n "$ARGS" ] || MISSING="$MISSING encodedConstructorArgs"
  [ -n "$SOLC_HASH" ] || MISSING="$MISSING solcInputHash"
  [ -n "$COMPILER" ] || MISSING="$MISSING compiler.version"
  if [ -n "$MISSING" ]; then
    echo "  FAIL $ROLE: $RECORD has no$MISSING"
    FAILED=$((FAILED + 1))
    continue
  fi

  if has_line_break "$ADDRESS$CONTRACT_NAME$SOURCE_PATH$ARGS$SOLC_HASH$COMPILER"; then
    echo "  FAIL $ROLE: $RECORD holds a line break in a field this script sends"
    FAILED=$((FAILED + 1))
    continue
  fi

  # The hash becomes part of the path this script uploads. A crafted record
  # could hold "../evil" and send any .json file in the repo to the explorer,
  # so only the exact format record.sh writes passes.
  if ! is_solc_input_hash "$SOLC_HASH"; then
    echo "  FAIL $ROLE: $RECORD holds a solcInputHash that is not 16 hex characters"
    FAILED=$((FAILED + 1))
    continue
  fi

  SOLC_INPUT="deployments/solcInputs/$SOLC_HASH.json"
  FQN="$SOURCE_PATH:$CONTRACT_NAME"

  if [ ! -f "$SOLC_INPUT" ]; then
    echo "  FAIL $ROLE: no compiler input at $SOLC_INPUT"
    FAILED=$((FAILED + 1))
    continue
  fi

  # Etherscan wants the arguments with no 0x prefix.
  ARGS_NO_PREFIX="${ARGS#0x}"

  if [ -n "$DRY" ]; then
    echo "  DRY  $ROLE $ADDRESS"
    echo "       contractname=$FQN"
    echo "       compilerversion=v$COMPILER"
    echo "       codeformat=solidity-standard-json-input"
    echo "       licenseType=3"
    echo "       constructorArguements=$ARGS_NO_PREFIX"
    echo "       sourceCode=@$SOLC_INPUT ($(wc -c <"$SOLC_INPUT" | tr -d ' ') bytes)"
    continue
  fi

  # ---- skip a contract that already has verified source ---------------------
  ABI_RESPONSE=$(curl_get "$HOST$(sep "$HOST")module=contract&action=getabi&address=$ADDRESS&apikey=$KEY" 30)
  # A reply this script cannot read is not proof of verified source. The role
  # goes on to the submit step, which reports a real reason when it fails.
  if [ "$(json_field "$ABI_RESPONSE" .status 0)" = "1" ]; then
    echo "  SKIP $ROLE $ADDRESS: already verified"
    continue
  fi

  echo "  SEND $ROLE $ADDRESS ($FQN)"
  # The URL and every field, including the key, arrive on stdin. Argv never
  # carries them, so a local `ps` cannot show the key. The upload is large,
  # so this call gets a longer budget than the two small GET calls.
  SUBMIT=$(curl -sS --connect-timeout 10 --max-time 180 -K - <<CFG || true
url = "$(cfg_escape "$HOST")"
request = "POST"
data-urlencode = "apikey=$(cfg_escape "$KEY")"
data-urlencode = "chainid=$(cfg_escape "$CHAIN")"
data-urlencode = "module=contract"
data-urlencode = "action=verifysourcecode"
data-urlencode = "contractaddress=$(cfg_escape "$ADDRESS")"
data-urlencode = "sourceCode@$(cfg_escape "$SOLC_INPUT")"
data-urlencode = "codeformat=solidity-standard-json-input"
data-urlencode = "contractname=$(cfg_escape "$FQN")"
data-urlencode = "compilerversion=v$(cfg_escape "$COMPILER")"
data-urlencode = "constructorArguements=$(cfg_escape "$ARGS_NO_PREFIX")"
data-urlencode = "licenseType=3"
CFG
)

  if [ "$(json_field "$SUBMIT" .status 0)" != "1" ]; then
    echo "  FAIL $ROLE: $(explorer_reason "$SUBMIT")"
    FAILED=$((FAILED + 1))
    continue
  fi

  # The explorer answers a good submit with a guid. The poll step needs it.
  GUID=$(json_field "$SUBMIT" .result "")
  if [ -z "$GUID" ]; then
    echo "  FAIL $ROLE: the explorer accepted the submit but sent no guid"
    FAILED=$((FAILED + 1))
    continue
  fi
  if has_line_break "$GUID"; then
    echo "  FAIL $ROLE: the explorer sent a guid holding a line break"
    FAILED=$((FAILED + 1))
    continue
  fi

  # ---- poll -----------------------------------------------------------------
  # TEXT holds the poll's result field. The loop keeps polling while TEXT is
  # empty or "Pending in queue". RESULT stays empty until the explorer
  # concludes, pass or fail, and RESULT_STATUS is captured at that moment.
  # POLL_NOTE holds the last reply the script could not read, so a timeout can
  # say why.
  RESULT=""
  RESULT_STATUS=""
  POLL_NOTE=""
  for _ in $(seq 1 30); do
    sleep 5
    POLL=$(curl_get "$HOST$(sep "$HOST")module=contract&action=checkverifystatus&guid=$GUID&apikey=$KEY" 30)
    TEXT=$(json_field "$POLL" .result "")
    if [ -z "$TEXT" ]; then
      # An empty body, or a body this script cannot read, is not a verdict. The
      # loop keeps polling and keeps the reason for the timeout message.
      POLL_NOTE=$(explorer_reason "$POLL")
      continue
    fi
    case "$TEXT" in
      "Pending in queue")
        POLL_NOTE=""
        continue
        ;;
      *)
        RESULT="$TEXT"
        RESULT_STATUS=$(json_field "$POLL" .status 0)
        break
        ;;
    esac
  done

  # An empty RESULT means every poll timed out or pended. That counts as a
  # failure. The explorer's last "still pending" reply can still carry status "1".
  if [ -z "$RESULT" ] && [ -n "$POLL_NOTE" ]; then
    echo "  FAIL $ROLE $ADDRESS: timed out after 150 seconds. $POLL_NOTE"
    FAILED=$((FAILED + 1))
  elif [ -z "$RESULT" ]; then
    echo "  FAIL $ROLE $ADDRESS: timed out after 150 seconds"
    FAILED=$((FAILED + 1))
  elif [ "$RESULT_STATUS" = "1" ]; then
    echo "  OK   $ROLE $ADDRESS: $RESULT"
  else
    echo "  FAIL $ROLE $ADDRESS: $RESULT"
    FAILED=$((FAILED + 1))
  fi

  # Stay inside the explorer's rate limit.
  sleep 0.5
done

if [ "$FAILED" -gt 0 ]; then
  echo "verify.sh: $FAILED contract(s) failed"
  exit 1
fi
echo "verify.sh: done"
