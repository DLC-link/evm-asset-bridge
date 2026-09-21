#!/usr/bin/env bash
#
# upgrade-sync.sh — reconciles the upgrade records with the chain.
#
# The chain is the source of truth for a timelock operation. forge writes files
# during simulation, before it broadcasts, and Safe mode never touches the
# chain. So no Solidity script records what happened. This script reads the
# timelock and the proxy, and it changes the records to match:
#
#   chain Waiting/Ready, block without readyAt  -> add readyAt
#   chain Waiting/Ready, no block               -> write a block for an empty payload
#   chain Unset, block without readyAt          -> keep it: not on chain yet
#   chain Unset, block with readyAt             -> cancelled: drop the block
#   chain Done, proxy points at next            -> promote the records
#
# Promote moves <name>.implementation to <name>.previousImplementation_<n>,
# turns <name>.nextImplementation into <name>.implementation with `schedule`
# renamed to `upgrade`, and gives the proxy record the new address,
# numDeployments + 1 and one history entry that names the previous file.
#
# It then prints the status. `make upgrade-status` runs this same command.
#
# Usage: CHAIN_ID=<id> RPC_URL=<url> ./script/upgrade-sync.sh <deploymentName> [chainId]
set -euo pipefail

export PATH="$HOME/.foundry/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NAME="${1:-}"
CHAIN_ID="${2:-${CHAIN_ID:-}}"
RPC_URL="${RPC_URL:-}"
if [ -z "$NAME" ] || [ -z "$CHAIN_ID" ] || [ -z "$RPC_URL" ]; then
  echo "usage: CHAIN_ID=<id> RPC_URL=<url> $0 <deploymentName> [chainId]" >&2
  exit 2
fi
for tool in jq cast; do
  command -v "$tool" >/dev/null || { echo "upgrade-sync.sh: $tool is not installed" >&2; exit 2; }
done

IMPLEMENTATION_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
ZERO32=0x0000000000000000000000000000000000000000000000000000000000000000

record() { printf 'deployments/%s.%s.%s.json' "$NAME" "$1" "$CHAIN_ID"; }
lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
call() { cast call --rpc-url "$RPC_URL" "$@"; }
# cast appends a scientific-notation hint to a large number. Keep the number.
call_uint() { call "$@" | cut -d' ' -f1; }
# GNU date takes -d, BSD date takes -r.
epoch_to_iso() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

require_record() {
  local f
  f="$(record "$1")"
  if [ ! -f "$f" ]; then
    echo "upgrade-sync.sh: no record at $f" >&2
    exit 1
  fi
  if ! jq -e . "$f" >/dev/null 2>&1; then
    echo "upgrade-sync.sh: $f holds no valid JSON" >&2
    exit 1
  fi
  if [ "$(jq -r .chainId "$f")" != "$CHAIN_ID" ]; then
    echo "upgrade-sync.sh: $f names chain $(jq -r .chainId "$f"), not $CHAIN_ID" >&2
    exit 1
  fi
}

# Every write stages <file>.tmp first. The trap removes stray temporaries, so
# a failure part way through leaves the records as they were.
drop_temporaries() { rm -f deployments/"$NAME".*."$CHAIN_ID".json.tmp; }
trap drop_temporaries EXIT

require_record proxy
require_record proxyAdmin
require_record timelock
PROXY_FILE=$(record proxy)
IMPL_FILE=$(record implementation)
NEXT_FILE=$(record nextImplementation)

PROXY=$(cast to-check-sum-address "$(jq -r .address "$PROXY_FILE")")
PROXY_ADMIN=$(cast to-check-sum-address "$(jq -r .address "$(record proxyAdmin)")")
TIMELOCK=$(cast to-check-sum-address "$(jq -r .address "$(record timelock)")")

MIN_DELAY=$(call_uint "$TIMELOCK" 'getMinDelay()(uint256)')
SLOT=$(cast storage "$PROXY" "$IMPLEMENTATION_SLOT" --rpc-url "$RPC_URL")
LIVE_IMPL=$(cast to-check-sum-address "0x${SLOT:26:40}")
NOW=$(cast block latest --field timestamp --rpc-url "$RPC_URL" | cut -d' ' -f1)

report_header() {
  echo "deployment      $NAME (chain $CHAIN_ID)"
  echo "proxy           $PROXY"
  echo "implementation  $LIVE_IMPL"
  echo "timelock        $TIMELOCK (min delay ${MIN_DELAY}s)"
}

if [ ! -f "$NEXT_FILE" ]; then
  report_header
  echo "next            none ($NEXT_FILE does not exist)"
  exit 0
fi
require_record nextImplementation
NEXT=$(cast to-check-sum-address "$(jq -r .address "$NEXT_FILE")")

# ---- the operation ----------------------------------------------------------
HAS_BLOCK=$(jq -r 'has("schedule")' "$NEXT_FILE")
if [ "$HAS_BLOCK" = "true" ]; then
  DATA=$(jq -r .schedule.data "$NEXT_FILE")
  HAS_READY=$(jq -r '.schedule | has("readyAt")' "$NEXT_FILE")
else
  DATA=0x
  HAS_READY=false
fi
# The same derivation as UpgradeManage.salt and UpgradeManage.upgradeCall.
# test/tooling/upgrade-sync.t.sh pins the two against each other.
SALT=$(cast keccak "$(cast abi-encode --packed 'f(string,string,address)' "$NAME" "-upgrade-" "$NEXT")")
CALLDATA=$(cast calldata 'upgradeAndCall(address,address,bytes)' "$PROXY" "$NEXT" "$DATA")
ID=$(call "$TIMELOCK" 'hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)' \
  "$PROXY_ADMIN" 0 "$CALLDATA" "$ZERO32" "$SALT")
if [ "$HAS_BLOCK" = "true" ]; then
  RECORDED_ID=$(jq -r .schedule.operationId "$NEXT_FILE")
  if [ "$(lower "$RECORDED_ID")" != "$(lower "$ID")" ]; then
    echo "upgrade-sync.sh: the schedule block names operation $RECORDED_ID, but the records derive $ID" >&2
    echo "upgrade-sync.sh: the record is inconsistent; repair it by hand before you continue" >&2
    exit 1
  fi
fi

# 0 Unset, 1 Waiting, 2 Ready, 3 Done
STATE=$(call_uint "$TIMELOCK" 'getOperationState(bytes32)(uint8)' "$ID")
READY_AT=$(call_uint "$TIMELOCK" 'getTimestamp(bytes32)(uint256)' "$ID")

# The block the sync writes for an operation somebody scheduled by hand. Only
# the fields the chain proves are set.
chain_block() {
  jq -n --arg id "$ID" --arg target "$PROXY_ADMIN" --arg calldata "$CALLDATA" --arg salt "$SALT" \
    --arg timelock "$TIMELOCK" --arg zero "$ZERO32" \
    '{operationId: $id, target: $target, calldata: $calldata, data: "0x", predecessor: $zero,
      salt: $salt, timelock: $timelock, delay: null, proposer: null, proposedAt: null}'
}

promote() {
  require_record implementation
  local n prev_file recorded_impl entry
  n=$(jq -r '.numDeployments // 1' "$PROXY_FILE")
  prev_file=$(record "previousImplementation_$n")
  if [ -f "$prev_file" ]; then
    echo "upgrade-sync.sh: $prev_file exists; the sync never overwrites a previous implementation" >&2
    exit 1
  fi
  recorded_impl=$(jq -r .implementation "$PROXY_FILE")
  if [ "$(lower "$recorded_impl")" != "$(lower "$(jq -r .address "$IMPL_FILE")")" ]; then
    echo "upgrade-sync.sh: $PROXY_FILE names implementation $recorded_impl, but $IMPL_FILE holds $(jq -r .address "$IMPL_FILE")" >&2
    echo "upgrade-sync.sh: repair the records before you promote" >&2
    exit 1
  fi

  jq --arg role "previousImplementation_$n" '. + {role: $role}' "$IMPL_FILE" >"$prev_file.tmp"

  jq --argjson block "$(chain_block)" \
    'del(.note) | .upgrade = (.schedule // $block) | del(.schedule) | . + {role: "implementation"}' \
    "$NEXT_FILE" >"$IMPL_FILE.tmp"

  entry=$(jq -c --arg record "$(basename "$prev_file")" \
    '{implementation: .address, contractName, solcInputHash, gitCommit, transactionHash, deployedAt, record: $record}' \
    "$IMPL_FILE")
  jq --arg impl "$NEXT" --argjson entry "$entry" \
    '. + {implementation: $impl, numDeployments: ((.numDeployments // 1) + 1), history: ((.history // []) + [$entry])}' \
    "$PROXY_FILE" >"$PROXY_FILE.tmp"

  mv "$prev_file.tmp" "$prev_file"
  mv "$IMPL_FILE.tmp" "$IMPL_FILE"
  mv "$PROXY_FILE.tmp" "$PROXY_FILE"
  rm -f "$NEXT_FILE"
  ACTION="promoted $NEXT; the old implementation is $prev_file"
  echo "wrote $prev_file"
  echo "wrote $IMPL_FILE"
  echo "wrote $PROXY_FILE"
}

ACTION="no change"
case "$STATE" in
  1 | 2)
    if [ "$LIVE_IMPL" = "$NEXT" ]; then
      echo "upgrade-sync.sh: the operation is pending, but the proxy already points at $NEXT; investigate" >&2
      exit 1
    fi
    if [ "$HAS_BLOCK" != "true" ]; then
      jq --argjson block "$(chain_block)" --argjson readyAt "$READY_AT" \
        '.schedule = ($block + {readyAt: $readyAt})' "$NEXT_FILE" >"$NEXT_FILE.tmp"
      mv "$NEXT_FILE.tmp" "$NEXT_FILE"
      ACTION="recorded the operation the chain holds (scheduled by hand)"
    elif [ "$HAS_READY" != "true" ]; then
      jq --argjson readyAt "$READY_AT" '.schedule.readyAt = $readyAt' "$NEXT_FILE" >"$NEXT_FILE.tmp"
      mv "$NEXT_FILE.tmp" "$NEXT_FILE"
      ACTION="confirmed the schedule; readyAt $READY_AT"
    fi
    ;;
  0)
    if [ "$HAS_BLOCK" = "true" ] && [ "$HAS_READY" = "true" ]; then
      jq 'del(.schedule)' "$NEXT_FILE" >"$NEXT_FILE.tmp"
      mv "$NEXT_FILE.tmp" "$NEXT_FILE"
      # The status below reads HAS_BLOCK, and the block is gone now.
      HAS_BLOCK=false
      ACTION="the operation was cancelled; dropped the schedule block"
    fi
    ;;
  3)
    if [ "$LIVE_IMPL" != "$NEXT" ]; then
      echo "upgrade-sync.sh: the operation is done, but the proxy points at $LIVE_IMPL, not $NEXT; investigate" >&2
      exit 1
    fi
    promote
    ;;
  *)
    echo "upgrade-sync.sh: unknown operation state '$STATE'" >&2
    exit 1
    ;;
esac

# ---- the status --------------------------------------------------------------
report_header
echo "next            $NEXT"
echo "operation       $ID"
case "$STATE" in
  0)
    if [ "$HAS_BLOCK" = "true" ]; then
      echo "state           scheduled in the record, not yet on chain"
    else
      echo "state           not scheduled"
    fi
    ;;
  1)
    LEFT=$((READY_AT - NOW))
    [ "$LEFT" -lt 0 ] && LEFT=0
    echo "state           waiting; ready at $(epoch_to_iso "$READY_AT") (${LEFT}s left)"
    ;;
  2) echo "state           ready to execute" ;;
  3) echo "state           done" ;;
esac
if [ "$LIVE_IMPL" = "$NEXT" ]; then
  echo "proxy points at next: yes"
else
  echo "proxy points at next: no"
fi
echo "sync            $ACTION"
