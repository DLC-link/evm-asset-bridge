#!/bin/sh
# Healthcheck for the beth-it image. Healthy means: the RPC answers AND
# the entrypoint finished the bridge deploy (marker file exists). Consumers
# that gate on service_healthy therefore wait for the deployed bridge, not
# just for a live chain.
set -e
test -f /tmp/beth-it-deployed
cast chain-id --rpc-url http://127.0.0.1:8545 >/dev/null
