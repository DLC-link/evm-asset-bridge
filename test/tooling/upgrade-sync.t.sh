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

echo "== the timelock delay targets send DELAY and run no sync =="
MK_OUT=$(make -n timelock-delay-schedule DEPLOYMENT=BETH RPC_URL="$MK_URL" SIGNER='--account d' DELAY=120 2>&1)
contains "delay schedule names the script"  "$MK_OUT" "ScheduleUpdateDelay.s.sol:ScheduleUpdateDelay"
contains "delay schedule passes DELAY"      "$MK_OUT" "--sig 'run(uint256)' \"120\""
contains "delay schedule broadcasts in direct mode" "$MK_OUT" "--broadcast --account d"
check    "delay schedule runs no sync"      "$(count "$MK_OUT" "upgrade-sync.sh")" "0"
contains "delay schedule prints its mode"   "$MK_OUT" "direct broadcast"

MK_OUT=$(make -n timelock-delay-execute DEPLOYMENT=BETH RPC_URL="$MK_URL" SIGNER='--account d' DELAY=120 2>&1)
contains "delay execute names the script"   "$MK_OUT" "ExecuteUpdateDelay.s.sol:ExecuteUpdateDelay"
MK_OUT=$(make -n timelock-delay-cancel DEPLOYMENT=BETH RPC_URL="$MK_URL" SIGNER='--account d' DELAY=120 2>&1)
contains "delay cancel names the script"    "$MK_OUT" "CancelUpdateDelay.s.sol:CancelUpdateDelay"

MK_OUT=$(SAFE=0x0000000000000000000000000000000000000001 make -n timelock-delay-schedule DEPLOYMENT=BETH RPC_URL="$MK_URL" DELAY=120 2>&1)
check    "delay Safe mode never broadcasts" "$(count "$MK_OUT" "\-\-broadcast")" "0"

set +e
MK_OUT=$(make -n timelock-delay-schedule DEPLOYMENT=BETH RPC_URL="$MK_URL" SIGNER='--account d' 2>&1)
MK_RC=$?
set -e
check    "delay schedule needs DELAY"       "$([ "$MK_RC" -ne 0 ] && echo refused || echo ran)" "refused"
contains "delay schedule names the variable" "$MK_OUT" "DELAY is not set"

set +e
MK_OUT=$(make -n timelock-delay-schedule DEPLOYMENT=BETH RPC_URL="$MK_URL" DELAY=120 2>&1)
MK_RC=$?
set -e
check    "direct delay schedule needs SIGNER" "$([ "$MK_RC" -ne 0 ] && echo refused || echo ran)" "refused"


BAK=$(mktemp -d)
cleanup() {
  anvil_stop "$PORT"
  prune_untracked_solc_inputs
  rm -rf "$BAK"
}
trap cleanup EXIT

echo "== starting anvil on port $PORT =="
anvil_start "$PORT"

# Every delete names chain $CHAIN_ID. A wider delete would take a real deploy
# with it.
rm -rf "deployments/BETH."*".$CHAIN_ID.json" "broadcast/Deploy_BETH.s.sol/$CHAIN_ID" \
  "broadcast/DeployNextImplementation.s.sol/$CHAIN_ID"
rm -f "deployments/.pending/BETH.$CHAIN_ID.json"

echo "== deploying the bridge =="
# Anvil's default accounts 0 and 3. OWNER_KEY belongs to PROXY_OWNER.
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
OWNER_KEY=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
deploy_beth "$RPC" "$DEPLOYER_KEY"

P="deployments/BETH.proxy.$CHAIN_ID.json"
I="deployments/BETH.implementation.$CHAIN_ID.json"
N="deployments/BETH.nextImplementation.$CHAIN_ID.json"
T="deployments/BETH.timelock.$CHAIN_ID.json"
PREV1="deployments/BETH.previousImplementation_1.$CHAIN_ID.json"
IMPL_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
PROXY_ADDR=$(jq -r .address "$P")
TIMELOCK_ADDR=$(jq -r .address "$T")
OLD_IMPL=$(cast to-check-sum-address "$(jq -r .address "$I")")
onchain_impl() {
  cast to-check-sum-address "0x$(cast storage "$PROXY_ADDR" "$IMPL_SLOT" --rpc-url "$RPC" | cut -c27-66)"
}
# set_impl_slot points the proxy at an address behind the timelock's back.
set_impl_slot() {
  cast rpc anvil_setStorageAt "$PROXY_ADDR" "$IMPL_SLOT" "$(cast abi-encode 'f(address)' "$1")" --rpc-url "$RPC" >/dev/null
}
no_temporaries() { [ -z "$(ls deployments/BETH.*.$CHAIN_ID.json.tmp 2>/dev/null)" ] && echo none || echo present; }
# sync_refuses runs the sync and expects a non-zero exit with one message.
sync_refuses() { # sync_refuses <label> <needle>
  local out rc
  set +e
  out=$(make upgrade-sync DEPLOYMENT=BETH RPC_URL="$RPC" 2>&1)
  rc=$?
  set -e
  check    "$1 refuses"     "$([ "$rc" -ne 0 ] && echo refused || echo ran)" "refused"
  contains "$1 names the cause" "$out" "$2"
  check    "$1 leaves no temporaries" "$(no_temporaries)" "none"
}

echo "== upgrade-sync with no next implementation =="
OUT=$(make upgrade-sync DEPLOYMENT=BETH RPC_URL="$RPC" 2>&1)
contains "reports no next" "$OUT" "next            none"
contains "reports the live implementation" "$OUT" "$OLD_IMPL"

echo "== upgrade-deploy =="
OUT=$(make upgrade-deploy DEPLOYMENT=BETH RPC_URL="$RPC" SIGNER="--private-key $DEPLOYER_KEY" 2>&1) || { echo "$OUT"; FAILURES=$((FAILURES + 1)); }
check    "next record exists"        "$([ -f "$N" ] && echo present || echo missing)" "present"
check    "next role"                 "$(jq -r .role "$N")" "nextImplementation"
check    "next contractName"         "$(jq -r .contractName "$N")" "BitSafeEvmAssetBridge"
contains "deploy prints the record path" "$OUT" "record $N"
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

echo "== a sync with no change =="
BEFORE=$(cat "$P" "$I" "$N")
OUT=$(make upgrade-sync DEPLOYMENT=BETH RPC_URL="$RPC" 2>&1)
check    "files unchanged"           "$(cat "$P" "$I" "$N")" "$BEFORE"
contains "reports no change"         "$OUT" "sync            no change"
contains "still waiting"             "$OUT" "state           waiting"

echo "== the sync refuses a damaged record while the operation waits =="
cp "$N" "$BAK/next.json"
jq '.schedule.operationId = "0x0000000000000000000000000000000000000000000000000000000000000001"' "$BAK/next.json" >"$N"
sync_refuses "a foreign operation id" "but the records derive"
jq 'del(.schedule.data)' "$BAK/next.json" >"$N"
sync_refuses "a block without data" "no data field that starts with 0x"
cp "$BAK/next.json" "$N"
set_impl_slot "$NEXT_IMPL"
sync_refuses "a pending operation while the proxy already points at next" "already points at $NEXT_IMPL"
set_impl_slot "$OLD_IMPL"
check    "proxy restored"            "$(onchain_impl)" "$OLD_IMPL"
check    "record restored"           "$(cat "$P" "$I" "$N")" "$BEFORE"

echo "== upgrade-execute before the delay =="
set +e
OUT=$(make upgrade-execute DEPLOYMENT=BETH RPC_URL="$RPC" SIGNER="--private-key $OWNER_KEY" 2>&1)
RC=$?
set -e
check    "refuses"                   "$([ "$RC" -ne 0 ] && echo refused || echo ran)" "refused"
contains "names the wait"            "$OUT" "OperationNotReady"
check    "proxy still on the old"    "$(onchain_impl)" "$OLD_IMPL"

echo "== upgrade-execute after the delay, with a previous file in the way =="
cast rpc evm_increaseTime 61 --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null
# The execute lands. The post-sync then refuses the promote, because a file
# with the next previous name already exists.
echo '{}' >"$PREV1"
set +e
OUT=$(make upgrade-execute DEPLOYMENT=BETH RPC_URL="$RPC" SIGNER="--private-key $OWNER_KEY" 2>&1)
RC=$?
set -e
check    "proxy on the next"         "$(onchain_impl)" "$NEXT_IMPL"
check    "the post-sync refuses"     "$([ "$RC" -ne 0 ] && echo refused || echo ran)" "refused"
contains "names the previous file"   "$OUT" "never overwrites a previous implementation"
check    "records not promoted"      "$([ -f "$N" ] && echo present || echo gone)" "present"
check    "no temporaries"            "$(no_temporaries)" "none"
rm -f "$PREV1"

echo "== the sync refuses a damaged record while the operation is done =="
cp "$P" "$BAK/proxy.json"
jq '.implementation = "0x000000000000000000000000000000000000dEaD"' "$BAK/proxy.json" >"$P"
sync_refuses "a proxy record that names another implementation" "repair the records before you promote"
cp "$BAK/proxy.json" "$P"
set_impl_slot "$OLD_IMPL"
sync_refuses "a done operation while the proxy points elsewhere" "is done, but the proxy points at $OLD_IMPL"
set_impl_slot "$NEXT_IMPL"

echo "== the sync promotes =="
OUT=$(make upgrade-sync DEPLOYMENT=BETH RPC_URL="$RPC" 2>&1) || { echo "$OUT"; FAILURES=$((FAILURES + 1)); }
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

echo "== the timelock delay change =="
T_BEFORE=$(shasum "$T")
make timelock-delay-schedule DEPLOYMENT=BETH RPC_URL="$RPC" SIGNER="--private-key $OWNER_KEY" DELAY=120 >/dev/null 2>&1 || FAILURES=$((FAILURES + 1))
cast rpc evm_increaseTime 61 --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null
make timelock-delay-execute DEPLOYMENT=BETH RPC_URL="$RPC" SIGNER="--private-key $OWNER_KEY" DELAY=120 >/dev/null 2>&1 || FAILURES=$((FAILURES + 1))
check    "the live delay is the new one"   "$(cast call "$TIMELOCK_ADDR" 'getMinDelay()(uint256)' --rpc-url "$RPC")" "120"
check    "the timelock record keeps the deploy-time delay" "$(shasum "$T")" "$T_BEFORE"
OUT=$(make manage-status DEPLOYMENT=BETH RPC_URL="$RPC" 2>&1) || { echo "$OUT"; FAILURES=$((FAILURES + 1)); }
contains "status prints timelockMinDelay"  "$OUT" "timelockMinDelay"
check    "status prints the new delay"     "$(printf '%s\n' "$OUT" | grep -E '^ *timelockMinDelay +120$' | tr -s ' ' | sed 's/^ //')" "timelockMinDelay 120"
set +e
OUT=$(make timelock-delay-schedule DEPLOYMENT=BETH RPC_URL="$RPC" SIGNER="--private-key $OWNER_KEY" DELAY=1d 2>&1)
RC=$?
set -e
check    "a malformed DELAY refuses"       "$([ "$RC" -ne 0 ] && echo refused || echo ran)" "refused"
check    "no envelope for the refused DELAY" "$([ -f "deployments/.safe/BETH.$CHAIN_ID.scheduleUpdateDelay.json" ] && echo present || echo absent)" "absent"

echo "== usage =="
set +e
OUT=$(RPC_URL= ./script/upgrade-sync.sh BETH "$CHAIN_ID" 2>&1)
RC=$?
set -e
check    "exit 2 with no RPC_URL"    "$RC" "2"
contains "prints usage"              "$OUT" "usage:"
check    "no temporaries at the end" "$(no_temporaries)" "none"

if [ "$FAILURES" -eq 0 ]; then echo "upgrade-sync.t.sh: all checks passed"; else echo "upgrade-sync.t.sh: $FAILURES check(s) failed"; exit 1; fi
