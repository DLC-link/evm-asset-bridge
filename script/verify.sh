#!/usr/bin/env bash
#
# verify.sh — submits the source of every recorded contract to a block explorer.
#
# It reads the records that script/record.sh wrote. It then runs
# `forge verify-contract` once per record.
#
# forge does six jobs this script used to do by hand. It picks the explorer
# host, it reads the API key, it skips a contract that already has verified
# source, it maps the licence, it sends the compiler version, and it waits for
# the result.
#
# forge compiles the source again on this machine. The local build must
# therefore match the deployed bytes. The script compares each record's
# gitCommit against HEAD, and it stops on a mismatch.
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
#   VERIFIER_URL                the fallback host. forge picks one otherwise.
#   CONTRACT                    optional. One recorded role, such as proxy.
#   ALLOW_COMMIT_MISMATCH=1     skip the commit check. Read the guard below.
#   DRY_RUN=1                   print the command and run nothing.
set -euo pipefail

export PATH="$HOME/.foundry/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NAME="${DEPLOYMENT:-}"
CHAIN="${CHAIN_ID:-}"
ONLY="${CONTRACT:-}"
DRY="${DRY_RUN:-}"
ALLOW_MISMATCH="${ALLOW_COMMIT_MISMATCH:-}"

[ -n "$NAME" ]  || { echo "verify.sh: DEPLOYMENT is not set. Example: DEPLOYMENT=BETH" >&2; exit 2; }
[ -n "$CHAIN" ] || { echo "verify.sh: CHAIN_ID is not set. Example: CHAIN_ID=11155111" >&2; exit 2; }

for tool in jq forge git; do
  command -v "$tool" >/dev/null || { echo "verify.sh: $tool is not installed" >&2; exit 2; }
done

# The record schema this script reads. script/record.sh stamps the same number
# on every record it writes. A record with any other version stops its role.
READS_SCHEMA_VERSION=1

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
# An empty host leaves the choice to forge, which knows every Etherscan chain.
HOST=$(printenv "VERIFIER_URL_$CHAIN" || true)
[ -n "$HOST" ] || HOST="${VERIFIER_URL:-}"

echo "verify.sh: deployment $NAME, chain $CHAIN, key from $KEY_VAR"
if [ -n "$HOST" ]; then
  echo "verify.sh: explorer $HOST"
else
  echo "verify.sh: explorer chosen by forge for chain $CHAIN"
fi

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

# ---- the build guard --------------------------------------------------------
# forge compiles the source again before it submits. A stale out/ therefore
# submits source that never produced the deployed bytes. The explorer either
# rejects it or publishes the wrong code, and nothing warns the operator. So
# every record must name the commit that is checked out now.
HEAD_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || true)
if [ -z "$ALLOW_MISMATCH" ]; then
  for ROLE in $ROLES; do
    RECORD="deployments/$NAME.$ROLE.$CHAIN.json"
    [ -f "$RECORD" ] || continue
    RECORD_COMMIT=$(jq -r '.gitCommit // empty' "$RECORD" 2>/dev/null || true)
    # An unreadable record names no commit. The loop below reports why, so the
    # guard leaves it alone. The loop also refuses a record with no gitCommit,
    # so no record reaches forge unchecked.
    [ -n "$RECORD_COMMIT" ] || continue
    [ "$RECORD_COMMIT" != "$HEAD_COMMIT" ] || continue
    {
      echo "verify.sh: STOP. This checkout is not the deployed commit."
      echo "verify.sh: $RECORD names commit '$RECORD_COMMIT'."
      echo "verify.sh: HEAD is '$HEAD_COMMIT'."
      echo "verify.sh: forge compiles the source again before it submits."
      echo "verify.sh: another commit compiles other bytes, and the result is wrong."
      echo "verify.sh: go back to the deployed commit, build, and verify:"
      echo
      echo "    git checkout $RECORD_COMMIT"
      echo "    forge build"
      echo "    make verify DEPLOYMENT=$NAME CHAIN_ID=$CHAIN"
      echo
      echo "verify.sh: set ALLOW_COMMIT_MISMATCH=1 if you know the build matches."
    } >&2
    exit 1
  done
fi

# json_field prints one field of a JSON record. It prints the default instead
# when the field is absent or null.
#
# `jq -r` prints the word "null" for an absent field, and a request carrying
# that word gets a confusing rejection. So every read of a record goes through
# this function.
json_field() { # json_field <text> <filter> <default>
  local out
  out=$(printf '%s' "$1" | jq -r "$2 // empty" 2>/dev/null || true)
  if [ -n "$out" ]; then printf '%s' "$out"; else printf '%s' "$3"; fi
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
  COMPILER=$(json_field "$RECORD_JSON" .compiler.version "")
  COMMIT=$(json_field "$RECORD_JSON" .gitCommit "")

  MISSING=""
  [ -n "$ADDRESS" ] || MISSING="$MISSING address"
  [ -n "$CONTRACT_NAME" ] || MISSING="$MISSING contractName"
  [ -n "$SOURCE_PATH" ] || MISSING="$MISSING sourcePath"
  [ -n "$ARGS" ] || MISSING="$MISSING encodedConstructorArgs"
  [ -n "$COMPILER" ] || MISSING="$MISSING compiler.version"
  # The build guard above reads gitCommit. A record without it would reach
  # forge unchecked, so it fails here instead.
  [ -n "$COMMIT" ] || MISSING="$MISSING gitCommit"
  if [ -n "$MISSING" ]; then
    echo "  FAIL $ROLE: $RECORD has no$MISSING"
    FAILED=$((FAILED + 1))
    continue
  fi

  FQN="$SOURCE_PATH:$CONTRACT_NAME"

  # The record's own encoded arguments go to forge. `--guess-constructor-args`
  # would not work here, because the ProxyAdmin has no transaction of its own.
  # The proxy constructor created it.
  FORGE_ARGS=(--chain "$CHAIN" --compiler-version "v$COMPILER"
    --constructor-args "$ARGS" --watch)
  [ -z "$HOST" ] || FORGE_ARGS+=(--verifier-url "$HOST")
  FORGE_ARGS+=("$ADDRESS" "$FQN")

  if [ -n "$DRY" ]; then
    # The printed line names the key variable, never the key. An operator can
    # copy the line and run it.
    echo "  DRY  $ROLE $ADDRESS"
    echo "       ETHERSCAN_API_KEY=\"\$$KEY_VAR\" forge verify-contract ${FORGE_ARGS[*]}"
    continue
  fi

  echo "  SEND $ROLE $ADDRESS ($FQN)"
  # The key travels in the environment, so argv never holds it. A local `ps`
  # therefore cannot show it.
  if ETHERSCAN_API_KEY="$KEY" forge verify-contract "${FORGE_ARGS[@]}"; then
    echo "  OK   $ROLE $ADDRESS"
  else
    echo "  FAIL $ROLE $ADDRESS: forge verify-contract failed"
    FAILED=$((FAILED + 1))
  fi
done

if [ "$FAILED" -gt 0 ]; then
  echo "verify.sh: $FAILED contract(s) failed"
  exit 1
fi
echo "verify.sh: done"
