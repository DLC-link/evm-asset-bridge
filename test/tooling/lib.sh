#!/usr/bin/env bash
#
# lib.sh — helpers that the tooling tests share.
#
# A test sources this file after it sets ROOT and FAILURES. It runs no test of
# its own. The tests count failures the same way, start anvil the same way,
# deploy the same BETH fixture, and leave compiler inputs behind, so the rules
# live here once.

# check compares one value against the value the test expects.
check() { # check <label> <actual> <expected>
  if [ "$2" = "$3" ]; then
    echo "  ok   $1"
  else
    echo "  FAIL $1: got '$2', want '$3'"
    FAILURES=$((FAILURES + 1))
  fi
}

# contains looks for a substring in a captured output.
contains() { # contains <label> <haystack> <needle>
  case "$2" in
    *"$3"*) echo "  ok   $1" ;;
    *) echo "  FAIL $1: '$3' not found"; FAILURES=$((FAILURES + 1)) ;;
  esac
}

# prune_untracked_solc_inputs removes the compiler inputs a test run created.
# It keeps any input that a record on disk still names, whether the record
# names it directly or through a history entry. A real deploy leaves both the
# record and the input untracked until the operator commits them. Deleting an
# input that a record names would destroy the only copy.
prune_untracked_solc_inputs() {
  local f hash r keep
  for f in deployments/solcInputs/*.json; do
    [ -e "$f" ] || continue
    git ls-files --error-unmatch "$f" >/dev/null 2>&1 && continue
    hash="$(basename "$f" .json)"
    keep=0
    for r in deployments/*.json; do
      [ -e "$r" ] || continue
      if jq -e --arg h "$hash" \
        '[.solcInputHash, ((.history // [])[] | .solcInputHash)] | index($h) != null' \
        "$r" >/dev/null 2>&1; then
        keep=1
        break
      fi
    done
    [ "$keep" -eq 1 ] || rm -f "$f"
  done
  return 0
}

lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

# anvil_stop kills the anvil that listens on one port, if any.
anvil_stop() { pkill -f "anvil --port $1" >/dev/null 2>&1 || true; }

# anvil_start starts anvil on one port and waits until it answers. The wait
# must end. An anvil that never answers would otherwise keep the test, and
# the CI job that runs it, alive until the job's own timeout.
anvil_start() { # anvil_start <port>
  local rpc="http://127.0.0.1:$1" waited=0
  anvil_stop "$1"
  anvil --port "$1" --silent &
  until cast chain-id --rpc-url "$rpc" >/dev/null 2>&1; do
    sleep 0.2
    waited=$((waited + 1))
    if [ "$waited" -ge 150 ]; then
      echo "lib.sh: anvil did not answer on $rpc within 30 seconds" >&2
      exit 1
    fi
  done
}

# deploy_beth deploys the BETH fixture with Deploy_BETH and records it. The
# addresses are anvil's default accounts; the keys are public and well known.
# The deployer is account 0, and PROXY_OWNER is account 3.
deploy_beth() { # deploy_beth <rpc> <deployer key>
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
    --rpc-url "$1" --broadcast --private-key "$2" >/dev/null
  ./script/record.sh BETH >/dev/null
}
