#!/usr/bin/env bash
# Runs script/verify.sh in dry-run mode and checks the request it builds.
set -euo pipefail

export PATH="$HOME/.foundry/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

CHAIN_ID=31337
FAILURES=0

cleanup() {
  # This test is the last consumer of the compiler input. Nothing
  # needs it once this test finishes.
  for f in deployments/solcInputs/*.json; do
    [ -e "$f" ] || continue
    git ls-files --error-unmatch "$f" >/dev/null 2>&1 || rm -f "$f"
  done
}
trap cleanup EXIT

check() { # check <label> <actual> <expected>
  if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got '$2', want '$3'"; FAILURES=$((FAILURES + 1)); fi
}
contains() { # contains <label> <haystack> <needle>
  case "$2" in *"$3"*) echo "  ok   $1" ;; *) echo "  FAIL $1: '$3' not found"; FAILURES=$((FAILURES + 1)) ;; esac
}

# The record test leaves the records behind. Build them if they are missing.
if [ ! -f "deployments/BETH.proxy.$CHAIN_ID.json" ]; then
  echo "== no records; running record.t.sh first =="
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
contains "names the file it wanted" "$OUT" "NOPE.proxy.$CHAIN_ID.json"

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

echo
if [ "$FAILURES" -eq 0 ]; then echo "verify.t.sh: all checks passed"; else echo "verify.t.sh: $FAILURES check(s) failed"; exit 1; fi
