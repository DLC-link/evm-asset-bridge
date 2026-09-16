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
export FAKE_CAST_LOG="$WORK/cast.log"

# queue_reply writes the answer of the nonce query. The first argument is the
# highest nonce in the queue. The word "empty" writes an empty queue.
queue_reply() { # queue_reply <nonce|empty>
  if [ "$1" = "empty" ]; then
    printf '{"count":0,"next":null,"previous":null,"results":[],"countUniqueNonce":0}\n200' \
      >"$WORK/queue.txt"
  else
    printf '{"count":1,"next":null,"previous":null,"results":[{"nonce":%s,"isExecuted":true}],"countUniqueNonce":1}\n200' \
      "$1" >"$WORK/queue.txt"
  fi
}
queue_reply empty

# This is a valid envelope. Each test copies the envelope. Each test then
# edits one field. The "safe" and "to" addresses are lowercase on purpose.
# The script must run its own checksum call to pass the checks below.
#
# propose.sh deletes the envelope after a successful propose. The fixture is
# therefore a template, and each test block copies it before the run.
ENVELOPE="$WORK/envelope.json"
TEMPLATE="$WORK/envelope.template.json"
fresh_envelope() { cp "$TEMPLATE" "$ENVELOPE"; }
cat >"$TEMPLATE" <<'JSON'
{
  "deployment": "BETH",
  "chainId": 11155111,
  "action": "setThreshold",
  "safe": "0xaaafda111eaf5a49359e5c15b9b58ded7313f979",
  "to": "0xc2dbb9af52da4ba877c13fdf55d128da76aee950",
  "value": "0",
  "data": "0x960bfe0400000000000000000000000000000000000000000000000000000000000003",
  "operation": 0
}
JSON

echo "== a good envelope reaches the service =="
fresh_envelope
printf '\n201' >"$WORK/post.txt"
# A lowercase FAKE_SIGNER_ADDRESS forces the sender checksum call to run.
# The lowercase "safe" and "to" fields force the same call for SAFE and TO.
OUT=$(FAKE_SIGNER_ADDRESS="0x7038f8a64ce8f879705a48e962b55d56aecd60d8" \
  ./script/manage/safe/propose.sh "$ENVELOPE" 2>&1)
check "exit status" "$?" "0"
contains "reports the hash" "$OUT" "0x1111111111111111111111111111111111111111111111111111111111111111"
contains "reports the delete" "$OUT" "propose.sh: removed"
check "removes the envelope" "$([ -e "$ENVELOPE" ] && echo yes || echo no)" "no"
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
contains "queries the queue first" "$REQ" "ordering=-nonce"
contains "queries the v1 endpoint" "$REQ" "/api/v1/safes/"

echo "== the run prints the target and the calldata before it signs =="
fresh_envelope
contains "prints the target" "$OUT" "propose.sh: to 0xc2DBb9AF52DA4BA877c13Fdf55d128dA76AEE950"
contains "prints the calldata" "$OUT" \
  "propose.sh: data 0x960bfe0400000000000000000000000000000000000000000000000000000000000003"
contains "prints the nonce and its source" "$OUT" "nonce 7 from the on-chain nonce"

echo "== the hashed transaction matches the posted transaction =="
# The owners sign the hash that getTransactionHash returns. The service shows
# the fields that the body carries. A difference between the two lets an owner
# sign one transaction while the queue displays another. Every field therefore
# appears on both sides below.
fresh_envelope
queue_reply empty
printf '\n201' >"$WORK/post.txt"
: >"$FAKE_CURL_LOG"
: >"$FAKE_CAST_LOG"
OUT=$(FAKE_SAFE_NONCE=7 ./script/manage/safe/propose.sh "$ENVELOPE" 2>&1)
check "exit status" "$?" "0"

HASH_ARGS=$(grep getTransactionHash "$FAKE_CAST_LOG")
HASH_ARGS=${HASH_ARGS#*"(bytes32) "}
HASH_ARGS=${HASH_ARGS%% --rpc-url*}
BODY_JSON=$(awk '/^\{$/,/^\}$/' "$FAKE_CURL_LOG")
hashed() { printf '%s' "$HASH_ARGS" | cut -d' ' -f"$1"; }
posted() { printf '%s' "$BODY_JSON" | jq -r --arg k "$1" '.[$k] | tostring'; }

check "hashes the posted to" "$(hashed 1)" "$(posted to)"
check "hashes the posted value" "$(hashed 2)" "$(posted value)"
check "hashes the posted data" "$(hashed 3)" "$(posted data)"
check "hashes the posted operation" "$(hashed 4)" "$(posted operation)"
check "hashes the posted safeTxGas" "$(hashed 5)" "$(posted safeTxGas)"
check "hashes the posted baseGas" "$(hashed 6)" "$(posted baseGas)"
check "hashes the posted gasPrice" "$(hashed 7)" "$(posted gasPrice)"
check "hashes the posted gasToken" "$(hashed 8)" "$(posted gasToken)"
check "hashes the posted refundReceiver" "$(hashed 9)" "$(posted refundReceiver)"
check "hashes the posted nonce" "$(hashed 10)" "$(posted nonce)"

echo "== an empty queue keeps the on-chain nonce =="
fresh_envelope
queue_reply empty
printf '\n201' >"$WORK/post.txt"
: >"$FAKE_CURL_LOG"
: >"$FAKE_CAST_LOG"
OUT=$(FAKE_SAFE_NONCE=5 ./script/manage/safe/propose.sh "$ENVELOPE" 2>&1)
check "exit status" "$?" "0"
contains "posts the on-chain nonce" "$(cat "$FAKE_CURL_LOG")" '"nonce": "5"'
contains "names the on-chain nonce" "$OUT" "nonce 5 from the on-chain nonce"
contains "hashes the same nonce" "$(cat "$FAKE_CAST_LOG")" "getTransactionHash"
contains "hashes with nonce 5" "$(grep getTransactionHash "$FAKE_CAST_LOG")" " 5 --rpc-url"

echo "== a queued nonce above the chain wins =="
fresh_envelope
queue_reply 11
: >"$FAKE_CURL_LOG"
: >"$FAKE_CAST_LOG"
OUT=$(FAKE_SAFE_NONCE=7 ./script/manage/safe/propose.sh "$ENVELOPE" 2>&1)
check "exit status" "$?" "0"
contains "posts the next free nonce" "$(cat "$FAKE_CURL_LOG")" '"nonce": "12"'
contains "names the queue" "$OUT" "nonce 12 from the highest queued nonce at the service"
contains "hashes with nonce 12" "$(grep getTransactionHash "$FAKE_CAST_LOG")" " 12 --rpc-url"

echo "== an executed entry below the chain loses =="
fresh_envelope
queue_reply 3
: >"$FAKE_CURL_LOG"
OUT=$(FAKE_SAFE_NONCE=9 ./script/manage/safe/propose.sh "$ENVELOPE" 2>&1)
check "exit status" "$?" "0"
contains "posts the on-chain nonce" "$(cat "$FAKE_CURL_LOG")" '"nonce": "9"'
contains "names the on-chain nonce" "$OUT" "nonce 9 from the on-chain nonce"

echo "== a failed queue query warns and falls back =="
fresh_envelope
printf 'upstream error\n503' >"$WORK/queue.txt"
: >"$FAKE_CURL_LOG"
OUT=$(FAKE_SAFE_NONCE=4 ./script/manage/safe/propose.sh "$ENVELOPE" 2>&1)
check "exit status" "$?" "0"
contains "warns loudly" "$OUT" "WARNING. The Safe service gave no queue answer."
contains "tells the operator to check the queue" "$OUT" "check for a nonce conflict"
contains "posts the on-chain nonce" "$(cat "$FAKE_CURL_LOG")" '"nonce": "4"'
contains "names the failure" "$OUT" "nonce 4 from the on-chain nonce, after a failed queue request"

echo "== a queue body that does not parse warns and falls back =="
fresh_envelope
printf 'not json at all\n200' >"$WORK/queue.txt"
: >"$FAKE_CURL_LOG"
OUT=$(FAKE_SAFE_NONCE=4 ./script/manage/safe/propose.sh "$ENVELOPE" 2>&1)
check "exit status" "$?" "0"
contains "warns loudly" "$OUT" "WARNING. The Safe service gave no queue answer."
contains "posts the on-chain nonce" "$(cat "$FAKE_CURL_LOG")" '"nonce": "4"'

echo "== the NONCE override wins over both sources =="
fresh_envelope
queue_reply 11
: >"$FAKE_CURL_LOG"
: >"$FAKE_CAST_LOG"
OUT=$(NONCE=42 FAKE_SAFE_NONCE=7 ./script/manage/safe/propose.sh "$ENVELOPE" 2>&1)
check "exit status" "$?" "0"
contains "posts the override" "$(cat "$FAKE_CURL_LOG")" '"nonce": "42"'
contains "names the override" "$OUT" "nonce 42 from the NONCE override"
contains "hashes with nonce 42" "$(grep getTransactionHash "$FAKE_CAST_LOG")" " 42 --rpc-url"
case "$(cat "$FAKE_CURL_LOG")" in
  *ordering=-nonce*) echo "  FAIL skips the queue query"; FAILURES=$((FAILURES + 1)) ;;
  *) echo "  ok   skips the queue query" ;;
esac

echo "== a NONCE with leading zeros loses them =="
fresh_envelope
: >"$FAKE_CURL_LOG"
: >"$FAKE_CAST_LOG"
OUT=$(NONCE=007 FAKE_SAFE_NONCE=7 ./script/manage/safe/propose.sh "$ENVELOPE" 2>&1)
check "exit status" "$?" "0"
contains "posts plain decimal" "$(cat "$FAKE_CURL_LOG")" '"nonce": "7"'
contains "names the override" "$OUT" "nonce 7 from the NONCE override"
contains "hashes with nonce 7" "$(grep getTransactionHash "$FAKE_CAST_LOG")" " 7 --rpc-url"

echo "== a NONCE of 000 becomes 0 =="
fresh_envelope
: >"$FAKE_CURL_LOG"
OUT=$(NONCE=000 FAKE_SAFE_NONCE=7 ./script/manage/safe/propose.sh "$ENVELOPE" 2>&1)
check "exit status" "$?" "0"
contains "posts zero" "$(cat "$FAKE_CURL_LOG")" '"nonce": "0"'

echo "== the API key reaches both requests =="
fresh_envelope
queue_reply empty
: >"$FAKE_CURL_LOG"
SAFE_API_KEY=s3cret-key ./script/manage/safe/propose.sh "$ENVELOPE" >"$WORK/out.txt" 2>&1
check "exit status" "$?" "0"
GET_REQ=$(awk '/ordering=-nonce/,/^--$/' "$FAKE_CURL_LOG")
contains "the queue query carries the bearer token" "$GET_REQ" \
  'header = "Authorization: Bearer s3cret-key"'
POST_REQ=$(awk '/request = "POST"/,/^--$/' "$FAKE_CURL_LOG")
contains "the proposal carries the bearer token" "$POST_REQ" \
  'header = "Authorization: Bearer s3cret-key"'

echo "== a bad NONCE stops the run =="
fresh_envelope
: >"$FAKE_CURL_LOG"
NONCE=-1 ./script/manage/safe/propose.sh "$ENVELOPE" >"$WORK/out.txt" 2>&1
check "exit status" "$?" "2"
contains "names the rule" "$(cat "$WORK/out.txt")" "NONCE must be a non-negative integer"
check "sends no request" "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" "0"

echo "== an action name with a quote stays valid JSON =="
fresh_envelope
queue_reply empty
printf '\n201' >"$WORK/post.txt"
: >"$FAKE_CURL_LOG"
jq '.action = "set\"Threshold"' "$ENVELOPE" >"$WORK/quoted.json"
./script/manage/safe/propose.sh "$WORK/quoted.json" >"$WORK/out.txt" 2>&1
check "exit status" "$?" "0"
BODY_JSON=$(awk '/^\{$/,/^\}$/' "$FAKE_CURL_LOG")
check "the body parses" "$(printf '%s' "$BODY_JSON" | jq -e -r '.origin | fromjson | .action')" \
  'set"Threshold'

echo "== a non-201 answer fails loudly =="
fresh_envelope
printf 'Sender=0x0 is not an owner or delegate\n422' >"$WORK/post.txt"
OUT=$(./script/manage/safe/propose.sh "$ENVELOPE" 2>&1)
check "exit status" "$?" "1"
contains "prints the service answer" "$OUT" "not an owner or delegate"
check "keeps the envelope after a failure" "$([ -e "$ENVELOPE" ] && echo yes || echo no)" "yes"

echo "== a chain id mismatch stops before any request =="
fresh_envelope
printf '\n201' >"$WORK/post.txt"
: >"$FAKE_CURL_LOG"
FAKE_CHAIN_ID=1 ./script/manage/safe/propose.sh "$ENVELOPE" >"$WORK/out.txt" 2>&1
check "exit status" "$?" "2"
contains "names both chains" "$(cat "$WORK/out.txt")" "11155111"
contains "names the RPC chain" "$(cat "$WORK/out.txt")" "the RPC serves chain 1"
check "sends no request" "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" "0"

echo "== an unmapped chain id stops the run =="
fresh_envelope
jq '.chainId = 31337' "$ENVELOPE" >"$WORK/local.json"
FAKE_CHAIN_ID=31337 ./script/manage/safe/propose.sh "$WORK/local.json" >"$WORK/out.txt" 2>&1
check "exit status" "$?" "2"
contains "says which chain" "$(cat "$WORK/out.txt")" "31337"

echo "== a missing field stops the run =="
fresh_envelope
jq 'del(.to)' "$ENVELOPE" >"$WORK/noto.json"
./script/manage/safe/propose.sh "$WORK/noto.json" >"$WORK/out.txt" 2>&1
check "exit status" "$?" "2"
contains "names the field" "$(cat "$WORK/out.txt")" "no 'to' field"

echo "== a delegatecall envelope stops the run =="
# ManageBase writes operation 0 for every action. Operation 1 is DELEGATECALL,
# which runs code in the Safe's own storage. A changed file must not reach a
# signature.
fresh_envelope
jq '.operation = 1' "$ENVELOPE" >"$WORK/delegate.json"
: >"$FAKE_CURL_LOG"
./script/manage/safe/propose.sh "$WORK/delegate.json" >"$WORK/out.txt" 2>&1
check "exit status" "$?" "2"
contains "names the operation" "$(cat "$WORK/out.txt")" "operation 1"
check "sends no request" "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" "0"

echo "== an envelope that sends value stops the run =="
fresh_envelope
jq '.value = "1000000000000000000"' "$ENVELOPE" >"$WORK/value.json"
: >"$FAKE_CURL_LOG"
./script/manage/safe/propose.sh "$WORK/value.json" >"$WORK/out.txt" 2>&1
check "exit status" "$?" "2"
contains "names the value" "$(cat "$WORK/out.txt")" "sends value 1000000000000000000"
check "sends no request" "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" "0"

echo "== calldata that is not hexadecimal stops the run =="
fresh_envelope
jq '.data = "0x960bfe04zz"' "$ENVELOPE" >"$WORK/baddata.json"
: >"$FAKE_CURL_LOG"
./script/manage/safe/propose.sh "$WORK/baddata.json" >"$WORK/out.txt" 2>&1
check "exit status" "$?" "2"
contains "says the data is not hexadecimal" "$(cat "$WORK/out.txt")" "is not hexadecimal"
check "sends no request" "$(wc -c <"$FAKE_CURL_LOG" | tr -d ' ')" "0"

echo "== calldata with an odd digit count stops the run =="
fresh_envelope
jq '.data = "0x960bfe0"' "$ENVELOPE" >"$WORK/odddata.json"
./script/manage/safe/propose.sh "$WORK/odddata.json" >"$WORK/out.txt" 2>&1
check "exit status" "$?" "2"
contains "says the digit count is odd" "$(cat "$WORK/out.txt")" "odd number of digits"

echo "== the dry run posts nothing =="
fresh_envelope
queue_reply 11
: >"$FAKE_CURL_LOG"
OUT=$(DRY_RUN=1 FAKE_SAFE_NONCE=7 ./script/manage/safe/propose.sh "$ENVELOPE" 2>&1)
check "exit status" "$?" "0"
contains "prints the body" "$OUT" "contractTransactionHash"
contains "reads the queue" "$(cat "$FAKE_CURL_LOG")" "ordering=-nonce"
contains "prints the real nonce" "$OUT" '"nonce": "12"'
case "$(cat "$FAKE_CURL_LOG")" in
  *'request = "POST"'*) echo "  FAIL posts nothing"; FAILURES=$((FAILURES + 1)) ;;
  *) echo "  ok   posts nothing" ;;
esac
check "keeps the envelope on a dry run" "$([ -e "$ENVELOPE" ] && echo yes || echo no)" "yes"

# ---- the make entry point ---------------------------------------------------
# The two blocks below drive `make`, not the script. The Makefile decides who
# needs a signer, and it decides what the mode line prints, so only a make-level
# run can check either. FOUNDRY_BIN points at the fakes, because the target
# prepends that directory to PATH and the real cast would otherwise win.

echo "== the manage mode line carries no wallet secret =="
# SIGNER can hold --private-key or --password. The mode line runs through echo,
# so `make -s` cannot suppress it. Its text must therefore carry no part of
# SIGNER, whatever wallet flags the operator passes and in whatever order.
mode_line() { # mode_line <signer>
  make -n manage DEPLOYMENT=BETH SCRIPT=Pause SIG='run()' \
    RPC_URL="https://rpc.example/KEYED123" SIGNER="$1" \
    FOUNDRY_BIN="$ROOT/test/tooling/fake" 2>&1 | grep '^echo "manage:' || true
}
for SIG_SHAPE in \
  "--private-key 0xSECRETKEY" \
  "--account sentry --password hunter2" \
  "--sender 0xAbc --account sentry" \
  "--password-file /run/secrets/s.pass --account sentry"; do
  MODE_OUT=$(mode_line "$SIG_SHAPE")
  case "$MODE_OUT" in
    *SECRETKEY* | *hunter2* | *KEYED123* | *sentry* | *s.pass* | *--*)
      echo "  FAIL the mode line carries part of SIGNER: $SIG_SHAPE"
      FAILURES=$((FAILURES + 1)) ;;
    *"direct broadcast"*)
      echo "  ok   no part of SIGNER reaches the line: $SIG_SHAPE" ;;
    *)
      echo "  FAIL the mode line names no mode: $SIG_SHAPE"
      FAILURES=$((FAILURES + 1)) ;;
  esac
done

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "propose.t.sh: all checks passed"
else
  echo "propose.t.sh: $FAILURES check(s) failed"
fi
exit "$FAILURES"
