#!/usr/bin/env bash
# Runs the upgrade targets against a local anvil and checks the records that
# script/upgrade-sync.sh writes. The first section reads the recipes only.
set -euo pipefail

export PATH="$HOME/.foundry/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

PORT=8549
RPC="http://127.0.0.1:$PORT"
CHAIN_ID=31337
FAILURES=0

. "$ROOT/test/tooling/lib.sh"

lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
count() { grep -c "$2" <<<"$1" || true; }

echo "== the upgrade targets quote the RPC URL and sync around each step =="
MK_URL='https://rpc.example/v2?key=abc&mode=fast'
set +e
MK_OUT=$(make -n upgrade-deploy DEPLOYMENT=BETH RPC_URL="$MK_URL" SIGNER='--account d' 2>&1)
MK_RC=$?
set -e
check    "upgrade-deploy reads"            "$MK_RC" "0"
contains "deploy quotes the URL"           "$MK_OUT" "--rpc-url \"$MK_URL\" --broadcast --account d"
contains "deploy names the script"         "$MK_OUT" "DeployNextImplementation.s.sol:DeployNextImplementation"
contains "deploy records"                  "$MK_OUT" "./script/record.sh BETH"
check    "deploy syncs once"               "$(count "$MK_OUT" "upgrade-sync.sh BETH")" "1"

MK_OUT=$(make -n upgrade-schedule DEPLOYMENT=BETH RPC_URL="$MK_URL" SIGNER='--account d' DATA=0x1234 2>&1)
contains "schedule names the script"       "$MK_OUT" "ScheduleUpgrade.s.sol:ScheduleUpgrade"
contains "schedule broadcasts in direct mode" "$MK_OUT" "--broadcast --account d"
contains "schedule passes DATA"            "$MK_OUT" "DATA=\"0x1234\""
check    "schedule syncs before and after" "$(count "$MK_OUT" "upgrade-sync.sh BETH")" "2"
contains "schedule prints its mode"        "$MK_OUT" "direct broadcast"

MK_OUT=$(SAFE=0x0000000000000000000000000000000000000001 make -n upgrade-execute DEPLOYMENT=BETH RPC_URL="$MK_URL" 2>&1)
contains "execute names the script"        "$MK_OUT" "ExecuteUpgrade.s.sol:ExecuteUpgrade"
check    "Safe mode never broadcasts"      "$(count "$MK_OUT" "\-\-broadcast")" "0"
check    "Safe mode syncs once"            "$(count "$MK_OUT" "upgrade-sync.sh BETH")" "1"
contains "Safe mode prints the hint"       "$MK_OUT" "run make upgrade-sync after the Safe executes"

MK_OUT=$(make -n upgrade-cancel DEPLOYMENT=BETH RPC_URL="$MK_URL" SIGNER='--account d' 2>&1)
contains "cancel names the script"         "$MK_OUT" "CancelUpgrade.s.sol:CancelUpgrade"

MK_OUT=$(make -n upgrade-status DEPLOYMENT=BETH RPC_URL="$MK_URL" 2>&1)
check    "status syncs"                    "$(count "$MK_OUT" "upgrade-sync.sh BETH")" "1"

set +e
MK_OUT=$(make -n upgrade-sync DEPLOYMENT=BETH 2>&1)
MK_RC=$?
set -e
check    "sync refuses a missing RPC_URL"  "$([ "$MK_RC" -ne 0 ] && echo refused || echo ran)" "refused"
contains "sync names the variable"         "$MK_OUT" "RPC_URL is not set"

set +e
MK_OUT=$(SIGNER='--account d' make -n upgrade-deploy DEPLOYMENT=BETH RPC_URL="$MK_URL" 2>&1)
MK_RC=$?
set -e
check    "deploy refuses an exported SIGNER" "$([ "$MK_RC" -ne 0 ] && echo refused || echo ran)" "refused"
contains "deploy names the rule"           "$MK_OUT" "SIGNER comes from your environment"

set +e
MK_OUT=$(make -n upgrade-schedule DEPLOYMENT=BETH RPC_URL="$MK_URL" 2>&1)
MK_RC=$?
set -e
check    "direct schedule needs SIGNER"    "$([ "$MK_RC" -ne 0 ] && echo refused || echo ran)" "refused"


cleanup() {
  pkill -f "anvil --port $PORT" >/dev/null 2>&1 || true
  prune_untracked_solc_inputs
}
trap cleanup EXIT

echo "== starting anvil on port $PORT =="
cleanup
anvil --port "$PORT" --silent &
WAITED=0
until cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; do
  sleep 0.2
  WAITED=$((WAITED + 1))
  if [ "$WAITED" -ge 150 ]; then
    echo "upgrade-sync.t.sh: anvil did not answer on $RPC within 30 seconds" >&2
    exit 1
  fi
done

# Every delete names chain $CHAIN_ID. A wider delete would take a real deploy
# with it.
rm -rf "deployments/BETH."*".$CHAIN_ID.json" "broadcast/Deploy_BETH.s.sol/$CHAIN_ID" \
  "broadcast/DeployNextImplementation.s.sol/$CHAIN_ID"
rm -f "deployments/.pending/BETH.$CHAIN_ID.json"

echo "== deploying the bridge =="
# Anvil's default accounts. These keys are public and well known.
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
OWNER_KEY=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
export ASSET=0x0000000000000000000000000000000000000000
export TARGET_DECIMALS=10
export DEFAULT_ADMIN=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
export ADMIN_DELAY=0
export BRIDGE_ADMIN=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
export PROXY_OWNER=0x90F79bf6EB2c4f870365E785982E1f101E93b906
export TIMELOCK_DELAY=60
export ATTESTORS=0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65,0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc,0x976EA74026E726554dB657fA54763abd0C3a0aa9
export THRESHOLD=2
export DEPOSIT_MIN=0
export DEPOSIT_MAX=115792089237316195423570985008687907853269984665640564039457584007913129639935
export WITHDRAW_MIN=0
export WITHDRAW_MAX=115792089237316195423570985008687907853269984665640564039457584007913129639935

forge script script/Deploy_BETH.s.sol:Deploy_BETH \
  --rpc-url "$RPC" --broadcast --private-key "$DEPLOYER_KEY" >/dev/null
./script/record.sh BETH >/dev/null

P="deployments/BETH.proxy.$CHAIN_ID.json"
I="deployments/BETH.implementation.$CHAIN_ID.json"
N="deployments/BETH.nextImplementation.$CHAIN_ID.json"
T="deployments/BETH.timelock.$CHAIN_ID.json"
PREV1="deployments/BETH.previousImplementation_1.$CHAIN_ID.json"
PROXY_ADDR=$(jq -r .address "$P")
TIMELOCK_ADDR=$(jq -r .address "$T")
OLD_IMPL=$(cast to-check-sum-address "$(jq -r .address "$I")")
onchain_impl() {
  cast to-check-sum-address "0x$(cast storage "$PROXY_ADDR" 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url "$RPC" | cut -c27-66)"
}
no_temporaries() { [ -z "$(ls deployments/BETH.*.$CHAIN_ID.json.tmp 2>/dev/null)" ] && echo none || echo present; }

echo "== upgrade-sync with no next implementation =="
OUT=$(make upgrade-sync DEPLOYMENT=BETH RPC_URL="$RPC" 2>&1)
contains "reports no next" "$OUT" "next            none"
contains "reports the live implementation" "$OUT" "$OLD_IMPL"

echo "== upgrade-deploy =="
OUT=$(make upgrade-deploy DEPLOYMENT=BETH RPC_URL="$RPC" SIGNER="--private-key $DEPLOYER_KEY" 2>&1) || { echo "$OUT"; FAILURES=$((FAILURES + 1)); }
check    "next record exists"        "$([ -f "$N" ] && echo present || echo missing)" "present"
check    "next role"                 "$(jq -r .role "$N")" "nextImplementation"
check    "next contractName"         "$(jq -r .contractName "$N")" "BitSafeEvmAssetBridge"
NEXT_IMPL=$(cast to-check-sum-address "$(jq -r .address "$N")")
check    "next differs from the old" "$([ "$NEXT_IMPL" != "$OLD_IMPL" ] && echo yes || echo no)" "yes"
check    "proxy record untouched"    "$(cast to-check-sum-address "$(jq -r .implementation "$P")")" "$OLD_IMPL"
check    "proxy still on the old"    "$(onchain_impl)" "$OLD_IMPL"
contains "sync reports not scheduled" "$OUT" "state           not scheduled"
check    "no schedule block yet"     "$(jq -r 'has("schedule")' "$N")" "false"

echo "== a second upgrade-deploy refuses =="
set +e
OUT=$(make upgrade-deploy DEPLOYMENT=BETH RPC_URL="$RPC" SIGNER="--private-key $DEPLOYER_KEY" 2>&1)
RC=$?
set -e
check    "refuses"                   "$([ "$RC" -ne 0 ] && echo refused || echo ran)" "refused"
contains "names the record"          "$OUT" "NextImplementationExists"

echo "== verify lists the next implementation =="
# A dry run still needs a key. The value never leaves the machine.
OUT=$(DRY_RUN=1 ETHERSCAN_API_KEY=testkey make verify DEPLOYMENT=BETH CHAIN_ID="$CHAIN_ID" 2>&1) || { echo "$OUT"; FAILURES=$((FAILURES + 1)); }
contains "dry run sees nextImplementation" "$OUT" "DRY  nextImplementation"

echo "== upgrade-schedule (direct) =="
OUT=$(make upgrade-schedule DEPLOYMENT=BETH RPC_URL="$RPC" SIGNER="--private-key $OWNER_KEY" 2>&1) || { echo "$OUT"; FAILURES=$((FAILURES + 1)); }
check    "block written"             "$(jq -r 'has("schedule")' "$N")" "true"
check    "block confirmed"           "$(jq -r '.schedule | has("readyAt")' "$N")" "true"
ID=$(jq -r .schedule.operationId "$N")
SALT=$(jq -r .schedule.salt "$N")
CALLDATA=$(jq -r .schedule.calldata "$N")
TARGET=$(jq -r .schedule.target "$N")
CHAIN_ID_HASH=$(cast call "$TIMELOCK_ADDR" 'hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)' \
  "$TARGET" 0 "$CALLDATA" 0x0000000000000000000000000000000000000000000000000000000000000000 "$SALT" --rpc-url "$RPC")
check    "operation id matches the chain" "$(lower "$ID")" "$(lower "$CHAIN_ID_HASH")"
# The shell derivation of the salt must equal the Solidity one.
SHELL_SALT=$(cast keccak "$(cast abi-encode --packed 'f(string,string,address)' BETH -upgrade- "$NEXT_IMPL")")
check    "shell salt equals the recorded salt" "$(lower "$SHELL_SALT")" "$(lower "$SALT")"
check    "proposer is the owner"     "$(cast to-check-sum-address "$(jq -r .schedule.proposer "$N")")" "$(cast to-check-sum-address "$PROXY_OWNER")"
check    "state waiting"             "$(cast call "$TIMELOCK_ADDR" 'getOperationState(bytes32)(uint8)' "$ID" --rpc-url "$RPC")" "1"
contains "status prints waiting"     "$OUT" "state           waiting"

echo "== upgrade-execute before the delay =="
set +e
OUT=$(make upgrade-execute DEPLOYMENT=BETH RPC_URL="$RPC" SIGNER="--private-key $OWNER_KEY" 2>&1)
RC=$?
set -e
check    "refuses"                   "$([ "$RC" -ne 0 ] && echo refused || echo ran)" "refused"
contains "names the wait"            "$OUT" "OperationNotReady"
check    "proxy still on the old"    "$(onchain_impl)" "$OLD_IMPL"

echo "== upgrade-execute after the delay =="
cast rpc evm_increaseTime 61 --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null
OUT=$(make upgrade-execute DEPLOYMENT=BETH RPC_URL="$RPC" SIGNER="--private-key $OWNER_KEY" 2>&1) || { echo "$OUT"; FAILURES=$((FAILURES + 1)); }
check    "proxy on the next"         "$(onchain_impl)" "$NEXT_IMPL"
contains "sync promoted"             "$OUT" "promoted $NEXT_IMPL"
check    "next record gone"          "$([ -f "$N" ] && echo present || echo gone)" "gone"
check    "previous file exists"      "$([ -f "$PREV1" ] && echo present || echo missing)" "present"
check    "previous role"             "$(jq -r .role "$PREV1")" "previousImplementation_1"
check    "previous address"          "$(cast to-check-sum-address "$(jq -r .address "$PREV1")")" "$OLD_IMPL"
check    "impl record address"       "$(cast to-check-sum-address "$(jq -r .address "$I")")" "$NEXT_IMPL"
check    "impl record role"          "$(jq -r .role "$I")" "implementation"
check    "impl record has upgrade"   "$(jq -r 'has("upgrade")' "$I")" "true"
check    "upgrade block readyAt"     "$(jq -r '.upgrade | has("readyAt")' "$I")" "true"
check    "upgrade block id"          "$(lower "$(jq -r .upgrade.operationId "$I")")" "$(lower "$ID")"
check    "impl record has no schedule" "$(jq -r 'has("schedule")' "$I")" "false"
check    "impl record has no note"   "$(jq -r 'has("note")' "$I")" "false"
check    "proxy.implementation"      "$(cast to-check-sum-address "$(jq -r .implementation "$P")")" "$NEXT_IMPL"
check    "numDeployments"            "$(jq -r .numDeployments "$P")" "2"
check    "history length"            "$(jq -r '.history | length' "$P")" "1"
check    "history[0].implementation" "$(cast to-check-sum-address "$(jq -r '.history[0].implementation' "$P")")" "$OLD_IMPL"
check    "history[0].record"         "$(jq -r '.history[0].record' "$P")" "BETH.previousImplementation_1.$CHAIN_ID.json"
check    "history[0].solcInputHash"  "$(jq -r '.history[0].solcInputHash' "$P")" "$(jq -r .solcInputHash "$PREV1")"
check    "no temporaries"            "$(no_temporaries)" "none"

echo "== a sync with no change =="
BEFORE=$(cat "$P" "$I")
OUT=$(make upgrade-sync DEPLOYMENT=BETH RPC_URL="$RPC" 2>&1)
check    "exit zero and files unchanged" "$(cat "$P" "$I")" "$BEFORE"
contains "reports no next"           "$OUT" "next            none"

echo "== cancel =="
make upgrade-deploy DEPLOYMENT=BETH RPC_URL="$RPC" SIGNER="--private-key $DEPLOYER_KEY" >/dev/null 2>&1 || FAILURES=$((FAILURES + 1))
make upgrade-schedule DEPLOYMENT=BETH RPC_URL="$RPC" SIGNER="--private-key $OWNER_KEY" >/dev/null 2>&1 || FAILURES=$((FAILURES + 1))
ID2=$(jq -r .schedule.operationId "$N")
OUT=$(make upgrade-cancel DEPLOYMENT=BETH RPC_URL="$RPC" SIGNER="--private-key $OWNER_KEY" 2>&1) || { echo "$OUT"; FAILURES=$((FAILURES + 1)); }
check    "block dropped"             "$(jq -r 'has("schedule")' "$N")" "false"
check    "next record stays"         "$([ -f "$N" ] && echo present || echo gone)" "present"
contains "sync reports the cancel"   "$OUT" "dropped the schedule block"
contains "status says not scheduled after the cancel" "$OUT" "state           not scheduled"
make upgrade-schedule DEPLOYMENT=BETH RPC_URL="$RPC" SIGNER="--private-key $OWNER_KEY" >/dev/null 2>&1 || FAILURES=$((FAILURES + 1))
check    "the same id schedules again" "$(lower "$(jq -r .schedule.operationId "$N")")" "$(lower "$ID2")"

echo "== an unconfirmed block =="
# Cancel on chain behind the tooling's back, then forget the confirmation.
cast send "$TIMELOCK_ADDR" 'cancel(bytes32)' "$ID2" --private-key "$OWNER_KEY" --rpc-url "$RPC" >/dev/null
jq 'del(.schedule.readyAt)' "$N" >"$N.tmp" && mv "$N.tmp" "$N"
OUT=$(make upgrade-sync DEPLOYMENT=BETH RPC_URL="$RPC" 2>&1)
check    "block kept"                "$(jq -r 'has("schedule")' "$N")" "true"
contains "reports not on chain"      "$OUT" "scheduled in the record, not yet on chain"
set +e
OUT=$(make upgrade-execute DEPLOYMENT=BETH RPC_URL="$RPC" SIGNER="--private-key $OWNER_KEY" 2>&1)
RC=$?
set -e
check    "execute refuses"           "$([ "$RC" -ne 0 ] && echo refused || echo ran)" "refused"
contains "execute names the cause"   "$OUT" "OperationNotOnChain"
make upgrade-schedule DEPLOYMENT=BETH RPC_URL="$RPC" SIGNER="--private-key $OWNER_KEY" >/dev/null 2>&1 || FAILURES=$((FAILURES + 1))
check    "schedule replaced the block" "$(jq -r '.schedule | has("readyAt")' "$N")" "true"

echo "== an operation scheduled by hand =="
make upgrade-cancel DEPLOYMENT=BETH RPC_URL="$RPC" SIGNER="--private-key $OWNER_KEY" >/dev/null 2>&1 || FAILURES=$((FAILURES + 1))
check    "block dropped again"       "$(jq -r 'has("schedule")' "$N")" "false"
NEXT2=$(cast to-check-sum-address "$(jq -r .address "$N")")
HAND_SALT=$(cast keccak "$(cast abi-encode --packed 'f(string,string,address)' BETH -upgrade- "$NEXT2")")
HAND_CALLDATA=$(cast calldata 'upgradeAndCall(address,address,bytes)' "$PROXY_ADDR" "$NEXT2" 0x)
PROXY_ADMIN_ADDR=$(jq -r .address "deployments/BETH.proxyAdmin.$CHAIN_ID.json")
cast send "$TIMELOCK_ADDR" 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' \
  "$PROXY_ADMIN_ADDR" 0 "$HAND_CALLDATA" 0x0000000000000000000000000000000000000000000000000000000000000000 "$HAND_SALT" 60 \
  --private-key "$OWNER_KEY" --rpc-url "$RPC" >/dev/null
OUT=$(make upgrade-sync DEPLOYMENT=BETH RPC_URL="$RPC" 2>&1)
check    "sync wrote a block"        "$(jq -r 'has("schedule")' "$N")" "true"
check    "hand block id"             "$(lower "$(jq -r .schedule.operationId "$N")")" "$(lower "$ID2")"
check    "hand block readyAt"        "$(jq -r '.schedule | has("readyAt")' "$N")" "true"
check    "hand block proposer null"  "$(jq -r .schedule.proposer "$N")" "null"
contains "reports the hand schedule" "$OUT" "scheduled by hand"

echo "== usage =="
set +e
OUT=$(RPC_URL= ./script/upgrade-sync.sh BETH "$CHAIN_ID" 2>&1)
RC=$?
set -e
check    "exit 2 with no RPC_URL"    "$RC" "2"
contains "prints usage"              "$OUT" "usage:"
check    "no temporaries at the end" "$(no_temporaries)" "none"

if [ "$FAILURES" -eq 0 ]; then echo "upgrade-sync.t.sh: all checks passed"; else echo "upgrade-sync.t.sh: $FAILURES check(s) failed"; exit 1; fi
