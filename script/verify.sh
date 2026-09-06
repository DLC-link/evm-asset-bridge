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
#   CONTRACT                    optional. One role only.
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

FAILED=0

for ROLE in $ROLES; do
  RECORD="deployments/$NAME.$ROLE.$CHAIN.json"
  if [ ! -f "$RECORD" ]; then
    echo "  SKIP $ROLE: no record at $RECORD"
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
  ABI_RESPONSE=$(curl -sS "$HOST$(sep "$HOST")module=contract&action=getabi&address=$ADDRESS&apikey=$KEY" || true)
  if [ "$(printf '%s' "$ABI_RESPONSE" | jq -r '.status // "0"')" = "1" ]; then
    echo "  SKIP $ROLE $ADDRESS: already verified"
    continue
  fi

  echo "  SEND $ROLE $ADDRESS ($FQN)"
  SUBMIT=$(curl -sS -X POST "$HOST" \
    --data-urlencode "apikey=$KEY" \
    --data-urlencode "chainid=$CHAIN" \
    --data-urlencode "module=contract" \
    --data-urlencode "action=verifysourcecode" \
    --data-urlencode "contractaddress=$ADDRESS" \
    --data-urlencode "sourceCode@$SOLC_INPUT" \
    --data-urlencode "codeformat=solidity-standard-json-input" \
    --data-urlencode "contractname=$FQN" \
    --data-urlencode "compilerversion=v$COMPILER" \
    --data-urlencode "constructorArguements=$ARGS_NO_PREFIX" \
    --data-urlencode "licenseType=3")

  if [ "$(printf '%s' "$SUBMIT" | jq -r '.status // "0"')" != "1" ]; then
    echo "  FAIL $ROLE: $(printf '%s' "$SUBMIT" | jq -r '.result // .message // .')"
    FAILED=$((FAILED + 1))
    continue
  fi

  GUID=$(printf '%s' "$SUBMIT" | jq -r .result)

  # ---- poll -----------------------------------------------------------------
  RESULT=""
  for _ in $(seq 1 30); do
    sleep 5
    STATUS=$(curl -sS "$HOST$(sep "$HOST")module=contract&action=checkverifystatus&guid=$GUID&apikey=$KEY" || true)
    TEXT=$(printf '%s' "$STATUS" | jq -r '.result // ""')
    case "$TEXT" in
      "Pending in queue"|"") continue ;;
      *) RESULT="$TEXT"; break ;;
    esac
  done

  if [ "$(printf '%s' "$STATUS" | jq -r '.status // "0"')" = "1" ]; then
    echo "  OK   $ROLE $ADDRESS: $RESULT"
  else
    echo "  FAIL $ROLE $ADDRESS: ${RESULT:-timed out after 150 seconds}"
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
