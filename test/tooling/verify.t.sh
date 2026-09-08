#!/usr/bin/env bash
# Runs script/verify.sh in dry-run mode and checks the command it builds.
#
# Every case here either sends nothing or stops before it sends. No case
# reaches a live block explorer.
set -euo pipefail

export PATH="$HOME/.foundry/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

CHAIN_ID=31337
FAILURES=0

# check and contains live in one file. record.t.sh sources the same file, so
# both tests count failures the same way.
. "$ROOT/test/tooling/lib.sh"

HEAD_COMMIT=$(git rev-parse --short HEAD)

# The records must be present, and they must name this commit. verify.sh stops
# on any other commit, because forge compiles the source again. A clean checkout
# holds no record, so this test builds them once.
NEED_RECORDS=0
for role in implementation proxy proxyAdmin; do
  r="deployments/BETH.$role.$CHAIN_ID.json"
  [ -f "$r" ] || { NEED_RECORDS=1; break; }
  [ "$(jq -r '.gitCommit // empty' "$r")" = "$HEAD_COMMIT" ] || { NEED_RECORDS=1; break; }
done
if [ "$NEED_RECORDS" -eq 1 ]; then
  echo "== records missing or from another commit; running record.t.sh first =="
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

contains "reports the key variable"   "$OUT" "key from ETHERSCAN_API_KEY_$CHAIN_ID"
contains "calls forge verify-contract" "$OUT" "forge verify-contract"
contains "passes the chain id"        "$OUT" "--chain $CHAIN_ID"
contains "waits for the result"       "$OUT" "--watch"
contains "handles implementation"     "$OUT" "src/BitSafeEvmAssetBridge.sol:BitSafeEvmAssetBridge"
contains "handles the proxy"          "$OUT" ":TransparentUpgradeableProxy"
contains "handles the ProxyAdmin"     "$OUT" ":ProxyAdmin"
contains "passes the compiler version" "$OUT" "--compiler-version v0.8.34+commit.80d5c536"
contains "passes the proxy ctor args" "$OUT" \
  "--constructor-args $(jq -r .encodedConstructorArgs "deployments/BETH.proxy.$CHAIN_ID.json")"

# forge picks the host itself unless a variable names one. The old code held a
# default endpoint of its own.
contains "leaves the host to forge" "$OUT" "explorer chosen by forge for chain $CHAIN_ID"
check    "passes no verifier url"   "$(printf '%s' "$OUT" | grep -c -- "--verifier-url" || true)" "0"

# The key reaches forge through the environment, so argv never holds it. A
# local `ps` therefore cannot show it. The printed line names the variable.
contains "passes the key by variable" "$OUT" "ETHERSCAN_API_KEY=\"\$ETHERSCAN_API_KEY_$CHAIN_ID\""
check    "never prints the key"       "$(printf '%s' "$OUT" | grep -c testkey || true)" "0"
check    "never passes the key in argv" \
  "$(printf '%s' "$OUT" | grep -c -- "--etherscan-api-key" || true)" "0"

echo "== a per-chain explorer host =="
OUT=$(DRY_RUN=1 VERIFIER_URL_31337=https://explorer.example/api \
  ETHERSCAN_API_KEY=x DEPLOYMENT=BETH CHAIN_ID=$CHAIN_ID ./script/verify.sh 2>&1)
contains "reports the host"     "$OUT" "explorer https://explorer.example/api"
contains "passes the host on"   "$OUT" "--verifier-url https://explorer.example/api"

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

# ---- the build guard ---------------------------------------------------------
# forge compiles the source again before it submits. A build from another commit
# therefore submits bytes the chain never held, and nothing warns the operator.
echo "== a record from another commit =="
GUARD="deployments/BETH.proxy.$CHAIN_ID.json"
cp "$GUARD" "$GUARD.bak"
jq --arg c deadbee '.gitCommit = $c' "$GUARD.bak" >"$GUARD"
set +e
OUT=$(DRY_RUN=1 ETHERSCAN_API_KEY=x DEPLOYMENT=BETH CHAIN_ID=$CHAIN_ID ./script/verify.sh 2>&1)
RC=$?
set -e
check    "exits non-zero on a commit mismatch" "$RC" "1"
contains "names the record's commit" "$OUT" "$GUARD names commit 'deadbee'"
contains "names the checked-out commit" "$OUT" "HEAD is '$HEAD_COMMIT'"
contains "gives the recovery command"   "$OUT" "git checkout deadbee"
contains "names the rebuild"            "$OUT" "forge build"
contains "names the escape hatch"       "$OUT" "ALLOW_COMMIT_MISMATCH=1"
check    "verifies nothing at all"      "$(printf '%s' "$OUT" | grep -c "DRY  " || true)" "0"

echo "== the escape hatch =="
set +e
OUT=$(ALLOW_COMMIT_MISMATCH=1 DRY_RUN=1 ETHERSCAN_API_KEY=x \
  DEPLOYMENT=BETH CHAIN_ID=$CHAIN_ID ./script/verify.sh 2>&1)
RC=$?
set -e
mv "$GUARD.bak" "$GUARD"
check    "exits zero with the escape hatch" "$RC" "0"
contains "reaches the proxy anyway" "$OUT" "DRY  proxy"

# ---- records this script must refuse -----------------------------------------
# One bad record must fail its own role only. The other roles must still run.
BAD="deployments/BETH.implementation.$CHAIN_ID.json"

run_bad() { # run_bad — runs every role in dry-run mode
  set +e
  BAD_OUT=$(DRY_RUN=1 ETHERSCAN_API_KEY=x DEPLOYMENT=BETH CHAIN_ID=$CHAIN_ID ./script/verify.sh 2>&1)
  BAD_RC=$?
  set -e
}

echo "== a record this script cannot read =="
cp "$BAD" "$BAD.bak"
printf '{"address": "0x1' >"$BAD"
run_bad
mv "$BAD.bak" "$BAD"
check    "exits non-zero on a truncated record" "$BAD_RC" "1"
contains "names the unreadable record" "$BAD_OUT" "holds no valid JSON"
contains "still handles the proxy"     "$BAD_OUT" "DRY  proxy"
contains "still handles the admin"     "$BAD_OUT" "DRY  proxyAdmin"

echo "== a record from a newer schema =="
cp "$BAD" "$BAD.bak"
jq '.schemaVersion = 2' "$BAD.bak" >"$BAD"
run_bad
mv "$BAD.bak" "$BAD"
check    "exits non-zero on an unknown schema" "$BAD_RC" "1"
contains "names both versions" "$BAD_OUT" "has schemaVersion '2'; this script reads 1"

echo "== a record missing a field forge needs =="
# jq prints the word "null" for an absent field. A command carrying that word
# gets a confusing rejection, so the script stops the role first.
cp "$BAD" "$BAD.bak"
jq 'del(.encodedConstructorArgs)' "$BAD.bak" >"$BAD"
run_bad
mv "$BAD.bak" "$BAD"
check    "exits non-zero on a missing field" "$BAD_RC" "1"
contains "names the missing field" "$BAD_OUT" "has no encodedConstructorArgs"

echo "== a record missing its commit =="
# The build guard reads gitCommit. A record without it would reach forge
# unchecked, so the script refuses the role.
cp "$BAD" "$BAD.bak"
jq 'del(.gitCommit)' "$BAD.bak" >"$BAD"
run_bad
mv "$BAD.bak" "$BAD"
check    "exits non-zero without a commit" "$BAD_RC" "1"
contains "names the missing commit" "$BAD_OUT" "has no gitCommit"

echo
if [ "$FAILURES" -eq 0 ]; then echo "verify.t.sh: all checks passed"; else echo "verify.t.sh: $FAILURES check(s) failed"; exit 1; fi
