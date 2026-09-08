#!/usr/bin/env bash
# Runs script/verify.sh in dry-run mode and checks the request it builds.
set -euo pipefail

export PATH="$HOME/.foundry/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

CHAIN_ID=31337
FAILURES=0

# check, contains, and the compiler-input rule live in one file. record.t.sh
# sources the same file, so both tests clean up the same way. An input that a
# record still names survives, because a real deploy leaves both untracked.
. "$ROOT/test/tooling/lib.sh"

# The stub directory holds the canned explorer replies. See the stub section
# below.
STUB_DIR=$(mktemp -d)
cleanup() {
  rm -rf "$STUB_DIR"
  prune_untracked_solc_inputs
}
trap cleanup EXIT

# The records and their compiler inputs must both be present. A clean checkout
# holds neither, so this test builds them once.
NEED_RECORDS=0
for role in implementation proxy proxyAdmin; do
  r="deployments/BETH.$role.$CHAIN_ID.json"
  [ -f "$r" ] || { NEED_RECORDS=1; break; }
  h="$(jq -r '.solcInputHash // empty' "$r")"
  [ -n "$h" ] && [ -f "deployments/solcInputs/$h.json" ] || { NEED_RECORDS=1; break; }
done
if [ "$NEED_RECORDS" -eq 1 ]; then
  echo "== records or compiler inputs missing; running record.t.sh first =="
  ./test/tooling/record.t.sh >/dev/null
fi

echo "== missing key =="
set +e
OUT=$(DRY_RUN= DEPLOYMENT=BETH CHAIN_ID=$CHAIN_ID ./script/verify.sh 2>&1)
RC=$?
set -e
check "exits non-zero without a key" "$RC" "1"
# One check on the whole sentence. "ETHERSCAN_API_KEY" alone is a substring of
# "ETHERSCAN_API_KEY_31337", so it would pass even if the fallback went missing.
contains "names both variables" "$OUT" "Set ETHERSCAN_API_KEY_$CHAIN_ID, or ETHERSCAN_API_KEY."

echo "== missing record =="
set +e
OUT=$(ETHERSCAN_API_KEY=x DEPLOYMENT=NOPE CHAIN_ID=$CHAIN_ID ./script/verify.sh 2>&1)
RC=$?
set -e
check "exits non-zero without records" "$RC" "1"
contains "names the files it wanted" "$OUT" "deployments/NOPE.<role>.$CHAIN_ID.json"

echo "== dry run, all three contracts =="
OUT=$(DRY_RUN=1 ETHERSCAN_API_KEY_31337=testkey DEPLOYMENT=BETH CHAIN_ID=$CHAIN_ID ./script/verify.sh 2>&1)

contains "reports the key variable"  "$OUT" "key from ETHERSCAN_API_KEY_$CHAIN_ID"
contains "handles implementation"    "$OUT" "src/BitSafeEvmAssetBridge.sol:BitSafeEvmAssetBridge"
contains "handles the proxy"         "$OUT" ":TransparentUpgradeableProxy"
contains "handles the ProxyAdmin"    "$OUT" ":ProxyAdmin"
contains "sends the right codeformat" "$OUT" "solidity-standard-json-input"
contains "sends the compiler version" "$OUT" "v0.8.34+commit.80d5c536"
contains "sends the MIT license code" "$OUT" "licenseType=3"
contains "sends the proxy ctor args"  "$OUT" "$(jq -r .encodedConstructorArgs "deployments/BETH.proxy.$CHAIN_ID.json" | cut -c3-42)"
check    "never prints the key"       "$(printf '%s' "$OUT" | grep -c testkey || true)" "0"

echo "== dry run, one contract only =="
OUT=$(DRY_RUN=1 ETHERSCAN_API_KEY=testkey CONTRACT=implementation DEPLOYMENT=BETH CHAIN_ID=$CHAIN_ID ./script/verify.sh 2>&1)
contains "reports the fallback variable" "$OUT" "key from ETHERSCAN_API_KEY"
contains "does the implementation"       "$OUT" "BitSafeEvmAssetBridge"
check "skips the other two" "$(printf '%s' "$OUT" | grep -c "TransparentUpgradeableProxy" || true)" "0"

echo "== a role outside the three fixed ones =="
# The role is a free label. A standalone timelock records one role only, and
# the script must find it without a code change.
EXTRA="deployments/BETH.timelock.$CHAIN_ID.json"
cp "deployments/BETH.proxyAdmin.$CHAIN_ID.json" "$EXTRA"
set +e
OUT=$(DRY_RUN=1 ETHERSCAN_API_KEY=x DEPLOYMENT=BETH CHAIN_ID=$CHAIN_ID ./script/verify.sh 2>&1)
RC=$?
set -e
rm -f "$EXTRA"
check "exits zero with an extra role" "$RC" "0"
contains "discovers the extra role" "$OUT" "DRY  timelock"

echo "== bad CONTRACT value =="
set +e
OUT=$(DRY_RUN=1 ETHERSCAN_API_KEY=x CONTRACT=implementaton DEPLOYMENT=BETH CHAIN_ID=$CHAIN_ID ./script/verify.sh 2>&1)
RC=$?
set -e
check "exits non-zero on a bad CONTRACT value" "$RC" "2"
contains "names implementation as a recorded role" "$OUT" "implementation"
contains "names proxy as a recorded role"          "$OUT" "proxy"
contains "names proxyAdmin as a recorded role"     "$OUT" "proxyAdmin"

echo "== missing per-role record =="
# A requested role with no record fails. It never passes silently.
IMPL_RECORD="deployments/BETH.implementation.$CHAIN_ID.json"
mv "$IMPL_RECORD" "$IMPL_RECORD.bak"
set +e
OUT=$(DRY_RUN=1 ETHERSCAN_API_KEY=x CONTRACT=implementation DEPLOYMENT=BETH CHAIN_ID=$CHAIN_ID ./script/verify.sh 2>&1)
RC=$?
set -e
mv "$IMPL_RECORD.bak" "$IMPL_RECORD"
check "exits non-zero when a requested role has no record" "$RC" "2"
contains "names the role it could not find" "$OUT" "Got 'implementation'"
contains "names the roles it did find"      "$OUT" "records: proxy proxyAdmin"


# ---- the explorer replies ----------------------------------------------------
# The dry-run cases above send nothing, so they never test how the script reads
# an explorer reply. A fake curl on PATH replaces the network. script/verify.sh
# always sends its request on stdin, so the stub reads the whole request and
# prints a canned reply. A fake sleep joins it, because the poll loop waits five
# seconds thirty times.
FAKE_PATH="$ROOT/test/tooling/fake:$PATH"

# run_stub answers the three calls with the bodies it is given. It sets
# STUB_OUT and STUB_RC, and it leaves the captured requests in $STUB_DIR/log.
# It runs one role, the implementation, unless a fourth argument names another.
# An empty fourth argument runs every role.
run_stub() { # run_stub <getabiBody> <submitBody> <pollBody> [role]
  rm -f "$STUB_DIR"/getabi.txt "$STUB_DIR"/submit.txt "$STUB_DIR"/poll.txt "$STUB_DIR"/log
  printf '%s' "$1" >"$STUB_DIR/getabi.txt"
  printf '%s' "$2" >"$STUB_DIR/submit.txt"
  printf '%s' "$3" >"$STUB_DIR/poll.txt"
  set +e
  STUB_OUT=$(PATH="$FAKE_PATH" FAKE_CURL_DIR="$STUB_DIR" FAKE_CURL_LOG="$STUB_DIR/log" \
    ETHERSCAN_API_KEY=stubkey CONTRACT="${4-implementation}" \
    DEPLOYMENT=BETH CHAIN_ID=$CHAIN_ID ./script/verify.sh 2>&1)
  STUB_RC=$?
  set -e
}

NOT_VERIFIED='{"status":"0","result":"Contract source code not verified"}'
GUID='{"status":"1","result":"stubguid"}'
PASSED='{"status":"1","result":"Pass - Verified"}'

echo "== the explorer already has the source =="
run_stub '{"status":"1","result":"[]"}' "$GUID" "$PASSED"
check    "exits zero when the source is already verified" "$STUB_RC" "0"
contains "skips the verified contract" "$STUB_OUT" "SKIP implementation"

echo "== the explorer accepts the source =="
run_stub "$NOT_VERIFIED" "$GUID" "$PASSED"
check    "exits zero on a pass"      "$STUB_RC" "0"
contains "sends the contract"        "$STUB_OUT" "SEND implementation"
contains "reports the pass"          "$STUB_OUT" "OK   implementation"
contains "quotes the explorer"       "$STUB_OUT" "Pass - Verified"

# The dry-run path prints these fields. This asserts the request really carries
# them. The key appears in the captured request, which proves it travels on
# stdin. Argv therefore never holds it, so a local `ps` cannot show it.
LOG=$(cat "$STUB_DIR/log")
contains "posts the verify action"   "$LOG" "action=verifysourcecode"
contains "posts the standard json"   "$LOG" "codeformat=solidity-standard-json-input"
contains "posts the contract name"   "$LOG" "src/BitSafeEvmAssetBridge.sol:BitSafeEvmAssetBridge"
contains "posts the license code"    "$LOG" "licenseType=3"
contains "sends the key on stdin"    "$LOG" "apikey=stubkey"
check    "never prints the key"      "$(printf '%s' "$STUB_OUT" | grep -c stubkey || true)" "0"

echo "== the explorer rejects the source =="
run_stub "$NOT_VERIFIED" '{"status":"0","result":"NOTOK: invalid API key"}' "$PASSED"
check    "exits non-zero on a reject" "$STUB_RC" "1"
contains "names the failed role"      "$STUB_OUT" "FAIL implementation"
contains "quotes the reason"          "$STUB_OUT" "NOTOK: invalid API key"
contains "counts the failure"         "$STUB_OUT" "1 contract(s) failed"

echo "== the already-verified check gets an error page =="
# A rate-limit page is not JSON. The script must treat the contract as
# unverified and submit it, rather than skip it.
run_stub '<html>rate limited</html>' "$GUID" "$PASSED"
check    "exits zero after an error page" "$STUB_RC" "0"
contains "submits the contract anyway"    "$STUB_OUT" "SEND implementation"

echo "== the explorer never concludes =="
# The fake sleep makes this case fast. The real loop waits 150 seconds.
run_stub "$NOT_VERIFIED" "$GUID" '{"status":"1","result":"Pending in queue"}'
check    "exits non-zero on a timeout" "$STUB_RC" "1"
contains "reports the timeout"         "$STUB_OUT" "timed out after 150 seconds"

echo "== the explorer sends no JSON =="
# A rate-limit page or an empty body must fail one role with a readable reason.
# It must never stop the run with a raw jq parse error.
run_stub "$NOT_VERIFIED" '' "$PASSED"
check    "exits non-zero on an empty submit reply" "$STUB_RC" "1"
contains "says the reply was empty" "$STUB_OUT" "the explorer sent an empty reply"

run_stub "$NOT_VERIFIED" '<html>502 Bad Gateway</html>' "$PASSED"
check    "exits non-zero on a non-JSON submit reply" "$STUB_RC" "1"
contains "quotes the page it got" "$STUB_OUT" "the explorer sent no JSON: <html>502 Bad Gateway</html>"

run_stub "$NOT_VERIFIED" "$GUID" '<html>429 Too Many Requests</html>'
check    "exits non-zero on a non-JSON poll reply" "$STUB_RC" "1"
contains "names the timeout"      "$STUB_OUT" "timed out after 150 seconds"
contains "quotes the poll page"   "$STUB_OUT" "the explorer sent no JSON: <html>429 Too Many Requests</html>"

echo "== the explorer accepts the submit but sends no guid =="
run_stub "$NOT_VERIFIED" '{"status":"1"}' "$PASSED"
check    "exits non-zero without a guid" "$STUB_RC" "1"
contains "says the guid is missing" "$STUB_OUT" "sent no guid"

echo "== a record this script cannot read =="
# One bad record must fail its own role only. The other roles must still run.
BAD="deployments/BETH.implementation.$CHAIN_ID.json"
cp "$BAD" "$BAD.bak"
printf '{"address": "0x1' >"$BAD"
run_stub "$NOT_VERIFIED" "$GUID" "$PASSED" ""
mv "$BAD.bak" "$BAD"
check    "exits non-zero on a truncated record" "$STUB_RC" "1"
contains "names the unreadable record" "$STUB_OUT" "holds no valid JSON"
contains "still verifies the proxy"    "$STUB_OUT" "OK   proxy"
contains "still verifies the admin"    "$STUB_OUT" "OK   proxyAdmin"

echo "== a record from a newer schema =="
cp "$BAD" "$BAD.bak"
jq '.schemaVersion = 2' "$BAD.bak" >"$BAD"
run_stub "$NOT_VERIFIED" "$GUID" "$PASSED"
mv "$BAD.bak" "$BAD"
check    "exits non-zero on an unknown schema" "$STUB_RC" "1"
contains "names both versions" "$STUB_OUT" "has schemaVersion '2'; this script reads 1"

echo "== a record missing a field the explorer needs =="
# jq prints the word "null" for an absent field. A request holding that word
# gets a confusing rejection, so the script stops the role first.
cp "$BAD" "$BAD.bak"
jq 'del(.encodedConstructorArgs)' "$BAD.bak" >"$BAD"
run_stub "$NOT_VERIFIED" "$GUID" "$PASSED"
mv "$BAD.bak" "$BAD"
check    "exits non-zero on a missing field" "$STUB_RC" "1"
contains "names the missing field" "$STUB_OUT" "has no encodedConstructorArgs"

echo "== a record holding a line break =="
# A curl config file holds one directive per line. A newline in a value would
# start a new directive, such as one that writes a file. The script must refuse
# the record and send nothing.
cp "$BAD" "$BAD.bak"
jq '.contractName = "Bridge\noutput = /tmp/stolen"' "$BAD.bak" >"$BAD"
run_stub "$NOT_VERIFIED" "$GUID" "$PASSED"
mv "$BAD.bak" "$BAD"
check    "exits non-zero on a line break" "$STUB_RC" "1"
contains "names the line break" "$STUB_OUT" "holds a line break"
check    "reaches no explorer" \
  "$([ -s "$STUB_DIR/log" ] && echo sent || echo nothing)" "nothing"

echo "== a poisoned explorer host =="
# The host, the key and the chain id all reach the same curl config. The script
# checks them once, before it reads any record. This case also proves the check
# runs at all: bash reports "command not found" for a function defined further
# down the file, and an `if` swallows that, so the check would do nothing.
set +e
OUT=$(VERIFIER_URL_31337="$(printf 'https://x\noutput = /tmp/stolen')" \
  ETHERSCAN_API_KEY=x DRY_RUN=1 DEPLOYMENT=BETH CHAIN_ID=$CHAIN_ID ./script/verify.sh 2>&1)
RC=$?
set -e
check    "exits non-zero on a poisoned host" "$RC" "2"
contains "names the line break"   "$OUT" "holds a line break"
check    "the check itself runs"  "$(printf '%s' "$OUT" | grep -c 'command not found' || true)" "0"
echo
if [ "$FAILURES" -eq 0 ]; then echo "verify.t.sh: all checks passed"; else echo "verify.t.sh: $FAILURES check(s) failed"; exit 1; fi
