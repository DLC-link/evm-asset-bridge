#!/usr/bin/env bash
#
# record.sh — turns one deploy into committed deployment records.
#
# It merges three sources:
#   1. deployments/.pending/<name>.<chainId>.json   (the deploy script wrote it)
#   2. broadcast/Deploy_<name>.s.sol/<chainId>/run-latest.json  (foundry wrote it)
#   3. out/<Contract>.sol/<Contract>.json           (the build wrote it)
#
# It writes deployments/<name>.<role>.<chainId>.json for each role, plus
# deployments/solcInputs/<hash>.json for each distinct compiler input. Then it
# removes the pending file.
#
# Usage: ./script/record.sh <deploymentName> [chainId]
#
# The chain id also comes from CHAIN_ID in the environment. It picks the exact
# pending file. Without it the script needs exactly one matching pending file.
set -euo pipefail

export PATH="$HOME/.foundry/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NAME="${1:-}"
CHAIN_ID="${2:-${CHAIN_ID:-}}"
if [ -z "$NAME" ]; then
  echo "usage: $0 <deploymentName> [chainId]   (example: $0 BETH 8453)" >&2
  exit 2
fi

# The schema version travels with every record. A consumer reads it to detect a
# migration. Raise it whenever a field changes meaning or leaves the record.
SCHEMA_VERSION=1

for tool in jq forge cast; do
  command -v "$tool" >/dev/null || { echo "record.sh: $tool is not installed" >&2; exit 2; }
done

# ---- 1. the pending file ----------------------------------------------------
# The chain id names the exact file. Sorting the glob would be wrong, because a
# string sort puts 31337 ahead of 8453. A local test run would then hijack a
# real deploy. So the script refuses to guess when several files match.
if [ -n "$CHAIN_ID" ]; then
  PENDING="deployments/.pending/$NAME.$CHAIN_ID.json"
  if [ ! -f "$PENDING" ]; then
    echo "record.sh: no pending file at $PENDING" >&2
    echo "record.sh: run the deploy first, or pass the right chain id" >&2
    exit 1
  fi
else
  PENDING=""
  MATCHES=""
  MATCH_COUNT=0
  for candidate in "deployments/.pending/$NAME."*.json; do
    [ -e "$candidate" ] || continue
    PENDING="$candidate"
    MATCHES="$MATCHES $candidate"
    MATCH_COUNT=$((MATCH_COUNT + 1))
  done
  if [ "$MATCH_COUNT" -eq 0 ]; then
    echo "record.sh: no pending file at deployments/.pending/$NAME.<chainId>.json" >&2
    echo "record.sh: run the deploy first, or pass the right deployment name" >&2
    exit 1
  fi
  if [ "$MATCH_COUNT" -gt 1 ]; then
    echo "record.sh: $MATCH_COUNT pending files match $NAME:$MATCHES" >&2
    echo "record.sh: name the chain, as in '$0 $NAME <chainId>'" >&2
    exit 1
  fi
fi

PENDING_CHAIN_ID=$(jq -r .chainId "$PENDING")
if [ -n "$CHAIN_ID" ] && [ "$PENDING_CHAIN_ID" != "$CHAIN_ID" ]; then
  echo "record.sh: $PENDING names chain $PENDING_CHAIN_ID, not $CHAIN_ID" >&2
  exit 1
fi
CHAIN_ID="$PENDING_CHAIN_ID"

# ---- 2. the broadcast artifact ----------------------------------------------
BROADCAST="broadcast/Deploy_$NAME.s.sol/$CHAIN_ID/run-latest.json"
if [ ! -f "$BROADCAST" ]; then
  echo "record.sh: no broadcast artifact at $BROADCAST" >&2
  exit 1
fi
GIT_COMMIT=$(jq -r '.commit // "unknown"' "$BROADCAST")

# GNU date takes -d, BSD date takes -r. Try GNU first, then fall back.
epoch_to_iso() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}
# foundry writes the timestamp in milliseconds.
DEPLOYED_AT=$(epoch_to_iso "$(jq -r '.timestamp' "$BROADCAST" | awk '{printf "%d", $1/1000}')")

mkdir -p deployments/solcInputs

lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

# ---- 2b. the outgoing implementation record ---------------------------------
# The loop writes the implementation record before it reaches the proxy. The
# proxy's history entry must describe the OLD implementation, so copy that
# record now. The copy is the only remaining source for its five extra fields.
OLD_IMPL_SNAPSHOT=""
if [ -f "deployments/$NAME.implementation.$CHAIN_ID.json" ]; then
  OLD_IMPL_SNAPSHOT=$(mktemp)
  cp "deployments/$NAME.implementation.$CHAIN_ID.json" "$OLD_IMPL_SNAPSHOT"
fi
drop_snapshot() {
  if [ -n "$OLD_IMPL_SNAPSHOT" ]; then rm -f "$OLD_IMPL_SNAPSHOT"; fi
}
trap drop_snapshot EXIT

# Prints the standard-json compiler input for one contract, and echoes the
# 16-character content hash it stored it under.
store_solc_input() { # store_solc_input <sourcePath> <contractName>
  local tmp err hash
  tmp=$(mktemp)
  err=$(mktemp)
  if ! forge verify-contract 0x0000000000000000000000000000000000000001 "$1:$2" \
    --show-standard-json-input >"$tmp" 2>"$err"; then
    echo "record.sh: forge verify-contract --show-standard-json-input failed for $2 ($1)" >&2
    cat "$err" >&2
    rm -f "$tmp" "$err"
    exit 1
  fi
  rm -f "$err"
  hash=$(shasum -a 256 "$tmp" | cut -c1-16)
  if [ ! -f "deployments/solcInputs/$hash.json" ]; then
    mv "$tmp" "deployments/solcInputs/$hash.json"
  else
    rm -f "$tmp"
  fi
  printf '%s' "$hash"
}

# ---- 3. one record per role -------------------------------------------------
COUNT=$(jq -r '.roles | length' "$PENDING")
PROXY_RECORD=""

for i in $(seq 0 $((COUNT - 1))); do
  ROLE=$(jq -r ".roles[$i]" "$PENDING")
  ADDR=$(jq -r ".addresses[$i]" "$PENDING")
  CONTRACT=$(jq -r ".contractNames[$i]" "$PENDING")
  SOURCE=$(jq -r ".sourcePaths[$i]" "$PENDING")
  ADDR_LC=$(lower "$ADDR")

  ARTIFACT="out/$(basename "$SOURCE")/$CONTRACT.json"
  [ -f "$ARTIFACT" ] || { echo "record.sh: no artifact at $ARTIFACT; run forge build" >&2; exit 1; }

  # Find the transaction. A contract is either created by its own transaction,
  # or created inside another contract's constructor.
  TX=$(jq -c --arg a "$ADDR_LC" '.transactions[] | select((.contractAddress // "") | ascii_downcase == $a)' "$BROADCAST")
  if [ -n "$TX" ]; then
    TX_HASH=$(printf '%s' "$TX" | jq -r .hash)
    CREATION_INPUT=$(printf '%s' "$TX" | jq -r .transaction.input)
    CREATED_BY=""
  else
    PARENT=$(jq -c --arg a "$ADDR_LC" \
      '.transactions[] | select([.additionalContracts[]? | (.address | ascii_downcase)] | index($a) != null)' "$BROADCAST")
    [ -n "$PARENT" ] || { echo "record.sh: $ADDR appears in no transaction in $BROADCAST" >&2; exit 1; }
    TX_HASH=$(printf '%s' "$PARENT" | jq -r .hash)
    CREATED_BY=$(printf '%s' "$PARENT" | jq -r .contractAddress)
    CREATION_INPUT=$(printf '%s' "$PARENT" | jq -r --arg a "$ADDR_LC" \
      '.additionalContracts[] | select((.address | ascii_downcase) == $a) | .initCode')
  fi

  RECEIPT=$(jq -c --arg h "$TX_HASH" '.receipts[] | select(.transactionHash == $h)' "$BROADCAST")

  # The creation input is the creation bytecode followed by the ABI-encoded
  # constructor arguments. Removing the known prefix leaves the arguments.
  CREATION_CODE=$(jq -r .bytecode.object "$ARTIFACT")
  case "$CREATION_INPUT" in
    "$CREATION_CODE"*) ENCODED_ARGS="0x${CREATION_INPUT:${#CREATION_CODE}}" ;;
    *) echo "record.sh: the creation code of $CONTRACT does not prefix its on-chain input" >&2
       echo "record.sh: rebuild with forge build, from the commit that deployed it" >&2
       exit 1 ;;
  esac

  SOLC_HASH=$(store_solc_input "$SOURCE" "$CONTRACT")
  OUT="deployments/$NAME.$ROLE.$CHAIN_ID.json"

  jq -n \
    --arg name "$NAME" --arg role "$ROLE" --argjson chainId "$CHAIN_ID" \
    --arg address "$ADDR" --arg contractName "$CONTRACT" --arg sourcePath "$SOURCE" \
    --arg encodedConstructorArgs "$ENCODED_ARGS" --arg transactionHash "$TX_HASH" \
    --argjson receipt "$RECEIPT" --slurpfile artifact "$ARTIFACT" \
    --arg solcInputHash "$SOLC_HASH" --arg gitCommit "$GIT_COMMIT" --arg deployedAt "$DEPLOYED_AT" \
    --argjson schemaVersion "$SCHEMA_VERSION" \
    '{
      schemaVersion: $schemaVersion,
      deploymentName: $name, role: $role, chainId: $chainId,
      address: $address, contractName: $contractName, sourcePath: $sourcePath,
      encodedConstructorArgs: $encodedConstructorArgs,
      transactionHash: $transactionHash, receipt: $receipt,
      artifact: $artifact[0],
      solcInputHash: $solcInputHash,
      compiler: {
        version: $artifact[0].metadata.compiler.version,
        optimizer: $artifact[0].metadata.settings.optimizer.enabled,
        runs: $artifact[0].metadata.settings.optimizer.runs,
        evmVersion: $artifact[0].metadata.settings.evmVersion
      },
      gitCommit: $gitCommit, deployedAt: $deployedAt
    }' >"$OUT.tmp"

  # ---- role-specific fields -------------------------------------------------
  if [ "$ROLE" = "proxyAdmin" ]; then
    OWNER=$(jq -r .proxyOwner "$PENDING")
    jq --arg owner "$OWNER" --arg createdBy "$CREATED_BY" \
      '. + {owner: $owner, createdBy: $createdBy}' "$OUT.tmp" >"$OUT.tmp2" && mv "$OUT.tmp2" "$OUT.tmp"
  fi

  if [ "$ROLE" = "proxy" ]; then
    IMPL=$(jq -r '.addresses[.roles | index("implementation")]' "$PENDING")
    PADMIN=$(jq -r '.addresses[.roles | index("proxyAdmin")]' "$PENDING")

    # Carry the previous implementation into history, if it changed.
    PREV_HISTORY='[]'
    PREV_COUNT=0
    if [ -f "$OUT" ]; then
      PREV_IMPL=$(jq -r '.implementation // ""' "$OUT")
      PREV_HISTORY=$(jq -c '.history // []' "$OUT")
      PREV_COUNT=$(jq -r '.numDeployments // 1' "$OUT")
      if [ -n "$PREV_IMPL" ] && [ "$(lower "$PREV_IMPL")" != "$(lower "$IMPL")" ]; then
        # The six fields describe the old implementation, never the proxy. An
        # operator verifies that implementation later from these fields alone.
        SNAPSHOT_ADDR=""
        if [ -n "$OLD_IMPL_SNAPSHOT" ]; then
          SNAPSHOT_ADDR=$(lower "$(jq -r '.address // ""' "$OLD_IMPL_SNAPSHOT")")
        fi
        if [ -n "$SNAPSHOT_ADDR" ] && [ "$SNAPSHOT_ADDR" = "$(lower "$PREV_IMPL")" ]; then
          ENTRY=$(jq -c '{implementation: .address, contractName: .contractName,
                          solcInputHash: .solcInputHash, gitCommit: .gitCommit,
                          transactionHash: .transactionHash, deployedAt: .deployedAt}' \
            "$OLD_IMPL_SNAPSHOT")
        else
          # Nobody recorded the old implementation, so five fields are lost.
          echo "record.sh: no record for the old implementation $PREV_IMPL" >&2
          echo "record.sh: its history entry holds the address only" >&2
          ENTRY=$(jq -nc --arg impl "$PREV_IMPL" \
            '{implementation: $impl, contractName: null, solcInputHash: null,
              gitCommit: null, transactionHash: null, deployedAt: null}')
        fi
        PREV_HISTORY=$(printf '%s' "$PREV_HISTORY" | jq -c --argjson e "$ENTRY" '. + [$e]')
        PREV_COUNT=$((PREV_COUNT + 1))
      fi
    else
      PREV_COUNT=1
    fi

    jq --arg impl "$IMPL" --arg padmin "$PADMIN" \
       --argjson history "$PREV_HISTORY" --argjson count "$PREV_COUNT" \
       --slurpfile pending "$PENDING" \
      '. + {
        implementation: $impl,
        proxyAdmin: $padmin,
        bridgeConfig: {
          asset: $pending[0].asset,
          assetDecimals: $pending[0].assetDecimals,
          targetDecimals: $pending[0].targetDecimals,
          depositUnit: $pending[0].depositUnit,
          defaultAdmin: $pending[0].defaultAdmin,
          adminDelay: $pending[0].adminDelay,
          bridgeAdmin: $pending[0].bridgeAdmin,
          proxyOwner: $pending[0].proxyOwner,
          attestors: $pending[0].attestors,
          threshold: $pending[0].threshold,
          depositLimits: {min: $pending[0].depositMin, max: $pending[0].depositMax},
          withdrawLimits: {min: $pending[0].withdrawMin, max: $pending[0].withdrawMax}
        },
        numDeployments: $count,
        history: $history
      }' "$OUT.tmp" >"$OUT.tmp2" && mv "$OUT.tmp2" "$OUT.tmp"
    PROXY_RECORD="$OUT"
  fi

  mv "$OUT.tmp" "$OUT"
  echo "recorded $ROLE  $ADDR  -> $OUT"
done

rm -f "$PENDING"
rmdir deployments/.pending 2>/dev/null || true
echo "done. The proxy record is $PROXY_RECORD"
