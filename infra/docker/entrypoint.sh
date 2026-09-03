#!/bin/sh
# This script is the entrypoint for the eth-sandbox image. The script
# starts anvil, deploys the bridge with script/DeployIT.s.sol, and then
# waits on anvil.
#
# Consumers read only up to the `finalized` block tag. Both flags below
# serve that tag. Neither flag works alone.
#
# --slots-in-an-epoch 1 makes the tag advance. Anvil's default leaves the
# tag 64 blocks behind the head.
#
# --block-time 1 mines one block every second. It does so even when no
# transaction arrives. The epoch flag alone does not keep the tag moving.
# A consumer then waits forever for the transaction it must observe.
#
# The mnemonic is anvil's own default, spelled out. This keeps the
# account table reproducible. THESE ARE PUBLIC, WELL-KNOWN TEST KEYS.
# NEVER send real funds to any address this chain funds.
set -eu

MNEMONIC="test test test test test test test test test test test junk"

anvil --host 0.0.0.0 --port 8545 --chain-id 31337 \
      --slots-in-an-epoch 1 --block-time 1 \
      --mnemonic "$MNEMONIC" &
ANVIL_PID=$!
trap 'kill "$ANVIL_PID" 2>/dev/null' TERM INT

i=0
until cast chain-id --rpc-url http://127.0.0.1:8545 >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 60 ]; then
        echo "eth-sandbox: anvil did not answer within 60s" >&2
        exit 1
    fi
    sleep 1
done

# The contracts are prebuilt at image build time. This only broadcasts.
# DeployIT asserts both contract addresses and fails loudly on drift.
forge script script/DeployIT.s.sol --rpc-url http://127.0.0.1:8545 --broadcast

echo "eth-sandbox: bridge ready; anvil serves on :8545"

wait "$ANVIL_PID"
