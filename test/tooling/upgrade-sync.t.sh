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

lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
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

if [ "$FAILURES" -eq 0 ]; then echo "upgrade-sync.t.sh: all checks passed"; else echo "upgrade-sync.t.sh: $FAILURES check(s) failed"; exit 1; fi
