#!/usr/bin/env bash
#
# propose.t.sh — drives script/manage/safe/propose.sh offline.
#
# A fake curl answers the Safe service. A fake cast answers the chain. Both
# live in test/tooling/fake. Both reach the script through PATH.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
FAILURES=0
. test/tooling/lib.sh

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PATH="$ROOT/test/tooling/fake:$HOME/.foundry/bin:$PATH"
export REAL_CAST="$HOME/.foundry/bin/cast"
export RPC_URL="http://127.0.0.1:0"
export SIGNER="--account proposer"
export FAKE_CURL_DIR="$WORK"
export FAKE_CURL_LOG="$WORK/requests.log"

# A valid envelope. Each test copies it and edits one field. "to" is
# lowercase on purpose. This makes the script's own checksum call
# load-bearing.
ENVELOPE="$WORK/envelope.json"
cat >"$ENVELOPE" <<'JSON'
{
  "deployment": "BETH",
  "chainId": 11155111,
  "action": "setThreshold",
  "safe": "0xaAafDA111EAf5a49359e5C15B9B58DED7313f979",
  "to": "0xc2dbb9af52da4ba877c13fdf55d128da76aee950",
  "value": "0",
  "data": "0x960bfe0400000000000000000000000000000000000000000000000000000000000003",
  "operation": 0
}
JSON

echo "== a good envelope reaches the service =="
printf '\n201' >"$WORK/post.txt"
# A lowercase FAKE_SIGNER_ADDRESS also makes the sender checksum call
# load-bearing. The envelope's lowercase "to" does the same for TO.
OUT=$(FAKE_SIGNER_ADDRESS="0x7038f8a64ce8f879705a48e962b55d56aecd60d8" \
  ./script/manage/safe/propose.sh "$ENVELOPE" 2>&1)
check "exit status" "$?" "0"
contains "reports the hash" "$OUT" "0x1111111111111111111111111111111111111111111111111111111111111111"
REQ=$(cat "$FAKE_CURL_LOG")
contains "posts to the v2 endpoint" "$REQ" "/api/v2/safes/"
contains "uses the sepolia short name" "$REQ" "/tx-service/sep/"
contains "sends the checksummed safe in the url" "$REQ" "0xaAafDA111EAf5a49359e5C15B9B58DED7313f979"
contains "sends the checksummed to address" "$REQ" "0xc2DBb9AF52DA4BA877c13Fdf55d128dA76AEE950"
contains "sends the nonce as a string" "$REQ" '"nonce": "7"'
contains "sends the contract transaction hash" "$REQ" '"contractTransactionHash": "0x1111'
contains "sends the signature" "$REQ" \
  "0x222222222222222222222222222222222222222222222222222222222222222233333333333333333333333333333333333333333333333333333333333333331b"
contains "sends the checksummed sender" "$REQ" "0x7038f8a64cE8F879705A48e962B55d56aEcd60D8"

echo "== a non-201 answer fails loudly =="
printf 'Sender=0x0 is not an owner or delegate\n422' >"$WORK/post.txt"
OUT=$(./script/manage/safe/propose.sh "$ENVELOPE" 2>&1)
check "exit status" "$?" "1"
contains "prints the service answer" "$OUT" "not an owner or delegate"

echo "== a chain id mismatch stops before any request =="
printf '\n201' >"$WORK/post.txt"
: >"$FAKE_CURL_LOG"
FAKE_CHAIN_ID=1 ./script/manage/safe/propose.sh "$ENVELOPE" >"$WORK/out.txt" 2>&1
check "exit status" "$?" "2"
contains "names both chains" "$(cat "$WORK/out.txt")" "11155111"
contains "names the RPC chain" "$(cat "$WORK/out.txt")" "the RPC serves chain 1"
check "sends no request" "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" "0"

echo "== an unmapped chain id stops the run =="
jq '.chainId = 31337' "$ENVELOPE" >"$WORK/local.json"
FAKE_CHAIN_ID=31337 ./script/manage/safe/propose.sh "$WORK/local.json" >"$WORK/out.txt" 2>&1
check "exit status" "$?" "2"
contains "says which chain" "$(cat "$WORK/out.txt")" "31337"

echo "== a missing field stops the run =="
jq 'del(.to)' "$ENVELOPE" >"$WORK/noto.json"
./script/manage/safe/propose.sh "$WORK/noto.json" >"$WORK/out.txt" 2>&1
check "exit status" "$?" "2"
contains "names the field" "$(cat "$WORK/out.txt")" "no 'to' field"

echo "== the dry run sends nothing =="
: >"$FAKE_CURL_LOG"
OUT=$(DRY_RUN=1 ./script/manage/safe/propose.sh "$ENVELOPE" 2>&1)
check "exit status" "$?" "0"
check "sends no request" "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" "0"
contains "prints the body" "$OUT" "contractTransactionHash"

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "propose.t.sh: all checks passed"
else
  echo "propose.t.sh: $FAILURES check(s) failed"
fi
exit "$FAILURES"
