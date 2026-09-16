#!/usr/bin/env bash
#
# record-upgrade.sh — promotes the next-implementation record after an upgrade.
#
# ExecuteUpgrade moves the proxy to the next implementation on chain. The
# records on disk still name the old one. This script reads three records:
#   1. deployments/<name>.nextImplementation.<chainId>.json  (make record wrote it)
#   2. deployments/<name>.proxy.<chainId>.json
#   3. deployments/<name>.implementation.<chainId>.json      (the outgoing one)
#
# It checks on chain that the proxy points at the next implementation. It then
# appends the outgoing implementation to the proxy history, rewrites the next
# implementation as the current one, and removes the nextImplementation file.
#
# Usage: ./script/record-upgrade.sh <deploymentName> [chainId]
#
# The chain id also comes from CHAIN_ID in the environment. RPC_URL names the
# chain to read. Both are required.
set -euo pipefail

export PATH="$HOME/.foundry/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NAME="${1:-${DEPLOYMENT:-}}"
CHAIN_ID="${2:-${CHAIN_ID:-}}"
RPC_URL="${RPC_URL:-}"
if [ -z "$NAME" ] || [ -z "$CHAIN_ID" ] || [ -z "$RPC_URL" ]; then
  echo "usage: RPC_URL=https://... $0 <deploymentName> <chainId>   (example: $0 BETH 8453)" >&2
  exit 2
fi

for tool in jq cast; do
  command -v "$tool" >/dev/null || { echo "record-upgrade.sh: $tool is not installed" >&2; exit 2; }
done

# The EIP-1967 implementation slot: keccak256("eip1967.proxy.implementation") - 1.
IMPLEMENTATION_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc

NEXT="deployments/$NAME.nextImplementation.$CHAIN_ID.json"
PROXY="deployments/$NAME.proxy.$CHAIN_ID.json"
IMPL="deployments/$NAME.implementation.$CHAIN_ID.json"

for f in "$NEXT" "$PROXY" "$IMPL"; do
  if [ ! -f "$f" ]; then
    echo "record-upgrade.sh: no record at $f" >&2
    if [ "$f" = "$NEXT" ]; then
      echo "record-upgrade.sh: run DeployImplementation and 'make record' first" >&2
    fi
    exit 1
  fi
  if ! jq -e . "$f" >/dev/null 2>&1; then
    echo "record-upgrade.sh: $f holds no valid JSON" >&2
    exit 1
  fi
  RECORD_CHAIN=$(jq -r '.chainId' "$f")
  if [ "$RECORD_CHAIN" != "$CHAIN_ID" ]; then
    echo "record-upgrade.sh: $f names chain $RECORD_CHAIN, not $CHAIN_ID" >&2
    exit 1
  fi
done

lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

NEXT_ADDR=$(jq -r '.address' "$NEXT")
PROXY_ADDR=$(jq -r '.address' "$PROXY")
OLD_ADDR=$(jq -r '.address' "$IMPL")
RECORDED_IMPL=$(jq -r '.implementation // ""' "$PROXY")

# The two records must agree before the script changes either one. A proxy
# record that names another implementation than the implementation record
# would leave a history entry that describes the wrong contract.
if [ "$(lower "$RECORDED_IMPL")" != "$(lower "$OLD_ADDR")" ]; then
  echo "record-upgrade.sh: $PROXY names implementation $RECORDED_IMPL" >&2
  echo "record-upgrade.sh: $IMPL names $OLD_ADDR" >&2
  echo "record-upgrade.sh: repair the records before you promote a new implementation" >&2
  exit 1
fi

if [ "$(lower "$NEXT_ADDR")" = "$(lower "$OLD_ADDR")" ]; then
  echo "record-upgrade.sh: $NEXT names the current implementation $OLD_ADDR" >&2
  echo "record-upgrade.sh: nothing to promote" >&2
  exit 1
fi

# ---- the on-chain check -----------------------------------------------------
# The records must follow the chain, never lead it. The slot read costs one RPC
# call, and it stops a promotion before ExecuteUpgrade has landed.
SLOT_VALUE=$(cast storage "$PROXY_ADDR" "$IMPLEMENTATION_SLOT" --rpc-url "$RPC_URL")
SLOT_VALUE=$(lower "$SLOT_VALUE")
ONCHAIN_IMPL="0x${SLOT_VALUE: -40}"
if [ "$ONCHAIN_IMPL" != "$(lower "$NEXT_ADDR")" ]; then
  echo "record-upgrade.sh: the proxy $PROXY_ADDR does not point at the next implementation" >&2
  echo "record-upgrade.sh: on chain it points at $ONCHAIN_IMPL" >&2
  echo "record-upgrade.sh: the next implementation is $NEXT_ADDR" >&2
  echo "record-upgrade.sh: run ExecuteUpgrade first, then run this script again" >&2
  exit 1
fi

# The trap removes the temporary files, so a failure part way through leaves
# no stray .tmp beside the records.
drop_temporaries() { rm -f "$PROXY.tmp" "$IMPL.tmp"; }
trap drop_temporaries EXIT

# ---- the proxy record -------------------------------------------------------
# The six fields describe the outgoing implementation. record.sh writes the
# same six fields, so a consumer reads one history shape.
ENTRY=$(jq -c '{implementation: .address, contractName: .contractName,
                solcInputHash: .solcInputHash, gitCommit: .gitCommit,
                transactionHash: .transactionHash, deployedAt: .deployedAt}' "$IMPL")
jq --arg impl "$NEXT_ADDR" --argjson entry "$ENTRY" \
  '. + {
    implementation: $impl,
    numDeployments: ((.numDeployments // 1) + 1),
    history: ((.history // []) + [$entry])
  }' "$PROXY" >"$PROXY.tmp"

# ---- the implementation record ----------------------------------------------
jq '. + {role: "implementation"}' "$NEXT" >"$IMPL.tmp"

# Both temporaries exist now. The two moves and the delete run last, so an
# earlier failure changes no record.
mv "$PROXY.tmp" "$PROXY"
mv "$IMPL.tmp" "$IMPL"
rm -f "$NEXT"

echo "recorded implementation  $NEXT_ADDR  -> $IMPL"
echo "recorded proxy           $PROXY_ADDR  -> $PROXY"
echo "done. The old implementation $OLD_ADDR is history entry $(jq -r '.history | length - 1' "$PROXY")"
