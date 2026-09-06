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

trap prune_untracked_solc_inputs EXIT

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
contains "names the per-chain variable" "$OUT" "ETHERSCAN_API_KEY_$CHAIN_ID"
contains "names the fallback variable"  "$OUT" "ETHERSCAN_API_KEY"

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

echo
if [ "$FAILURES" -eq 0 ]; then echo "verify.t.sh: all checks passed"; else echo "verify.t.sh: $FAILURES check(s) failed"; exit 1; fi
