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

# check, contains, anvil, the BETH deploy and the compiler-input rule live in
# one file, so every tooling test sets up and cleans up the same way.
. "$ROOT/test/tooling/lib.sh"

echo "== the deploy target quotes the RPC URL =="
# An RPC URL often carries a query string. An unquoted `&` makes the shell run
# `forge script` in the background, so `make deploy` reports success while the
# deploy still runs. `make -n` prints the recipe and runs nothing.
MK_URL='https://rpc.example/v2?key=abc&mode=fast'
set +e
MK_OUT=$(make -n deploy DEPLOYMENT=BETH RPC_URL="$MK_URL" SIGNER='--account d' 2>&1)
MK_RC=$?
set -e
check    "make -n reads the deploy target" "$MK_RC" "0"
contains "quotes the URL for forge script" "$MK_OUT" "--rpc-url \"$MK_URL\" --broadcast"
contains "quotes the URL for cast"         "$MK_OUT" "cast chain-id --rpc-url \"$MK_URL\""

cleanup() {
  anvil_stop "$PORT"
  prune_untracked_solc_inputs
}
trap cleanup EXIT

echo "== starting anvil on port $PORT =="
anvil_start "$PORT"

# Every delete here names chain $CHAIN_ID. `broadcast/` and a pending file both
# stay out of git, and they hold the only copy of a real deploy's transactions.
# A wider delete would take a mainnet deploy's provenance with it.
rm -rf "deployments/BETH."*".$CHAIN_ID.json" "broadcast/Deploy_BETH.s.sol/$CHAIN_ID"
rm -f "deployments/.pending/BETH.$CHAIN_ID.json"

echo "== deploying and recording =="
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
deploy_beth "$RPC" "$DEPLOYER_KEY"

echo "== checks =="
P="deployments/BETH.proxy.$CHAIN_ID.json"
I="deployments/BETH.implementation.$CHAIN_ID.json"
A="deployments/BETH.proxyAdmin.$CHAIN_ID.json"
T="deployments/BETH.timelock.$CHAIN_ID.json"

for f in "$P" "$I" "$A" "$T"; do
  if [ -f "$f" ]; then echo "  ok   $f exists"; else echo "  FAIL $f missing"; FAILURES=$((FAILURES + 1)); fi
done

check "pending file removed" \
  "$([ -f "deployments/.pending/BETH.$CHAIN_ID.json" ] && echo present || echo gone)" "gone"

check "proxy role"          "$(jq -r .role "$P")"          "proxy"
check "proxy contractName"  "$(jq -r .contractName "$P")"  "TransparentUpgradeableProxy"
check "impl contractName"   "$(jq -r .contractName "$I")"  "BitSafeEvmAssetBridge"
check "admin contractName"  "$(jq -r .contractName "$A")"  "ProxyAdmin"
check "timelock contractName" "$(jq -r .contractName "$T")" "TimelockController"
check "deploymentName"      "$(jq -r .deploymentName "$P")" "BETH"
check "chainId"             "$(jq -r .chainId "$P")"       "$CHAIN_ID"

# A consumer outside this repo reads the schema version to detect a migration.
check "proxy schemaVersion" "$(jq -r .schemaVersion "$P")" "2"
check "impl schemaVersion"  "$(jq -r .schemaVersion "$I")" "2"
check "admin schemaVersion" "$(jq -r .schemaVersion "$A")" "2"
check "timelock schemaVersion" "$(jq -r .schemaVersion "$T")" "2"

# The proxy's third constructor argument is the initialize calldata.
check "impl has no ctor args" "$(jq -r .encodedConstructorArgs "$I")" "0x"

PROXY_ADDR=$(jq -r .address "$P")
IMPL_ADDR=$(jq -r .address "$I")
ADMIN_ADDR=$(jq -r .address "$A")
TIMELOCK_ADDR=$(jq -r .address "$T")
ZERO=0x0000000000000000000000000000000000000000

# Argument 1 of the proxy constructor is the implementation address.
DECODED_ALL=$(cast abi-decode --input "c(address,address,bytes)" "$(jq -r .encodedConstructorArgs "$P")")
DECODED_IMPL=${DECODED_ALL%%$'\n'*}
check "proxy arg0 == implementation" "$(cast to-check-sum-address "$DECODED_IMPL")" "$(cast to-check-sum-address "$IMPL_ADDR")"

# The timelock owns the ProxyAdmin, so the ProxyAdmin's only constructor
# argument and its owner field both name the timelock.
DECODED_OWNER=$(cast abi-decode --input "c(address)" "$(jq -r .encodedConstructorArgs "$A")")
check "proxyAdmin arg0 == timelock" "$(cast to-check-sum-address "$DECODED_OWNER")" "$(cast to-check-sum-address "$TIMELOCK_ADDR")"
check "proxyAdmin deployTimeConfig.owner" "$(cast to-check-sum-address "$(jq -r .deployTimeConfig.owner "$A")")" "$(cast to-check-sum-address "$TIMELOCK_ADDR")"
check "proxyAdmin createdBy"        "$(cast to-check-sum-address "$(jq -r .createdBy "$A")")" "$(cast to-check-sum-address "$PROXY_ADDR")"

# The record keeps the timelock's deploy-time configuration.
check "timelock role"     "$(jq -r .role "$T")"     "timelock"
check "timelock deployTimeConfig.minDelay" "$(jq -r .deployTimeConfig.minDelay "$T")" "$TIMELOCK_DELAY"
check "timelock proposers" "$(jq -r '.deployTimeConfig.proposers | length' "$T")" "1"
check "timelock proposer is PROXY_OWNER" \
  "$(cast to-check-sum-address "$(jq -r '.deployTimeConfig.proposers[0]' "$T")")" "$(cast to-check-sum-address "$PROXY_OWNER")"
check "timelock executors" "$(jq -r '.deployTimeConfig.executors | length' "$T")" "1"
check "timelock executor is PROXY_OWNER" \
  "$(cast to-check-sum-address "$(jq -r '.deployTimeConfig.executors[0]' "$T")")" "$(cast to-check-sum-address "$PROXY_OWNER")"
# The zero admin makes the timelock its own admin.
check "timelock admin is zero" "$(jq -r .deployTimeConfig.admin "$T")" "$ZERO"

# The constructor arguments agree with the four fields above.
TL_ARGS=$(cast abi-decode --input "c(uint256,address[],address[],address)" "$(jq -r .encodedConstructorArgs "$T")")
check "timelock arg0 == TIMELOCK_DELAY" "$(printf '%s' "$TL_ARGS" | sed -n 1p)" "$TIMELOCK_DELAY"
check "timelock arg1 == [PROXY_OWNER]" \
  "$(printf '%s' "$TL_ARGS" | sed -n 2p | tr -d '[] ' | tr 'A-F' 'a-f')" "$(lower "$PROXY_OWNER")"
check "timelock arg2 == [PROXY_OWNER]" \
  "$(printf '%s' "$TL_ARGS" | sed -n 3p | tr -d '[] ' | tr 'A-F' 'a-f')" "$(lower "$PROXY_OWNER")"
check "timelock arg3 == zero" "$(printf '%s' "$TL_ARGS" | sed -n 4p | tr 'A-F' 'a-f')" "$ZERO"
check "no bridgeConfig on timelock" "$(jq -r 'has("bridgeConfig")' "$T")" "false"

# The proxy record links the other two.
check "proxy.implementation" "$(cast to-check-sum-address "$(jq -r .implementation "$P")")" "$(cast to-check-sum-address "$IMPL_ADDR")"
check "proxy.proxyAdmin"     "$(cast to-check-sum-address "$(jq -r .proxyAdmin "$P")")"     "$(cast to-check-sum-address "$ADMIN_ADDR")"
check "deployTimeConfig.timelock" "$(cast to-check-sum-address "$(jq -r .deployTimeConfig.timelock "$P")")" "$(cast to-check-sum-address "$TIMELOCK_ADDR")"
check "deployTimeConfig.timelockDelay" "$(jq -r .deployTimeConfig.timelockDelay "$P")" "$TIMELOCK_DELAY"
check "deployTimeConfig.proxyOwner"    "$(cast to-check-sum-address "$(jq -r .deployTimeConfig.proxyOwner "$P")")" "$(cast to-check-sum-address "$PROXY_OWNER")"

# The deploy-time configuration of the bridge is nested on the proxy record only.
check "deployTimeConfig.threshold" "$(jq -r .deployTimeConfig.threshold "$P")" "2"
check "deployTimeConfig.targetDecimals" "$(jq -r .deployTimeConfig.targetDecimals "$P")" "10"
check "deployTimeConfig.assetDecimals"  "$(jq -r .deployTimeConfig.assetDecimals "$P")" "18"
check "deployTimeConfig.depositUnit"    "$(jq -r .deployTimeConfig.depositUnit "$P")" "100000000"
check "deployTimeConfig.attestors" "$(jq -r '.deployTimeConfig.attestors | length' "$P")" "3"
check "proxy deployTimeConfig keys" "$(jq -c '.deployTimeConfig | keys_unsorted' "$P")" \
  '["asset","assetDecimals","targetDecimals","depositUnit","defaultAdmin","adminDelay","bridgeAdmin","proxyOwner","timelock","timelockDelay","attestors","threshold","depositLimits","withdrawLimits"]'
check "timelock deployTimeConfig keys" "$(jq -c '.deployTimeConfig | keys_unsorted' "$T")" \
  '["minDelay","proposers","executors","admin"]'
check "proxyAdmin deployTimeConfig keys" "$(jq -c '.deployTimeConfig | keys_unsorted' "$A")" '["owner"]'
check "no bridgeConfig on proxy" "$(jq -r 'has("bridgeConfig")' "$P")" "false"
check "no top-level minDelay" "$(jq -r 'has("minDelay")' "$T")" "false"
check "no top-level owner" "$(jq -r 'has("owner")' "$A")" "false"
check "no deployTimeConfig on impl" "$(jq -r 'has("deployTimeConfig")' "$I")" "false"

# Receipt and provenance.
check "receipt status"  "$(jq -r .receipt.status "$P")" "0x1"
check "has txHash"      "$(jq -r '.transactionHash | startswith("0x")' "$P")" "true"

# Every record must name its own creation. foundry sends the transactions and
# collects the hashes separately, and it sometimes writes one entry's hash
# beside the other entry's contractAddress. We measured that on 4 of 8 local
# deploys. A record built from `transactions[].hash` then carries the other
# contract's receipt, so record.sh reads the hash from the receipt instead.
check "the impl receipt names the impl" \
  "$(cast to-check-sum-address "$(jq -r .receipt.contractAddress "$I")")" \
  "$(cast to-check-sum-address "$IMPL_ADDR")"
check "the proxy receipt names the proxy" \
  "$(cast to-check-sum-address "$(jq -r .receipt.contractAddress "$P")")" \
  "$(cast to-check-sum-address "$PROXY_ADDR")"

check "the timelock receipt names the timelock" \
  "$(cast to-check-sum-address "$(jq -r .receipt.contractAddress "$T")")" \
  "$(cast to-check-sum-address "$TIMELOCK_ADDR")"

# The ProxyAdmin has no transaction of its own. Its creator's receipt records it.
check "the admin receipt names its creator" \
  "$(cast to-check-sum-address "$(jq -r .receipt.contractAddress "$A")")" \
  "$(cast to-check-sum-address "$(jq -r .createdBy "$A")")"

for f in "$P" "$I" "$A" "$T"; do
  check "$(basename "$f") agrees with its receipt" \
    "$(jq -r '.transactionHash == .receipt.transactionHash' "$f")" "true"
done
check "has gitCommit"   "$(jq -r '.gitCommit | length > 0' "$P")" "true"
check "has deployedAt"  "$(jq -r '.deployedAt | length > 0' "$P")" "true"
check "numDeployments"  "$(jq -r .numDeployments "$P")" "1"
check "history empty"   "$(jq -r '.history | length' "$P")" "0"

# The record keeps the ABI and the compiler settings, and nothing else from the
# build artifact.
check "abi present"      "$(jq -r '.abi | length > 0' "$I")" "true"
check "compiler version" "$(jq -r .compiler.version "$I")" "0.8.34+commit.80d5c536"

# An operator commits these files, so they must name no local path. foundry
# writes seven of its remappings as absolute paths. Those reach the build
# artifact under `metadata.settings.remappings` and `rawMetadata`, so the record
# keeps the ABI alone. Dropping the artifact also cuts the records for one
# chain from 290 KB to about 20 KB.
for f in "$P" "$I" "$A" "$T"; do
  b=$(basename "$f")
  check "no build artifact in $b" "$(jq -r 'has("artifact")' "$f")" "false"
  check "no absolute path in $b"  "$(grep -c -E '/(Users|home|root)/' "$f" || true)" "0"
  check "$b stays small"          "$([ "$(wc -c <"$f")" -lt 60000 ] && echo yes || echo no)" "yes"
done

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
deploy_beth "$RPC" "$DEPLOYER_KEY"

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
check "second deploy keeps deployTimeConfig" "$(jq -r 'has("deployTimeConfig") and (has("bridgeConfig") | not)' "$P")" "true"

echo "== a pending file that names no roles =="
# A missing roles array reads as length zero. `seq 0 -1` prints nothing on Linux
# but counts down on macOS. So the old loop either recorded nothing and reported
# success, or it ran twice on null. The writer must refuse the file and keep it.
mkdir -p deployments/.pending
NO_ROLES="deployments/.pending/BETH.$CHAIN_ID.json"
printf '{"chainId":%s,"deploymentName":"BETH"}' "$CHAIN_ID" >"$NO_ROLES"
set +e
OUT=$(./script/record.sh BETH "$CHAIN_ID" 2>&1)
RC=$?
set -e
check    "refuses a pending file with no roles" "$RC" "1"
contains "says what the file must hold" "$OUT" "four arrays of one non-zero length"
check    "keeps the pending file" \
  "$([ -f "$NO_ROLES" ] && echo kept || echo gone)" "kept"
check    "leaves the proxy record alone" "$(jq -r .role "$P")" "proxy"
rm -f "$NO_ROLES"

echo "== a pending file whose arrays disagree =="
printf '{"chainId":%s,"roles":["a","b"],"addresses":["0x1"],"contractNames":["C"],"sourcePaths":["s"]}' \
  "$CHAIN_ID" >"$NO_ROLES"
set +e
OUT=$(./script/record.sh BETH "$CHAIN_ID" 2>&1)
RC=$?
set -e
check    "refuses arrays of different lengths" "$RC" "1"
contains "names the roles it read" "$OUT" "it holds roles"
rm -f "$NO_ROLES"
rmdir deployments/.pending 2>/dev/null || true

echo "== two pending files =="
# A string sort puts 31337 ahead of 8453. The writer must never guess, or a
# local test run would hijack a deploy to another chain.
#
# This block writes a file for chain 8453, so it uses a deployment name that no
# deploy uses. The name BETH would overwrite, and then delete, a real pending
# file for Base.
mkdir -p deployments/.pending
FAKE_NAME=RECORDTEST
FAKE_LOCAL="deployments/.pending/$FAKE_NAME.$CHAIN_ID.json"
FAKE_OTHER="deployments/.pending/$FAKE_NAME.8453.json"
printf '{"chainId":%s}' "$CHAIN_ID" >"$FAKE_LOCAL"
printf '{"chainId":8453}' >"$FAKE_OTHER"
set +e
OUT=$(./script/record.sh "$FAKE_NAME" 2>&1)
RC=$?
set -e
check "refuses two pending files" "$RC" "1"
contains "names the other chain's file" "$OUT" "$FAKE_OTHER"

set +e
OUT=$(./script/record.sh "$FAKE_NAME" 8453 2>&1)
RC=$?
set -e
check "the chain id picks the exact file" "$RC" "1"
contains "reaches the chain it was given" "$OUT" "broadcast/Deploy_$FAKE_NAME.s.sol/8453/run-latest.json"
rm -f "$FAKE_LOCAL" "$FAKE_OTHER"
rmdir deployments/.pending 2>/dev/null || true

echo "== a pending file that names another broadcast script =="
# DeployNextImplementation writes under its own broadcast folder. The pending
# file names it, and record.sh reads that folder. The throwaway name keeps a
# real record safe.
OTHER_SCRIPT="Other_$FAKE_NAME.s.sol"
mkdir -p deployments/.pending "broadcast/$OTHER_SCRIPT/$CHAIN_ID"
cp "broadcast/Deploy_BETH.s.sol/$CHAIN_ID/run-latest.json" "broadcast/$OTHER_SCRIPT/$CHAIN_ID/run-latest.json"
CURRENT_IMPL=$(jq -r .address "$I")
jq -n --arg name "$FAKE_NAME" --argjson chainId "$CHAIN_ID" --arg script "$OTHER_SCRIPT" --arg addr "$CURRENT_IMPL" \
  '{deploymentName: $name, chainId: $chainId, broadcastScript: $script,
    roles: ["nextImplementation"], addresses: [$addr],
    contractNames: ["BitSafeEvmAssetBridge"], sourcePaths: ["src/BitSafeEvmAssetBridge.sol"]}' \
  >"$FAKE_LOCAL"
set +e
OUT=$(./script/record.sh "$FAKE_NAME" "$CHAIN_ID" 2>&1)
RC=$?
set -e
check    "reads the named broadcast folder" "$RC" "0"
NEXT_RECORD="deployments/$FAKE_NAME.nextImplementation.$CHAIN_ID.json"
check    "writes the nextImplementation record" "$([ -f "$NEXT_RECORD" ] && echo present || echo missing)" "present"
check    "record address" "$(cast to-check-sum-address "$(jq -r .address "$NEXT_RECORD")")" "$(cast to-check-sum-address "$CURRENT_IMPL")"
check    "record role" "$(jq -r .role "$NEXT_RECORD")" "nextImplementation"
contains "records the role" "$OUT" "recorded nextImplementation"
contains "prints done"                       "$OUT" "done."
case "$OUT" in
  *"The proxy record is"*) PROXY_LINE=present ;;
  *) PROXY_LINE=absent ;;
esac
check    "prints no proxy record line"       "$PROXY_LINE" "absent"
rm -f "$NEXT_RECORD"
rm -rf "broadcast/$OTHER_SCRIPT"

echo "== a broadcast script with a slash is refused =="
mkdir -p deployments/.pending
jq -n --arg name "$FAKE_NAME" --argjson chainId "$CHAIN_ID" --arg addr "$CURRENT_IMPL" \
  '{deploymentName: $name, chainId: $chainId, broadcastScript: "../Deploy_BETH.s.sol",
    roles: ["nextImplementation"], addresses: [$addr],
    contractNames: ["BitSafeEvmAssetBridge"], sourcePaths: ["src/BitSafeEvmAssetBridge.sol"]}' \
  >"$FAKE_LOCAL"
set +e
OUT=$(./script/record.sh "$FAKE_NAME" "$CHAIN_ID" 2>&1)
RC=$?
set -e
check    "refuses a path" "$RC" "1"
contains "names the rule" "$OUT" "must be one file name"
rm -f "$FAKE_LOCAL"
rmdir deployments/.pending 2>/dev/null || true

echo
if [ "$FAILURES" -eq 0 ]; then echo "record.t.sh: all checks passed"; else echo "record.t.sh: $FAILURES check(s) failed"; exit 1; fi
