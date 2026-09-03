#!/usr/bin/env bash
# This script is the acceptance gate for the eth-sandbox image. A
# developer runs it through `make it-verify`. CI runs it against a
# locally built amd64 image before it pushes anything.
#
# It proves the four properties DLC-link/dlc-attestor-stack depends on:
#
#   1. the bridge proxy holds code at the pinned address;
#   2. threshold() returns 2, with exactly three attestors;
#   3. the `finalized` tag advances, which the attestors read;
#   4. a deposit emits a Deposit event that a scan bounded by
#      `finalized` finds — the attestors' exact read path.
#
# Every check runs `cast` INSIDE the container. The host needs no
# Foundry install. All diagnostics go to stderr.
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <image-tag>" >&2
    exit 2
fi
IMAGE="$1"

TIMEOUT_SECONDS=${SMOKE_TIMEOUT_SECONDS:-240}
INTERVAL=5
PROXY=0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
RPC=http://127.0.0.1:8545
# This is anvil account 6, the test user. It is a PUBLIC, well-known
# test key.
TEST_USER_KEY=0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e
# keccak256("Deposit(bytes32,bytes,address,uint256)")
DEPOSIT_TOPIC0=0xacaea730ea841fae3326f72a7ff746b6e06c646840526bcaf5dabee5fd887ef8
CONTAINER="eth-sandbox-smoke-$$"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "image not present locally: $IMAGE" >&2
    exit 1
fi

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

fail() {
    echo "SMOKE FAIL: $1" >&2
    echo "--- container logs (last 50 lines) ---" >&2
    docker logs "$CONTAINER" 2>&1 | tail -50 >&2
    exit 1
}

docker run -d --name "$CONTAINER" "$IMAGE" >/dev/null

# 1. Wait for the bridge, using the image's own probe.
deadline=$((SECONDS + TIMEOUT_SECONDS))
while true; do
    if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
        echo "SMOKE FAIL: container disappeared" >&2
        exit 1
    fi
    state=$(docker inspect -f '{{.State.Status}}' "$CONTAINER")
    if [ "$state" = exited ]; then
        code=$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER")
        fail "container exited early with code $code"
    fi
    if docker exec "$CONTAINER" /check-service.sh >/dev/null 2>&1; then
        break
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
        fail "bridge did not appear within ${TIMEOUT_SECONDS}s"
    fi
    sleep "$INTERVAL"
done
echo "smoke: bridge is deployed at $PROXY"

# 2. The configuration the attestor stack pins.
threshold=$(docker exec "$CONTAINER" cast call --rpc-url "$RPC" "$PROXY" "threshold()(uint256)")
[ "$threshold" = 2 ] || fail "threshold is '$threshold', want 2"

attestors=$(docker exec "$CONTAINER" cast call --rpc-url "$RPC" "$PROXY" "getAttestors()(address[])")
count=$(printf '%s' "$attestors" | tr ',' '\n' | grep -c '0x' || true)
[ "$count" = 3 ] || fail "attestor count is $count, want 3 (got: $attestors)"
echo "smoke: threshold 2 with 3 attestors"

# 3. The finalized tag must advance with no transactions. With
#    --slots-in-an-epoch 1 alone it freezes on an idle chain. A consumer
#    then waits forever for the transaction it must observe.
before=$(docker exec "$CONTAINER" cast block finalized --field number --rpc-url "$RPC")
sleep 6
after=$(docker exec "$CONTAINER" cast block finalized --field number --rpc-url "$RPC")
if [ "$after" -le "$before" ]; then
    fail "finalized did not advance without transactions ($before -> $after); check --slots-in-an-epoch 1 and --block-time 1"
fi
echo "smoke: finalized advanced $before -> $after with no transactions"

# 4. The consumer read path, end to end.
docker exec "$CONTAINER" cast send "$PROXY" "depositETH(bytes)" 0x736d6f6b65 \
    --value 1ether --private-key "$TEST_USER_KEY" --rpc-url "$RPC" >/dev/null
# finalized trails the head by 2 blocks. Let it pass the deposit.
sleep 6
logs=$(docker exec "$CONTAINER" cast logs --from-block 0 --to-block finalized \
    --address "$PROXY" --rpc-url "$RPC")
printf '%s' "$logs" | grep -q "$DEPOSIT_TOPIC0" \
    || fail "no Deposit event under the finalized tag; a consumer scanning to finalized would see nothing"
echo "smoke: Deposit event is visible under the finalized tag"

echo "SMOKE PASS: $IMAGE"
