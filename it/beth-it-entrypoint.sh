#!/bin/sh
# Entrypoint for the beth-it image (see Dockerfile.beth-it).
#
# The script starts anvil, deploys the bridge with script/DeployIT.s.sol,
# writes the /tmp/beth-it-deployed marker, and then waits on anvil.
# it/check-service.sh reports healthy only after the marker exists, so a
# consumer that gates on the container healthcheck sees the bridge at the
# fixed addresses from the first moment the container is "healthy".
set -eu

# --block-time 1: 1-second blocks so confirmation-count waits behave like a
#                 real chain instead of instant-mine.
# --host 0.0.0.0: bind on all interfaces so the port publishes to the host
#                 and is reachable from sibling containers by service name.
anvil --block-time 1 --host 0.0.0.0 &
ANVIL_PID=$!
trap 'kill "$ANVIL_PID" 2>/dev/null' TERM INT

i=0
until cast chain-id --rpc-url http://127.0.0.1:8545 >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 60 ]; then
        echo "beth-it: anvil did not answer within 60s" >&2
        exit 1
    fi
    sleep 1
done

# The contracts are prebuilt at image build time (RUN forge build), so this
# only broadcasts. A deploy failure exits non-zero and stops the container.
forge script script/DeployIT.s.sol --rpc-url http://127.0.0.1:8545 --broadcast -vvvv

touch /tmp/beth-it-deployed
echo "beth-it: bridge deployed; anvil serves on :8545"

wait "$ANVIL_PID"
