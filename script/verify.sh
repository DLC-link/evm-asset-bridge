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
#   CONTRACT                    optional. One of implementation, proxy, proxyAdmin.
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

# CONTRACT limits the run to one role. An unlisted role is likely a typo.
if [ -n "$ONLY" ]; then
  case "$ONLY" in
    implementation|proxy|proxyAdmin) ;;
    *)
      echo "verify.sh: CONTRACT must be implementation, proxy, or proxyAdmin. Got '$ONLY'." >&2
      exit 2
      ;;
  esac
fi

for tool in jq curl; do
  command -v "$tool" >/dev/null || { echo "verify.sh: $tool is not installed" >&2; exit 2; }
done

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

echo "verify.sh: deployment $NAME, chain $CHAIN, key from $KEY_VAR"
echo "verify.sh: explorer $HOST"

# ---- which roles ------------------------------------------------------------
if [ -n "$ONLY" ]; then
  ROLES="$ONLY"
else
  ROLES="implementation proxy proxyAdmin"
fi

# The proxy record must exist. Its absence means the whole deployment is absent.
PROXY_RECORD="deployments/$NAME.proxy.$CHAIN.json"
if [ ! -f "$PROXY_RECORD" ]; then
  echo "verify.sh: no record at $PROXY_RECORD" >&2
  echo "verify.sh: run 'make record DEPLOYMENT=$NAME' after a deploy" >&2
  exit 1
fi

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

  ADDRESS=$(jq -r .address "$RECORD")
  CONTRACT_NAME=$(jq -r .contractName "$RECORD")
  SOURCE_PATH=$(jq -r .sourcePath "$RECORD")
  ARGS=$(jq -r .encodedConstructorArgs "$RECORD")
  SOLC_HASH=$(jq -r .solcInputHash "$RECORD")
  COMPILER=$(jq -r .compiler.version "$RECORD")
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
  if [ "$(printf '%s' "$ABI_RESPONSE" | jq -r '.status // "0"')" = "1" ]; then
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

  if [ "$(printf '%s' "$SUBMIT" | jq -r '.status // "0"')" != "1" ]; then
    echo "  FAIL $ROLE: $(printf '%s' "$SUBMIT" | jq -r '.result // .message // .')"
    FAILED=$((FAILED + 1))
    continue
  fi

  GUID=$(printf '%s' "$SUBMIT" | jq -r .result)

  # ---- poll -----------------------------------------------------------------
  # TEXT holds the poll's result field. The loop keeps polling while TEXT is
  # empty or "Pending in queue". RESULT stays empty until the explorer
  # concludes, pass or fail, and RESULT_STATUS is captured at that moment.
  RESULT=""
  RESULT_STATUS=""
  for _ in $(seq 1 30); do
    sleep 5
    POLL=$(curl_get "$HOST$(sep "$HOST")module=contract&action=checkverifystatus&guid=$GUID&apikey=$KEY" 30)
    TEXT=$(printf '%s' "$POLL" | jq -r '.result // ""')
    case "$TEXT" in
      "Pending in queue"|"") continue ;;
      *)
        RESULT="$TEXT"
        RESULT_STATUS=$(printf '%s' "$POLL" | jq -r '.status // "0"')
        break
        ;;
    esac
  done

  # An empty RESULT means every poll timed out or pended. That counts as a
  # failure. The explorer's last "still pending" reply can still carry status "1".
  if [ -z "$RESULT" ]; then
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
