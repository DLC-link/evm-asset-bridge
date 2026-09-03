#!/bin/sh
# This script is the healthcheck for the eth-sandbox image. Healthy means
# the bridge proxy holds code. Code at that address also proves
# initialize() ran. The proxy constructor calls initialize() in the same
# transaction as the CREATE.
#
# cast writes RPC errors to stderr. cast also leaves stdout empty on an
# error. An unreachable chain therefore fails this check too.
set -eu

RPC=${RPC_URL:-http://127.0.0.1:8545}
PROXY=${BRIDGE_ADDRESS:-0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512}

code=$(cast code --rpc-url "$RPC" "$PROXY")
[ -n "$code" ] && [ "$code" != "0x" ]
