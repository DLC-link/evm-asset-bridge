#!/usr/bin/env bash
#
# propose.sh — proposes one management action to a Safe wallet.
#
# It reads the envelope that a management script wrote in Safe mode. It asks
# the Safe contract for the transaction hash. It signs that hash with the
# proposer key. It posts the signed transaction to the Safe Transaction
# Service. The owners then confirm the transaction in the Safe user interface.
#
# The proposer needs no ETH. The proposer needs no owner rights. The proposer
# must be a registered delegate of the Safe. See script/manage/README.md for
# the registration step.
#
# Usage:
#   RPC_URL=https://... SIGNER="--account proposer" \
#     ./script/manage/safe/propose.sh deployments/.safe/BETH.11155111.pause.json
#
# Environment:
#   RPC_URL       required. The chain to read the Safe from.
#   SIGNER        required. Wallet flags for cast, such as --account proposer.
#                 Prefer --account or a hardware wallet. --private-key puts the
#                 key into the argument list of cast. A local `ps` then shows
#                 that key to every user on the machine.
#   SAFE_API_KEY  optional. Raises the rate limit. Get one at
#                 https://developer.safe.global.
#   NONCE         optional. Overrides the computed nonce. Use it to batch
#                 several proposals. The value must be a non-negative integer.
#   DRY_RUN=1     print the request and post nothing.
#
# The script deletes the envelope after the service accepts the proposal. A
# DRY_RUN run keeps the file.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

ENVELOPE="${1:-}"
[ -n "$ENVELOPE" ] || { echo "propose.sh: name an envelope file" >&2; exit 2; }
[ -f "$ENVELOPE" ] || { echo "propose.sh: no such file: $ENVELOPE" >&2; exit 2; }

for tool in jq curl cast; do
  command -v "$tool" >/dev/null || { echo "propose.sh: $tool is not installed" >&2; exit 2; }
done

[ -n "${RPC_URL:-}" ] || { echo "propose.sh: RPC_URL is not set" >&2; exit 2; }
[ -n "${SIGNER:-}" ] || [ -n "${DRY_RUN:-}" ] || \
  { echo "propose.sh: SIGNER is not set. Example: SIGNER=\"--account proposer\"" >&2; exit 2; }

# The operator can pin the nonce. NONCE later holds the value that the run
# uses. The script therefore keeps the override in its own variable.
NONCE_ENV="${NONCE:-}"
if [ -n "$NONCE_ENV" ]; then
  case "$NONCE_ENV" in
    *[!0-9]*)
      echo "propose.sh: NONCE must be a non-negative integer, not '$NONCE_ENV'" >&2
      exit 2
      ;;
  esac
  # 007 and 7 name the same slot. The body carries the nonce as a JSON string.
  # This loop therefore removes the leading zeros. A shell arithmetic expansion
  # would overflow on a very long value. This loop cannot.
  while [ "${#NONCE_ENV}" -gt 1 ] && [ "${NONCE_ENV:0:1}" = "0" ]; do
    NONCE_ENV="${NONCE_ENV:1}"
  done
fi

ZERO="0x0000000000000000000000000000000000000000"

# ---- read the envelope ------------------------------------------------------
# Every field must be present. A missing field would otherwise reach the
# service as the string "null". The service would then answer with a
# confusing message.
field() { # field <name>
  local v
  v=$(jq -r --arg k "$1" 'if has($k) and (.[$k] != null) then .[$k] | tostring else "" end' "$ENVELOPE")
  [ -n "$v" ] || { echo "propose.sh: the envelope has no '$1' field" >&2; exit 2; }
  printf '%s' "$v"
}

ENV_CHAIN=$(field chainId)
SAFE=$(field safe)
TO=$(field to)
VALUE=$(field value)
DATA=$(field data)
OPERATION=$(field operation)
ACTION=$(field action)

# ---- the chain --------------------------------------------------------------
# The envelope names its target chain. A mismatch means the RPC points
# somewhere else. The resulting hash would then be meaningless.
RPC_CHAIN=$(cast chain-id --rpc-url "$RPC_URL")
if [ "$RPC_CHAIN" != "$ENV_CHAIN" ]; then
  echo "propose.sh: the envelope is for chain $ENV_CHAIN but the RPC serves chain $RPC_CHAIN" >&2
  exit 2
fi

# The Safe service addresses a chain by its EIP-3770 short name.
case "$ENV_CHAIN" in
  1) SHORT="eth" ;;
  11155111) SHORT="sep" ;;
  8453) SHORT="base" ;;
  42161) SHORT="arb1" ;;
  137) SHORT="pol" ;;
  *)
    echo "propose.sh: no Safe service short name for chain $ENV_CHAIN" >&2
    echo "propose.sh: add it from https://github.com/ethereum-lists/chains" >&2
    exit 2
    ;;
esac

# ---- checksum ---------------------------------------------------------------
# The service rejects a lowercase address in the URL and in the body.
SAFE=$(cast to-check-sum-address "$SAFE")
TO=$(cast to-check-sum-address "$TO")

# ---- curl helpers -----------------------------------------------------------
# Every request travels on stdin as a curl config file. A local `ps` therefore
# cannot show the API key.
#
# A curl config file holds one directive per line. A newline inside a value
# would start a new directive. has_line_break refuses such a value.
has_line_break() { # has_line_break <value>
  case "$1" in
    *$'\n'* | *$'\r'*) return 0 ;;
    *) return 1 ;;
  esac
}

# This escapes backslash and double quote for curl's quoted config-file syntax.
cfg_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

AUTH_LINE=""
if [ -n "${SAFE_API_KEY:-}" ]; then
  if has_line_break "$SAFE_API_KEY"; then
    echo "propose.sh: SAFE_API_KEY holds a line break" >&2
    exit 2
  fi
  AUTH_LINE="header = \"Authorization: Bearer $(cfg_escape "$SAFE_API_KEY")\""
fi

# ---- read the Safe ----------------------------------------------------------
# The Safe contract holds the executed nonce. The service holds a separate
# queue of proposed transactions. Two proposals that take the same nonce
# exclude each other, and only one of them can ever run. This script therefore
# reads both sources and takes the first free slot above both.
ONCHAIN_NONCE=$(cast call "$SAFE" "nonce()(uint256)" --rpc-url "$RPC_URL")
ONCHAIN_NONCE="${ONCHAIN_NONCE%%$'\n'*}"
ONCHAIN_NONCE="${ONCHAIN_NONCE%% *}"

# The service offers no next-nonce endpoint. A list request sorted by
# descending nonce gives the highest queued nonce in its first result. An
# executed transaction stays in that list. The on-chain value therefore still
# wins when the queue holds no pending entry.
QUEUE_URL="https://api.safe.global/tx-service/$SHORT/api/v1/safes/$SAFE/multisig-transactions/?ordering=-nonce&limit=1"

# queue_nonce prints the next free nonce that the service queue allows. It
# prints 0 for an empty queue. It returns 1 when the request or the body fails.
queue_nonce() {
  local response status body
  response=$(curl -sS --connect-timeout 10 --max-time 30 -K - <<CFG || true
url = "$(cfg_escape "$QUEUE_URL")"
header = "Accept: application/json"
$AUTH_LINE
write-out = "\n%{http_code}"
CFG
)
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  [ "$status" = "200" ] || return 1
  printf '%s' "$body" | jq -e -r \
    'if (.results | type) != "array" then error("no results")
     elif (.results | length) == 0 then 0
     elif (.results[0].nonce | type) != "number" then error("no nonce")
     else .results[0].nonce + 1 end' 2>/dev/null
}

if [ -n "$NONCE_ENV" ]; then
  NONCE="$NONCE_ENV"
  NONCE_REASON="the NONCE override"
else
  NONCE="$ONCHAIN_NONCE"
  NONCE_REASON="the on-chain nonce"
  if QUEUED_NONCE=$(queue_nonce); then
    if [ "$QUEUED_NONCE" -gt "$NONCE" ]; then
      NONCE="$QUEUED_NONCE"
      NONCE_REASON="the highest queued nonce at the service"
    fi
  else
    # RULING: a service outage must not block every proposal. The Safe
    # interface shows a nonce conflict to the owners. The failure is
    # therefore recoverable.
    echo "propose.sh: ##########################################################" >&2
    echo "propose.sh: ## WARNING. The Safe service gave no queue answer.      ##" >&2
    echo "propose.sh: ## This run falls back to the on-chain nonce.           ##" >&2
    echo "propose.sh: ## A queued proposal can hold that nonce already.       ##" >&2
    echo "propose.sh: ## Open the Safe queue and check for a nonce conflict.  ##" >&2
    echo "propose.sh: ##########################################################" >&2
    NONCE_REASON="the on-chain nonce, after a failed queue request"
  fi
fi

# The Safe contract computes its own EIP-712 hash. This script therefore
# builds no EIP-712 encoding itself. safeTxGas, baseGas, gasPrice, gasToken
# and refundReceiver stay at their neutral values. No refund logic runs at
# gasPrice 0.
SAFE_TX_HASH=$(cast call "$SAFE" \
  "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)" \
  "$TO" "$VALUE" "$DATA" "$OPERATION" 0 0 0 "$ZERO" "$ZERO" "$NONCE" \
  --rpc-url "$RPC_URL")
SAFE_TX_HASH="${SAFE_TX_HASH%%$'\n'*}"
SAFE_TX_HASH="${SAFE_TX_HASH%% *}"

# An envelope file name carries no arguments. A later run of the same action
# overwrites the file. The operator therefore reads the target and the calldata
# here, before the signature exists.
echo "propose.sh: action $ACTION, safe $SAFE"
echo "propose.sh: to $TO"
echo "propose.sh: value $VALUE, operation $OPERATION"
echo "propose.sh: data $DATA"
echo "propose.sh: nonce $NONCE from $NONCE_REASON. The on-chain nonce is $ONCHAIN_NONCE"
echo "propose.sh: safeTxHash $SAFE_TX_HASH"

# ---- sign -------------------------------------------------------------------
# --no-hash is mandatory. Without it, cast adds the EIP-191 prefix. The
# signature then recovers to the wrong address. The service then answers
# "Signature does not match sender".
#
# DRY_RUN never touches the signing key. A keystore signer could otherwise
# prompt for a password during a run that sends nothing.
if [ -n "${DRY_RUN:-}" ]; then
  SIGNATURE="DRY_RUN-NOT-SIGNED"
  SENDER="$ZERO"
else
  # shellcheck disable=SC2086
  SIGNATURE=$(cast wallet sign --no-hash $SIGNER "$SAFE_TX_HASH")
  # shellcheck disable=SC2086
  SENDER=$(cast wallet address $SIGNER)
  SENDER=$(cast to-check-sum-address "$SENDER")
fi

# ---- build the body ---------------------------------------------------------
# A number that can exceed 2^53 travels as a JSON string. A JSON number loses
# precision past 2^53. operation stays a plain number. operation never
# exceeds 1. jq writes the file. No shell quoting therefore reaches the body.
BODY="$(mktemp)"
trap 'rm -f "$BODY"' EXIT
jq -n \
  --arg to "$TO" --arg value "$VALUE" --arg data "$DATA" \
  --argjson operation "$OPERATION" \
  --arg nonce "$NONCE" --arg hash "$SAFE_TX_HASH" \
  --arg sender "$SENDER" --arg signature "$SIGNATURE" \
  --arg origin "$ACTION" --arg zero "$ZERO" \
  '{to: $to, value: $value, data: $data, operation: $operation,
    safeTxGas: "0", baseGas: "0", gasPrice: "0",
    gasToken: $zero, refundReceiver: $zero, nonce: $nonce,
    contractTransactionHash: $hash, sender: $sender, signature: $signature,
    origin: ({name: "evm-asset-bridge", action: $origin} | tojson)}' \
  >"$BODY"

URL="https://api.safe.global/tx-service/$SHORT/api/v2/safes/$SAFE/multisig-transactions/"

if [ -n "${DRY_RUN:-}" ]; then
  echo "propose.sh: DRY_RUN, sending nothing"
  echo "POST $URL"
  cat "$BODY"
  exit 0
fi

# ---- post -------------------------------------------------------------------
# write-out appends the status code. The last line of the answer is therefore
# the status code.
#
# The body is a large, multi-line JSON document. It therefore travels by file
# reference on the `data-binary` line. curl reads the file itself. The config
# text on stdin never carries the body bytes.
RESPONSE=$(curl -sS --connect-timeout 10 --max-time 60 -K - <<CFG || true
url = "$(cfg_escape "$URL")"
request = "POST"
header = "Content-Type: application/json"
$AUTH_LINE
data-binary = "@$(cfg_escape "$BODY")"
write-out = "\n%{http_code}"
CFG
)

STATUS="${RESPONSE##*$'\n'}"
SERVICE_REPLY="${RESPONSE%$'\n'*}"

# The service answers a good proposal with status 201 and an empty body. The
# status is therefore the only signal. This script never parses the body.
if [ "$STATUS" != "201" ]; then
  echo "propose.sh: the Safe service answered $STATUS" >&2
  echo "$SERVICE_REPLY" >&2
  exit 1
fi

echo "propose.sh: proposed. safeTxHash $SAFE_TX_HASH"
echo "propose.sh: owners confirm at https://app.safe.global/transactions/queue?safe=$SHORT:$SAFE"

# The envelope file name carries no arguments, so a second run of the same
# action replaces the first file. The proposed transaction lives in the Safe
# queue at this point, so the file has no further use. The delete stops a
# later run from replacing an envelope that nobody proposed yet.
rm -f "$ENVELOPE"
echo "propose.sh: removed $ENVELOPE"
