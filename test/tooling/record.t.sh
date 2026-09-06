#!/usr/bin/env bash
# Runs script/record.sh against a local anvil and checks the records it writes.
set -euo pipefail

export PATH="$HOME/.foundry/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

PORT=8547
RPC="http://127.0.0.1:$PORT"
CHAIN_ID=31337
FAILURES=0

# check, contains, and the compiler-input rule live in one file. verify.t.sh
# sources the same file, so both tests clean up the same way.
. "$ROOT/test/tooling/lib.sh"

cleanup() {
  pkill -f "anvil --port $PORT" >/dev/null 2>&1 || true
  prune_untracked_solc_inputs
}
trap cleanup EXIT

echo "== starting anvil on port $PORT =="
cleanup
anvil --port "$PORT" --silent &
until cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; do sleep 0.2; done

rm -rf "deployments/BETH."*".$CHAIN_ID.json" deployments/.pending broadcast/Deploy_BETH.s.sol

echo "== deploying =="
# Anvil's first default account. This key is public and well known.
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export ASSET=0x0000000000000000000000000000000000000000
export TARGET_DECIMALS=10
export DEFAULT_ADMIN=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
export ADMIN_DELAY=0
export BRIDGE_ADMIN=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
export PROXY_OWNER=0x90F79bf6EB2c4f870365E785982E1f101E93b906
export ATTESTORS=0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65,0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc,0x976EA74026E726554dB657fA54763abd0C3a0aa9
export THRESHOLD=2
export DEPOSIT_MIN=0
export DEPOSIT_MAX=115792089237316195423570985008687907853269984665640564039457584007913129639935
export WITHDRAW_MIN=0
export WITHDRAW_MAX=115792089237316195423570985008687907853269984665640564039457584007913129639935

forge script script/Deploy_BETH.s.sol:Deploy_BETH \
  --rpc-url "$RPC" --broadcast --private-key "$PRIVATE_KEY" >/dev/null

echo "== recording =="
./script/record.sh BETH

echo "== checks =="
P="deployments/BETH.proxy.$CHAIN_ID.json"
I="deployments/BETH.implementation.$CHAIN_ID.json"
A="deployments/BETH.proxyAdmin.$CHAIN_ID.json"

for f in "$P" "$I" "$A"; do
  if [ -f "$f" ]; then echo "  ok   $f exists"; else echo "  FAIL $f missing"; FAILURES=$((FAILURES + 1)); fi
done

check "pending file removed" \
  "$([ -f "deployments/.pending/BETH.$CHAIN_ID.json" ] && echo present || echo gone)" "gone"

check "proxy role"          "$(jq -r .role "$P")"          "proxy"
check "proxy contractName"  "$(jq -r .contractName "$P")"  "TransparentUpgradeableProxy"
check "impl contractName"   "$(jq -r .contractName "$I")"  "BitSafeEvmAssetBridge"
check "admin contractName"  "$(jq -r .contractName "$A")"  "ProxyAdmin"
check "deploymentName"      "$(jq -r .deploymentName "$P")" "BETH"
check "chainId"             "$(jq -r .chainId "$P")"       "$CHAIN_ID"

# A consumer outside this repo reads the schema version to detect a migration.
check "proxy schemaVersion" "$(jq -r .schemaVersion "$P")" "1"
check "impl schemaVersion"  "$(jq -r .schemaVersion "$I")" "1"
check "admin schemaVersion" "$(jq -r .schemaVersion "$A")" "1"

# The proxy's third constructor argument is the initialize calldata.
check "impl has no ctor args" "$(jq -r .encodedConstructorArgs "$I")" "0x"

PROXY_ADDR=$(jq -r .address "$P")
IMPL_ADDR=$(jq -r .address "$I")
ADMIN_ADDR=$(jq -r .address "$A")

# Argument 1 of the proxy constructor is the implementation address.
DECODED_IMPL=$(cast abi-decode --input "c(address,address,bytes)" "$(jq -r .encodedConstructorArgs "$P")" | head -1)
check "proxy arg0 == implementation" "$(cast to-check-sum-address "$DECODED_IMPL")" "$(cast to-check-sum-address "$IMPL_ADDR")"

# The ProxyAdmin's only constructor argument is its owner.
DECODED_OWNER=$(cast abi-decode --input "c(address)" "$(jq -r .encodedConstructorArgs "$A")")
check "proxyAdmin arg0 == PROXY_OWNER" "$(cast to-check-sum-address "$DECODED_OWNER")" "$(cast to-check-sum-address "$PROXY_OWNER")"
check "proxyAdmin owner field"         "$(cast to-check-sum-address "$(jq -r .owner "$A")")" "$(cast to-check-sum-address "$PROXY_OWNER")"
check "proxyAdmin createdBy"           "$(cast to-check-sum-address "$(jq -r .createdBy "$A")")" "$(cast to-check-sum-address "$PROXY_ADDR")"

# The proxy record links the other two.
check "proxy.implementation" "$(cast to-check-sum-address "$(jq -r .implementation "$P")")" "$(cast to-check-sum-address "$IMPL_ADDR")"
check "proxy.proxyAdmin"     "$(cast to-check-sum-address "$(jq -r .proxyAdmin "$P")")"     "$(cast to-check-sum-address "$ADMIN_ADDR")"

# The bridge configuration is nested on the proxy record only.
check "bridgeConfig.threshold" "$(jq -r .bridgeConfig.threshold "$P")" "2"
check "bridgeConfig.targetDecimals" "$(jq -r .bridgeConfig.targetDecimals "$P")" "10"
check "bridgeConfig.assetDecimals"  "$(jq -r .bridgeConfig.assetDecimals "$P")" "18"
check "bridgeConfig.depositUnit"    "$(jq -r .bridgeConfig.depositUnit "$P")" "100000000"
check "bridgeConfig.attestors" "$(jq -r '.bridgeConfig.attestors | length' "$P")" "3"
check "no bridgeConfig on impl" "$(jq -r 'has("bridgeConfig")' "$I")" "false"

# Receipt and provenance.
check "receipt status"  "$(jq -r .receipt.status "$P")" "0x1"
check "has txHash"      "$(jq -r '.transactionHash | startswith("0x")' "$P")" "true"
check "has gitCommit"   "$(jq -r '.gitCommit | length > 0' "$P")" "true"
check "has deployedAt"  "$(jq -r '.deployedAt | length > 0' "$P")" "true"
check "numDeployments"  "$(jq -r .numDeployments "$P")" "1"
check "history empty"   "$(jq -r '.history | length' "$P")" "0"

# The artifact goes in whole, under one key.
check "artifact.abi present" "$(jq -r '.artifact.abi | length > 0' "$I")" "true"
check "compiler version"     "$(jq -r .compiler.version "$I")" "0.8.34+commit.80d5c536"

# The compiler input exists and parses.
HASH=$(jq -r .solcInputHash "$I")
check "solcInput exists" "$([ -f "deployments/solcInputs/$HASH.json" ] && echo yes || echo no)" "yes"
check "solcInput parses" "$(jq -r .language "deployments/solcInputs/$HASH.json")" "Solidity"

# The proxy stores its own compiler input. The history checks below rely on
# that difference, because a history entry must never name the proxy's input.
check "the proxy has its own compiler input" \
  "$([ "$(jq -r .solcInputHash "$P")" = "$HASH" ] && echo same || echo different)" "different"

IMPL_TX=$(jq -r .transactionHash "$I")

echo "== second deploy: history =="
forge script script/Deploy_BETH.s.sol:Deploy_BETH \
  --rpc-url "$RPC" --broadcast --private-key "$PRIVATE_KEY" >/dev/null
./script/record.sh BETH

check "numDeployments now 2" "$(jq -r .numDeployments "$P")" "2"
check "history has one entry" "$(jq -r '.history | length' "$P")" "1"
check "history names the old implementation" \
  "$(cast to-check-sum-address "$(jq -r '.history[0].implementation' "$P")")" \
  "$(cast to-check-sum-address "$IMPL_ADDR")"

# The entry must describe the OLD implementation, never the proxy. An operator
# verifies that implementation later from these fields alone.
check "history names the old contract"      "$(jq -r '.history[0].contractName' "$P")"    "BitSafeEvmAssetBridge"
check "history names the old solc input"    "$(jq -r '.history[0].solcInputHash' "$P")"   "$HASH"
check "history names the old transaction"   "$(jq -r '.history[0].transactionHash' "$P")" "$IMPL_TX"
check "history keeps the old commit"        "$(jq -r '.history[0].gitCommit | length > 0' "$P")" "true"
check "history keeps the old timestamp"     "$(jq -r '.history[0].deployedAt | length > 0' "$P")" "true"

echo "== two pending files =="
# A string sort puts 31337 ahead of 8453. The writer must never guess, or a
# local test run would hijack a deploy to another chain.
mkdir -p deployments/.pending
printf '{"chainId":31337}' >"deployments/.pending/BETH.$CHAIN_ID.json"
printf '{"chainId":8453}' >deployments/.pending/BETH.8453.json
set +e
OUT=$(./script/record.sh BETH 2>&1)
RC=$?
set -e
check "refuses two pending files" "$RC" "1"
contains "names the other chain's file" "$OUT" "deployments/.pending/BETH.8453.json"

set +e
OUT=$(./script/record.sh BETH 8453 2>&1)
RC=$?
set -e
check "the chain id picks the exact file" "$RC" "1"
contains "reaches the chain it was given" "$OUT" "broadcast/Deploy_BETH.s.sol/8453/run-latest.json"
rm -rf deployments/.pending

echo
if [ "$FAILURES" -eq 0 ]; then echo "record.t.sh: all checks passed"; else echo "record.t.sh: $FAILURES check(s) failed"; exit 1; fi
