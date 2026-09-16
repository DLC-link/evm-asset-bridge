#!/usr/bin/env bash
# Runs the whole upgrade sequence against a local anvil, then checks the
# records that script/record-upgrade.sh writes.
#
# The sequence: deploy, DeployImplementation, record, ScheduleUpgrade, wait,
# ExecuteUpgrade, record-upgrade. The deploy needs the timelock, so this test
# passes only on a tree where Deploy_BETH reads TIMELOCK_DELAY.
set -euo pipefail

export PATH="$HOME/.foundry/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

PORT=8548
RPC="http://127.0.0.1:$PORT"
CHAIN_ID=31337
FAILURES=0

# check, contains, and the compiler-input rule live in one file. The other
# tooling tests source the same file, so every test cleans up the same way.
. "$ROOT/test/tooling/lib.sh"

echo "== the record-upgrade target passes its three variables =="
MK_URL='https://rpc.example/v2?key=abc&mode=fast'
set +e
MK_OUT=$(make -n record-upgrade DEPLOYMENT=BETH CHAIN_ID=8453 RPC_URL="$MK_URL" 2>&1)
MK_RC=$?
set -e
check    "make -n reads the target" "$MK_RC" "0"
contains "quotes the URL"           "$MK_OUT" "RPC_URL=\"$MK_URL\""
contains "passes the chain id"      "$MK_OUT" 'CHAIN_ID="8453"'
contains "names the deployment"     "$MK_OUT" "./script/record-upgrade.sh BETH"
set +e
make -n record-upgrade DEPLOYMENT=BETH CHAIN_ID=8453 >/dev/null 2>&1
MK_RC=$?
set -e
check "refuses a run without RPC_URL" "$([ "$MK_RC" -ne 0 ] && echo refused || echo ran)" "refused"

cleanup() {
  pkill -f "anvil --port $PORT" >/dev/null 2>&1 || true
  prune_untracked_solc_inputs
}
trap cleanup EXIT

echo "== starting anvil on port $PORT =="
cleanup
anvil --port "$PORT" --silent &
# The wait must end. An anvil that never answers would otherwise keep this
# script, and the CI job that runs it, alive until the job's own timeout.
WAITED=0
until cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; do
  sleep 0.2
  WAITED=$((WAITED + 1))
  if [ "$WAITED" -ge 150 ]; then
    echo "record-upgrade.t.sh: anvil did not answer on $RPC within 30 seconds" >&2
    exit 1
  fi
done

# Every delete here names chain $CHAIN_ID. `broadcast/` and a pending file both
# stay out of git, and they hold the only copy of a real deploy's transactions.
rm -rf "deployments/BETH."*".$CHAIN_ID.json" \
  "broadcast/Deploy_BETH.s.sol/$CHAIN_ID" "broadcast/DeployImplementation.s.sol/$CHAIN_ID"
rm -f "deployments/.pending/BETH.$CHAIN_ID.json"

echo "== deploying with a 5 second timelock =="
# Anvil's default accounts. These keys are public and well known.
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
# Account 3 is the proxy owner. It holds the three timelock roles.
PROXY_OWNER_KEY=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
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
export TIMELOCK_DELAY=5

forge script script/Deploy_BETH.s.sol:Deploy_BETH \
  --rpc-url "$RPC" --broadcast --private-key "$PRIVATE_KEY" >/dev/null
./script/record.sh BETH >/dev/null

P="deployments/BETH.proxy.$CHAIN_ID.json"
I="deployments/BETH.implementation.$CHAIN_ID.json"
T="deployments/BETH.timelock.$CHAIN_ID.json"
N="deployments/BETH.nextImplementation.$CHAIN_ID.json"

if [ ! -f "$T" ]; then
  echo "record-upgrade.t.sh: no timelock record at $T" >&2
  echo "record-upgrade.t.sh: this test needs the deploy that places a timelock before the ProxyAdmin" >&2
  exit 1
fi
check "the timelock delay is recorded" "$(jq -r .minDelay "$T")" "5"
OLD_IMPL=$(jq -r .address "$I")
PROXY_ADDR=$(jq -r .address "$P")
OLD_SOLC=$(jq -r .solcInputHash "$I")
OLD_TX=$(jq -r .transactionHash "$I")

export DEPLOYMENT=BETH
export RPC_URL="$RPC"
SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
onchain_impl() { cast to-check-sum-address "0x$(cast storage "$PROXY_ADDR" "$SLOT" --rpc-url "$RPC" | cut -c27-66)"; }

echo "== DeployImplementation writes the next implementation =="
forge script script/manage/BitSafeEvmAssetBridge/DeployImplementation.s.sol:DeployImplementation \
  --sig 'run()' --rpc-url "$RPC" --broadcast --private-key "$PRIVATE_KEY" >/dev/null
PENDING="deployments/.pending/BETH.$CHAIN_ID.json"
check "writes a pending file"      "$([ -f "$PENDING" ] && echo yes || echo no)" "yes"
check "names its broadcast script" "$(jq -r .broadcastScript "$PENDING")" "DeployImplementation.s.sol"
check "registers one role"         "$(jq -r '.roles | join(",")' "$PENDING")" "nextImplementation"

echo "== record writes the nextImplementation record =="
./script/record.sh BETH >/dev/null
check "next record exists"   "$([ -f "$N" ] && echo yes || echo no)" "yes"
check "next record role"     "$(jq -r .role "$N")" "nextImplementation"
check "next record contract" "$(jq -r .contractName "$N")" "BitSafeEvmAssetBridge"
NEXT_IMPL=$(jq -r .address "$N")
check "the next implementation is new" \
  "$([ "$(echo "$NEXT_IMPL" | tr 'A-Z' 'a-z')" = "$(echo "$OLD_IMPL" | tr 'A-Z' 'a-z')" ] && echo same || echo different)" "different"
check "the proxy still runs the old implementation" "$(onchain_impl)" "$(cast to-check-sum-address "$OLD_IMPL")"
check "the proxy record still names the old implementation" \
  "$(cast to-check-sum-address "$(jq -r .implementation "$P")")" "$(cast to-check-sum-address "$OLD_IMPL")"

echo "== record-upgrade refuses before the execute =="
set +e
OUT=$(./script/record-upgrade.sh BETH "$CHAIN_ID" 2>&1)
RC=$?
set -e
check    "exit status" "$RC" "1"
contains "says the proxy does not point at the next implementation" "$OUT" "does not point at the next implementation"
contains "names the fix" "$OUT" "run ExecuteUpgrade first"
check "keeps the next record"   "$([ -f "$N" ] && echo yes || echo no)" "yes"
check "leaves the proxy record" "$(jq -r '.history | length' "$P")" "0"
check "leaves no temporary"     "$(ls deployments/BETH.*.tmp 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "== ScheduleUpgrade from the proxy owner =="
OUT=$(forge script script/manage/BitSafeEvmAssetBridge/ScheduleUpgrade.s.sol:ScheduleUpgrade \
  --sig 'run(bytes)' 0x --rpc-url "$RPC" --broadcast --private-key "$PROXY_OWNER_KEY" 2>&1)
check    "schedule exit status" "$?" "0"
contains "prints the earliest execute time" "$OUT" "earliest execute at"

echo "== ExecuteUpgrade before the delay reverts =="
set +e
OUT=$(forge script script/manage/BitSafeEvmAssetBridge/ExecuteUpgrade.s.sol:ExecuteUpgrade \
  --sig 'run(bytes)' 0x --rpc-url "$RPC" --broadcast --private-key "$PROXY_OWNER_KEY" 2>&1)
RC=$?
set -e
check    "execute fails early" "$([ "$RC" -ne 0 ] && echo failed || echo passed)" "failed"
contains "names the timelock state error" "$OUT" "TimelockUnexpectedOperationState"
check    "the proxy did not change" "$(onchain_impl)" "$(cast to-check-sum-address "$OLD_IMPL")"

echo "== wait past the delay, then ExecuteUpgrade =="
cast rpc evm_increaseTime 6 --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null
forge script script/manage/BitSafeEvmAssetBridge/ExecuteUpgrade.s.sol:ExecuteUpgrade \
  --sig 'run(bytes)' 0x --rpc-url "$RPC" --broadcast --private-key "$PROXY_OWNER_KEY" >/dev/null
check "the proxy runs the next implementation" "$(onchain_impl)" "$(cast to-check-sum-address "$NEXT_IMPL")"

echo "== record-upgrade promotes the record =="
OUT=$(./script/record-upgrade.sh BETH "$CHAIN_ID" 2>&1)
check    "exit status" "$?" "0"
contains "prints the implementation path" "$OUT" "$I"
contains "prints the proxy path"          "$OUT" "$P"
check "the next record is gone"   "$([ -f "$N" ] && echo present || echo gone)" "gone"
check "impl record address"       "$(cast to-check-sum-address "$(jq -r .address "$I")")" "$(cast to-check-sum-address "$NEXT_IMPL")"
check "impl record role"          "$(jq -r .role "$I")" "implementation"
check "impl record contract"      "$(jq -r .contractName "$I")" "BitSafeEvmAssetBridge"
check "proxy.implementation"      "$(cast to-check-sum-address "$(jq -r .implementation "$P")")" "$(cast to-check-sum-address "$NEXT_IMPL")"
check "numDeployments now 2"      "$(jq -r .numDeployments "$P")" "2"
check "history has one entry"     "$(jq -r '.history | length' "$P")" "1"
check "history names the old implementation" \
  "$(cast to-check-sum-address "$(jq -r '.history[0].implementation' "$P")")" "$(cast to-check-sum-address "$OLD_IMPL")"
check "history names the old contract"    "$(jq -r '.history[0].contractName' "$P")"    "BitSafeEvmAssetBridge"
check "history names the old solc input"  "$(jq -r '.history[0].solcInputHash' "$P")"   "$OLD_SOLC"
check "history names the old transaction" "$(jq -r '.history[0].transactionHash' "$P")" "$OLD_TX"
check "history keeps the old commit"      "$(jq -r '.history[0].gitCommit | length > 0' "$P")" "true"
check "history keeps the old timestamp"   "$(jq -r '.history[0].deployedAt | length > 0' "$P")" "true"
check "the proxy record keeps its address" "$(cast to-check-sum-address "$(jq -r .address "$P")")" "$(cast to-check-sum-address "$PROXY_ADDR")"
check "the proxy record keeps its role"    "$(jq -r .role "$P")" "proxy"
check "the proxy record keeps its config"  "$(jq -r .bridgeConfig.threshold "$P")" "2"
check "leaves no temporary" "$(ls deployments/BETH.*.tmp 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "== a second run refuses, because no next record waits =="
set +e
OUT=$(./script/record-upgrade.sh BETH "$CHAIN_ID" 2>&1)
RC=$?
set -e
check    "exit status" "$RC" "1"
contains "names the missing record" "$OUT" "$N"
check    "history unchanged" "$(jq -r '.history | length' "$P")" "1"

echo "== a run without RPC_URL stops with usage =="
set +e
OUT=$(RPC_URL= ./script/record-upgrade.sh BETH "$CHAIN_ID" 2>&1)
RC=$?
set -e
check    "exit status" "$RC" "2"
contains "prints usage" "$OUT" "usage:"

echo
if [ "$FAILURES" -eq 0 ]; then echo "record-upgrade.t.sh: all checks passed"; else echo "record-upgrade.t.sh: $FAILURES check(s) failed"; exit 1; fi
