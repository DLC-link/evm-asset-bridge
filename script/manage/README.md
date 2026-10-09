# Management scripts

This is the operator runbook for the post-deploy admin actions.

## 1. What these scripts are

`script/manage/` holds one script for each admin action. The root `script/`
folder holds the deploy scripts only. Each management file drives one contract
function. The file name matches that function.

A folder names a contract, and `DEPLOYMENT` names one instance of that
contract. The scripts for `BitSafeEvmAssetBridge` live in
`script/manage/BitSafeEvmAssetBridge/`. `DEPLOYMENT=BETH` picks the
production BETH bridge, and the deployment records pin its addresses. The
two Sepolia instances are `BETH_DEVNET` and `BETH_TESTNET`. The `CHYPE`,
`CHYPE_DEVNET` and `CHYPE_TESTNET` deployments on HyperEVM use the same
folder. The root README lists every deployment name.

**Warning.** The guard checks the contract name only. It cannot tell two
deployments of the same contract apart. A wrong `DEPLOYMENT` value that
names another real `BitSafeEvmAssetBridge` deployment still passes every
check. Run `make manage-status DEPLOYMENT=<name> RPC_URL=<url>` first, and
confirm the printed bridge address. Fix `DEPLOYMENT` before you send a real
transaction.

A second deployment of the same contract needs no new script. It needs one
set of deployment records and one `.env.{network}.{deployment}` file. This
promise covers the management scripts only. The deploy script still needs
one new file for each deployment.

`script/manage/ManageBase.s.sol` holds the shared code.
`script/manage/BitSafeEvmAssetBridge/BridgeManage.s.sol` binds that base to
`BitSafeEvmAssetBridge`.

### Errors from a wrong `DEPLOYMENT` or `RPC_URL`

A script reverts with `DeploymentNotSet` when `DEPLOYMENT` is empty. Set
`DEPLOYMENT`, or load an environment file that sets it.

A script reverts with `ContractMismatch(recordContractName,
expectedContractName)` when the two names disagree. The `DEPLOYMENT` value
then names a deployment of another contract. The operator may also have run
the script from the wrong folder. Check both before you retry.

A script reverts with a `vm.readFile` error when no implementation record
exists for the current chain. The message names the missing file, such as
`deployments/NOSUCH.implementation.31337.json`. This happens when `RPC_URL`
points at a chain that `DEPLOYMENT` never deployed to. Check `RPC_URL`, and
check `DEPLOYMENT`.

Every script reads the deployment record in `deployments/`. The record names
the proxy address for the current chain. The record also names its own chain
id. The script stops when the two chain ids disagree.

One `make` target runs every script. The target is `make manage`. It carries
the Foundry path itself. No `make` command needs a `PATH` export. A direct
call to `propose.sh` still needs one.

## 2. The two modes

Every action script runs in one of two modes. The `SAFE` environment variable
picks the mode. `make manage` reads `SAFE`. It then builds the correct
command.

| Mode | How to select it | What the script does |
| --- | --- | --- |
| Direct broadcast | Leave `SAFE` empty. Set `SIGNER`. | It sends the transaction from your wallet. |
| Safe | Set `SAFE=0xYourSafe`. | It writes a transaction envelope to `deployments/.safe/`. |

A Safe-mode run sends nothing. The script first simulates the call from the
Safe address. The simulation proves that the Safe holds the role. It also
proves that the arguments are valid. The script then writes the envelope file.

The envelope path is `deployments/.safe/<DEPLOYMENT>.<chainId>.<action>.json`.

Both modes build the calldata with the same `encode` function. A Safe
therefore signs the exact bytes that a direct broadcast sends.

Direct broadcast:

```bash
make manage DEPLOYMENT=BETH SCRIPT=Pause SIG='run()' \
  RPC_URL=https://... SIGNER="--account sentry"
```

Safe:

```bash
SAFE=0xYourSafe make manage DEPLOYMENT=BETH SCRIPT=Pause SIG='run()' \
  RPC_URL=https://...
```

`make manage` refuses a direct broadcast without `SIGNER`. It stops with a
guard error. Safe mode needs no `SIGNER`.

`make manage` names its mode on its first line of output. An exported `SAFE`
picks Safe mode, and that export is easy to forget. Read the line before you
wait for a transaction:

```
manage: Safe mode. It writes an envelope for 0xYourSafe and broadcasts nothing.
manage: direct broadcast. It signs and sends a transaction now.
```

The line names no part of `SIGNER`. That value can hold `--private-key` or
`--password`, and a terminal log keeps whatever a command prints. You pass
`SIGNER` on the make line, so the line would only repeat what your command
already shows. `make` hides the command it runs, for the same reason.

Use a keystore account or a hardware wallet for a direct broadcast. A raw
private key on the command line enters your shell history.

### Set the variables once

`make` reads `DEPLOYMENT`, `RPC_URL` and `SAFE` from the environment. Export
those three once. Each command below then stays short.

```bash
export DEPLOYMENT=BETH
export RPC_URL=https://...
export SAFE=0xYourSafe                   # Safe mode needs this
```

Do not export `SIGNER`. It names a signing key, and every command takes it on
the make line. One exported key would sign a deploy, an admin action and a Safe
proposal alike. `make` stops when `SIGNER` comes from your environment, and it
names the fix.

Load the environment file once for your shell instead. It sets `DEPLOYMENT`,
and it sets `SAFE`. Every command below then needs neither:

```bash
set -a; source .env.sepolia.BETH_DEVNET; set +a
```

Pass `DEPLOYMENT=BETH_DEVNET` on a `make` line instead, when you do not load
the file. The management targets set no default, and they stop without it.

That file carries no `RPC_URL`. A keyed endpoint URL is a secret. Pass
`RPC_URL` on the command line instead. You can also export it yourself.

Unset `SAFE` before a direct broadcast:

```bash
unset SAFE
```

## 3. The action table

Every command follows one template:

```bash
make manage SCRIPT=<Script> SIG='<sig>' ARGS='<arguments>' \
  RPC_URL=https://... SIGNER="--account <name>"
```

`SCRIPT` names the file `script/manage/BitSafeEvmAssetBridge/<Script>.s.sol`.
`MANAGE_CONTRACT` names that folder, and it defaults to
`BitSafeEvmAssetBridge`. A folder for another contract needs that variable.
`SIG` names the `run` signature of that file. `ARGS` holds the arguments.
Several arguments need one pair of quotes.

The table below leaves out `RPC_URL`, `SAFE` and `DEPLOYMENT`. Export those
three first, or load the environment file. Add `SIGNER` to every line
yourself, and read the `Role` column for the role that key must hold. Read the previous
section for that step. The `Role` column names the sender that the contract
accepts. In Safe mode that sender is the Safe itself.

| Script | Role | Command |
| --- | --- | --- |
| `Status` | none (read only) | `make manage SCRIPT=Status SIG='run()'` |
| `Pause` | `BRIDGE_ADMIN` or `SENTRY` | `make manage SCRIPT=Pause SIG='run()'` |
| `Unpause` | `BRIDGE_ADMIN` | `make manage SCRIPT=Unpause SIG='run()'` |
| `SetThreshold` | `DEFAULT_ADMIN` | `make manage SCRIPT=SetThreshold SIG='run(uint256)' ARGS=3` |
| `SetDepositLimits` | `BRIDGE_ADMIN` | `make manage SCRIPT=SetDepositLimits SIG='run(uint256,uint256)' ARGS='100000000 900000000'` |
| `SetWithdrawLimits` | `BRIDGE_ADMIN` | `make manage SCRIPT=SetWithdrawLimits SIG='run(uint256,uint256)' ARGS='1 700000000'` |
| `SetWithdrawRateLimit` | `BRIDGE_ADMIN` | `make manage SCRIPT=SetWithdrawRateLimit SIG='run(uint256,uint256)' ARGS='100000000000000000000 86400'` |
| `SetWithdrawalHorizon` | `BRIDGE_ADMIN` | `make manage SCRIPT=SetWithdrawalHorizon SIG='run(uint256)' ARGS=172800` |
| `VoidWithdrawRequest` | `BRIDGE_ADMIN` | `make manage SCRIPT=VoidWithdrawRequest SIG='run(bytes)' ARGS=0x0011deadbeef22` |
| `RescueERC20` | `BRIDGE_ADMIN` | `make manage SCRIPT=RescueERC20 SIG='run(address,address,uint256)' ARGS='0xToken 0xTo 100'` |
| `RescueETH` | `BRIDGE_ADMIN` | `make manage SCRIPT=RescueETH SIG='run(address,uint256)' ARGS='0xTo 1000000000000000000'` |
| `RescueSurplus` | `BRIDGE_ADMIN` | `make manage SCRIPT=RescueSurplus SIG='run(address,uint256)' ARGS='0xTo 1000000000000000000'` |
| `GrantRole` | `DEFAULT_ADMIN` | `make manage SCRIPT=GrantRole SIG='run(string,address)' ARGS='SENTRY 0xYourSentry'` |
| `RevokeRole` | `DEFAULT_ADMIN` | `make manage SCRIPT=RevokeRole SIG='run(string,address)' ARGS='SENTRY 0xOldSentry'` |
| `RenounceRole` | the role holder itself | `make manage SCRIPT=RenounceRole SIG='run(string,address)' ARGS='SENTRY 0xYourOwnAddress'` |
| `BeginDefaultAdminTransfer` | `DEFAULT_ADMIN` | `make manage SCRIPT=BeginDefaultAdminTransfer SIG='run(address)' ARGS=0xNewAdmin` |
| `AcceptDefaultAdminTransfer` | the incoming admin | `make manage SCRIPT=AcceptDefaultAdminTransfer SIG='run()'` |
| `CancelDefaultAdminTransfer` | `DEFAULT_ADMIN` | `make manage SCRIPT=CancelDefaultAdminTransfer SIG='run()'` |
| `ChangeDefaultAdminDelay` | `DEFAULT_ADMIN` | `make manage SCRIPT=ChangeDefaultAdminDelay SIG='run(uint256)' ARGS=259200` |
| `RollbackDefaultAdminDelay` | `DEFAULT_ADMIN` | `make manage SCRIPT=RollbackDefaultAdminDelay SIG='run()'` |
| `ScheduleUpgrade` | timelock proposer (`PROXY_OWNER`) | `make upgrade-schedule` (section 12) |
| `ExecuteUpgrade` | timelock executor (`PROXY_OWNER`) | `make upgrade-execute` (section 12) |
| `CancelUpgrade` | timelock canceller (`PROXY_OWNER`) | `make upgrade-cancel` (section 12) |

Copy one line. Change the `ARGS` value. Send the command.

Read these five notes with the table:

- `Status` sends nothing. It therefore needs no `SIGNER` and no `SAFE`.
  `make manage-status RPC_URL=https://...` is the shorter form of the same
  command.
- `GrantRole` and `RevokeRole` take a role name. They do not take a role hash.
  The three legal names are `BRIDGE_ADMIN`, `ATTESTOR` and `SENTRY`. The
  scripts reject `DEFAULT_ADMIN`. Use `BeginDefaultAdminTransfer` for that
  role.
- `RenounceRole` needs the caller's own address as the second argument. The
  `ATTESTOR` role rejects a renounce. An attestor leaves through `RevokeRole`.
- `RescueERC20` rejects the bridged asset. Use `RescueSurplus` for a
  bridged-asset balance above `totalLocked`.
- `RescueETH` reverts when the bridged asset is ETH. Use `RescueSurplus` on an
  ETH bridge.
- The three upgrade scripts live in `script/manage/upgrade/`, not in the
  bridge folder. They have their own `make` targets. Section 12 holds the
  whole sequence.

This example raises the signature threshold to 3:

```bash
make manage SCRIPT=SetThreshold SIG='run(uint256)' ARGS=3 \
  RPC_URL=https://... SIGNER="--account defaultAdmin"
```

Read the live configuration first. This target needs no wallet:

```bash
make manage-status RPC_URL=https://...
```

## 4. Rules for the attestor set and the limits

The contract sets no order between a role change and a threshold change. One
order still prevents a stop in withdrawals. This section gives the rules.

### Grow the attestor set: any order

Run `GrantRole ATTESTOR` and `SetThreshold` in either order. The contract
accepts both. A threshold above the current attestor count still reverts. The
contract checks no other ratio between the two values. The team sets that
ratio by governance policy.

```bash
# 3 attestors, threshold 2. Add a fourth attestor. Then raise the threshold.
make manage SCRIPT=GrantRole SIG='run(string,address)' \
  ARGS='ATTESTOR 0xNewAttestor' \
  RPC_URL=https://... SIGNER="--account defaultAdmin"
make manage SCRIPT=SetThreshold SIG='run(uint256)' ARGS=3 \
  RPC_URL=https://... SIGNER="--account defaultAdmin"
```

### Shrink the attestor set: lower, then revoke

Run `SetThreshold` first. Run `RevokeRole ATTESTOR` second. The contract
accepts the reverse order too. The order above prevents an outage.

A revoke never reverts on the threshold. A revoke can leave the attestor count
below the threshold. The remaining attestors cannot collect enough signatures.
Every withdrawal then halts.

An admin lowers the threshold to recover. One remaining attestor blocks that
recovery. `MIN_THRESHOLD` is 2. The attestor count is the upper bound. No
threshold value obeys both bounds at a count of 1. Only a grant of more
attestors recovers the bridge from that state. Never let the attestor count
fall below 2.

```bash
# 4 attestors, threshold 3. Remove one attestor.
make manage SCRIPT=SetThreshold SIG='run(uint256)' ARGS=2 \
  RPC_URL=https://... SIGNER="--account defaultAdmin"
make manage SCRIPT=RevokeRole SIG='run(string,address)' \
  ARGS='ATTESTOR 0xOldAttestor' \
  RPC_URL=https://... SIGNER="--account defaultAdmin"
```

### The threshold bounds

`SetThreshold` accepts a value that obeys two rules:

- The value must be 2 or more. `MIN_THRESHOLD` is 2.
- The value must not exceed the attestor count.

### The deposit limit granularity

`SetDepositLimits` obeys one more rule than `SetWithdrawLimits`. The band must
hold at least one amount that the target chain can express. The bridge rounds
`maxAmount` down to a multiple of `depositUnit()`. The call reverts with
`InvalidLimits` when that rounded value is 0. It reverts the same way when the
rounded value falls below `minAmount`. Read `depositUnit` from
`make manage-status` before you pick the band.

## 5. The withdrawal horizon rule

The horizon bounds how far a withdrawal deadline can sit past the current
time. A horizon of 0 disables the bound.

One `SetWithdrawalHorizon` transaction activates the bound. A change
invalidates every unsubmitted bundle whose deadline lies past the new bound.
The signers must re-sign those requests. Expect a short delay in withdrawals
after this change. Start with a long
horizon, such as 48 hours.

```bash
make manage SCRIPT=SetWithdrawalHorizon SIG='run(uint256)' ARGS=172800 \
  RPC_URL=https://... SIGNER="--account bridgeAdmin"
```

### Recover after a long pause

A pause longer than the horizon expires every pending bundle. The request ids
stay unused, so no funds are at risk. Recover in three steps:

1. Raise the horizon above the age of the oldest pending request.
2. Let the signers re-sign the pending requests.
3. Lower the horizon after the pending requests clear.

## 6. The default admin transfer

`DEFAULT_ADMIN_ROLE` moves in two steps, with one delay between them. Five
scripts govern the role. Three scripts drive the transfer. Two scripts drive
the delay.

| Step | Script | Sender |
| --- | --- | --- |
| 1 | `BeginDefaultAdminTransfer` | the current admin |
| 2 | `AcceptDefaultAdminTransfer` | the **incoming** admin |
| any | `CancelDefaultAdminTransfer` | the current admin |

The incoming admin sends step 2. The current admin cannot send it. Step 2
reverts before the scheduled delay passes. Read `pendingAdminAt` from
`make manage-status` to see the schedule.

An incoming Safe proposes step 2. Set `SAFE` to that incoming Safe:

```bash
SAFE=0xYourIncomingSafe make manage SCRIPT=AcceptDefaultAdminTransfer \
  SIG='run()' RPC_URL=https://...
```

The two delay scripts are `ChangeDefaultAdminDelay` and
`RollbackDefaultAdminDelay`. The current admin sends both. A new delay takes
effect only after its own wait period passes. An increase waits up to
`defaultAdminDelayIncreaseWait()`. A decrease waits the difference between the
old delay and the new delay.

## 7. The complete Safe flow

The flow has three parts. You write the envelope. You propose it. The owners
then confirm it.

**Step 1. Write the envelope.** Set `SAFE` to your Safe address:

```bash
SAFE=0xYourSafe make manage SCRIPT=Pause SIG='run()' RPC_URL=https://...
```

The script prints the envelope path. For chain 11155111 the path is
`deployments/.safe/BETH.11155111.pause.json`.

**Step 2. Propose the envelope.** The proposer signs the Safe transaction
hash. The proposer then posts it. The script deletes the envelope after the
service accepts the proposal:

```bash
make propose ENVELOPE=deployments/.safe/BETH.11155111.pause.json \
  RPC_URL=https://... SIGNER="--account proposer"
```

`SIGNER` names the proposer key here. Pass it on the make line. `make` stops
when `SIGNER` comes from your environment, so an admin key cannot sign a
proposal by accident.

The `make` target calls `script/manage/safe/propose.sh`. Call the script
directly if you prefer. The direct form needs every variable. It also needs
the Foundry binaries on your `PATH`. The `make` target adds that path itself:

```bash
PATH="$HOME/.foundry/bin:$PATH" RPC_URL=https://... \
  SIGNER="--account proposer" \
  ./script/manage/safe/propose.sh deployments/.safe/BETH.11155111.pause.json
```

The script prints the action, the Safe, the target, the calldata, the nonce and
the hash. Read the target and the calldata before you sign. An envelope file
name carries no arguments. A later run of the same action overwrites the file.

Set `DRY_RUN=1` to print the request. A dry run posts nothing. A dry run also
never reads the signing key, so it needs no `SIGNER`. A dry run still reads the
queue of the service. A dry run keeps the envelope file. Both forms accept the
variable:

```bash
DRY_RUN=1 make propose ENVELOPE=deployments/.safe/BETH.11155111.pause.json \
  RPC_URL=https://...

DRY_RUN=1 PATH="$HOME/.foundry/bin:$PATH" RPC_URL=https://... \
  ./script/manage/safe/propose.sh deployments/.safe/BETH.11155111.pause.json
```

Give `SIGNER` a keystore account or a hardware wallet. `--private-key` puts the
key into the argument list of `cast`. A local `ps` then shows that key to every
user on the machine.

**Step 3. The owners confirm.** The script prints the queue link on success.
The owners open that link. The owners then confirm the transaction. One owner
executes it.

The proposer needs no ETH. The proposer needs no owner rights. The proposer
must be a registered delegate of the Safe. Section 8 covers that registration.

### The signing prompt needs a terminal

`cast wallet sign --account <name>` opens a password prompt. The prompt needs a
real terminal. A non-interactive shell fails with
`Error: Device not configured (os error 6)`.

An operator therefore runs `make propose` in a real terminal. Automation passes
the `--password-file` option of `cast` instead:

```bash
SIGNER="--account proposer --password-file /run/secrets/proposer.pass"
```

### The nonce that a proposal takes

The Safe contract holds the executed nonce. The Safe Transaction Service holds
a separate queue of proposed transactions. `propose.sh` reads both sources. It
takes the first free slot above both values. Two proposals in one queue
therefore take two different nonces. The script prints the chosen nonce and its
source in one line.

Set `NONCE` to pin the value. An operator needs this variable for a batch of
proposals. The value must be a non-negative integer. `make propose` forwards
the value:

```bash
make propose ENVELOPE=deployments/.safe/BETH.11155111.pause.json \
  RPC_URL=https://... NONCE=12
```

The script prints a loud warning when the service gives no queue answer. The
run then continues with the on-chain nonce. A queued proposal can hold that
nonce already. The Safe interface shows such a conflict to the owners. Open the
queue after every warning of this kind.

### Safe mode cannot pre-stage a time-gated action

Safe mode simulates the call from the Safe address first. The simulation must
succeed at the current block. Two actions fail that simulation before their
time arrives:

- `AcceptDefaultAdminTransfer` reverts until the schedule of the transfer
  passes.
- `Unpause` reverts while the bridge runs.

An operator cannot build these two envelopes in advance. The operator waits for
the condition. The operator then writes the envelope. The operator proposes it
in the same session. Plan the owner confirmations for that later moment.

## 8. Delegate registration stays manual

A Safe **owner** must register the delegate. The proposer cannot register
itself. Owners keep their keys in hardware wallets. This repo therefore holds
no script for the step. safe-cli and the Safe interface already sign the
registration message with a hardware wallet.

### The mechanism

The delegate signs an EIP-712 message. The message type is
`Delegate{address delegateAddress,uint256 totp}`. The domain is
`{name: "Safe Transaction Service", version: "1.0", chainId: <chainId>}`.
`totp` is the current Unix time divided by 3600. The division drops the
remainder. The value therefore changes once per hour.

The service records the delegate on the Safe. The service then fills the
`proposedByDelegate` field of each proposal from that delegate. The service
never counts a delegate as a confirmation. A proposer can therefore propose a
transaction. A proposer can never approve one.

### Route A: safe-cli

```bash
pip install safe-cli
safe-cli 0xYourSafe $RPC_URL
```

Load an owner key in the session. Then add the delegate:

```
> load_ledger_cli_owners                        # a hardware wallet
> add_delegate 0xYourProposer "bridge proposer"
```

`remove_delegate 0xYourProposer` reverses the step. Run `help` first. The
argument order changes between safe-cli releases.

### Route B: the Safe user interface

Open https://app.safe.global. Select the Safe. Open `Settings`. Find the
delegate list. Add the proposer address. Sign the prompt with an owner key.

Some Safe releases hide this list. Use route A when you cannot find it.

## 9. The Safe API key

The Safe Transaction Service limits an anonymous client to 2 requests per
second. `SAFE_API_KEY` raises that limit. Get a key at
https://developer.safe.global.

Export the key before you propose:

```bash
export SAFE_API_KEY=...
```

`propose.sh` sends the key as a bearer token. The key travels on stdin. A local
`ps` therefore cannot show it. The variable stays optional. One proposal sends
two requests to the service. A single run therefore stays inside the anonymous
limit.

Keep the key out of every tracked file. `.env.sepolia.BETH_DEVNET` holds no
secret.

## 10. Tests for this tooling

`script/manage/safe/propose.sh` has offline tests in
`test/tooling/propose.t.sh`. A fake `curl` answers the service. A fake `cast`
answers the chain. CI runs the suite on every push.

The upgrade scripts have tests in `test/manage/UpgradeActions.t.sol` and
`test/manage/DeployNextImplementation.t.sol`. The whole upgrade sequence
runs against a local anvil in `test/tooling/upgrade-sync.t.sh`. CI runs
all three.

The script maps each chain to a Safe short name. On a new chain, open the
queue link that the script prints, and check that it names the correct Safe.

## 11. Which Safes govern a deployment

Two Safes govern a production deployment. `GOVERNANCE.md` at the repo root
describes them for a non-technical reader.

1. **The multi-organisation Safe.** BitSafe and the operator partners control
   it together. It holds `DEFAULT_ADMIN`, and it is the proposer, canceller,
   and executor of the timelock that owns the `ProxyAdmin`. `DEFAULT_ADMIN`
   and `PROXY_OWNER` therefore name the same address on mainnet.
2. **The BitSafe Safe.** BitSafe alone controls it. It holds `BRIDGE_ADMIN`.

No Safe owns the `ProxyAdmin` directly. The timelock owns it, and an upgrade
waits `TIMELOCK_DELAY` seconds between its proposal and its execution. The
Sepolia instances use one Safe for every authority.

The tooling does not depend on the shape. `SAFE` names the Safe on every
invocation. An operator points each action at the Safe that holds its role.

## 12. Upgrade through the timelock

The `ProxyAdmin` of every deployment belongs to an OpenZeppelin
`TimelockController`. An upgrade therefore takes three calls on the
timelock: `schedule`, a wait of at least the minimum delay, and `execute`.
Every argument of those calls must match to the byte. The scripts in
`script/manage/upgrade/` build them from the deployment records, and the
operator names no address.

The scripts work for any recorded deployment whose `proxyAdmin` record
names a timelock as owner. They read the roles `proxy`, `proxyAdmin`,
`timelock` and `nextImplementation`, and nothing else. They hold no bridge
knowledge.

Every target needs `DEPLOYMENT` and `RPC_URL`. Load the environment file
first, as section 2 describes. Each target runs the sync before it acts,
and again after a direct broadcast. The records therefore match the chain
when the command returns.

### 12.1 Deploy the next implementation

```bash
make upgrade-deploy SIGNER="--account deployer --slow"
```

The command deploys the contract that the current implementation record
names, records it as `deployments/<name>.nextImplementation.<chainId>.json`,
and syncs. `CONTRACT=src/Other.sol:Other` deploys another contract. The
script refuses a contract whose constructor takes arguments. Every
implementation we ship only disables its initializers.

Pass `--slow` when the deployer key carries an EIP-7702 delegation. Any funded key may deploy an implementation. The deploy grants no
power; the timelock operation does.

One `nextImplementation` record exists per deployment at a time. The
command refuses a second deploy while the record exists. Delete the file by
hand to drop an implementation you no longer want. Section 12.7 says when.

### 12.2 Verify the source

```bash
make verify CHAIN_ID=<chainId>
```

`verify.sh` reads the roles from the file names, so it submits the new
record with no change. Commit the record and the compiler input.

### 12.3 Review the storage layout by hand

The bridge uses ERC-7201 namespaced storage. `solc` therefore emits an
empty `storageLayout`, and no automated layout comparison proves anything
about this contract. A human reviews the diff instead.

```bash
git diff <gitCommit> HEAD -- src/
```

`gitCommit` comes from the current implementation record. Open the
`BridgeStorage` struct in `src/BitSafeEvmAssetBridge.sol`. Check three
points. No field disappears. No field changes its type or its position.
Every new field comes after the last existing field. A second engineer confirms
the same three points. Do not schedule before both reviews are done.

### 12.4 Schedule

```bash
SAFE=0xProxyOwnerSafe make upgrade-schedule
make propose ENVELOPE=deployments/.safe/<name>.<chainId>.scheduleUpgrade.json SIGNER="--account proposer"
```

The script checks the proposer role, simulates the whole upgrade, sends
`schedule`, and writes a `schedule` block into the `nextImplementation`
record. The block holds `operationId`, `target`, `calldata`, `data`,
`predecessor`, `salt`, `timelock`, `delay`, `proposer`, and `proposedAt`.
The sync adds `readyAt` once the chain confirms the operation. In direct
mode, pass
`SIGNER="--account proxyOwner"` and leave `SAFE` empty.

**A payload.** `DATA=0x...` adds a call that runs inside `upgradeAndCall`
right after the switch. A reinitializer of the new version is the usual
case. The script checks the selector against the new contract's ABI, and it
runs the whole upgrade as the timelock on a state snapshot. A payload that
reverts stops the command before anyone signs.

**The funded-instance trap.** The simulation proves only that the payload
runs. It proves nothing about its effect. A reinitializer that resets
`totalLocked` to zero on a bridge that holds deposits lets `rescueSurplus`
sweep every deposit as surplus. The reviewer of the payload owns this check.
Read the reinitializer line by line, and confirm that it writes no field
that already holds a live value. Prefer an upgrade with no payload; a new
setting can follow through a management script.

**Schedule again.** The script refuses a second schedule while the chain
holds the operation, or while the record holds a confirmed block. A block
without `readyAt` is an intent that never landed, and the next schedule
replaces it. Reject a Safe proposal that never executed before you schedule
again with another payload. Two live proposals would name two different
operations.

### 12.5 Wait

```bash
make upgrade-status
```

The command prints the deployment, the proxy, the live implementation, the
timelock and its minimum delay, the next implementation, the operation id,
and the state. It also prints whether the proxy already points at the next
implementation. Anyone can watch the operation on the timelock address
during the delay.

| State | Meaning |
| --- | --- |
| `not scheduled` | No schedule exists yet. |
| `scheduled in the record, not yet on chain` | The record holds an intent the chain has not confirmed. |
| `waiting; ready at <ISO> (<n>s left)` | The chain confirmed the operation; the delay has not passed. |
| `ready to execute` | The delay has passed. |
| `done` | The operation already executed. |

### 12.6 Execute

```bash
SAFE=0xProxyOwnerSafe make upgrade-execute
make propose ENVELOPE=deployments/.safe/<name>.<chainId>.executeUpgrade.json SIGNER="--account proposer"
```

The script rebuilds the call from the `schedule` block and asks the
timelock for the live state. `OperationNotReady` names the seconds left.
`OperationNotOnChain` means the schedule never landed. `OperationDone` means
the upgrade already ran.

After the Safe executes, run the sync:

```bash
make upgrade-sync
```

The sync sees the operation as done and the proxy on the new code. It
promotes the records. The old implementation record becomes
`<name>.previousImplementation_<n>.<chainId>.json`. The next-implementation
record becomes the implementation record, with the `schedule` block renamed
to `upgrade`. The proxy record gains the new address, `numDeployments + 1`,
and one `history` entry whose `record` field names the previous file. Commit
the three files the sync prints. In direct mode the target syncs by itself.

### 12.7 Cancel

```bash
SAFE=0xProxyOwnerSafe make upgrade-cancel
make propose ENVELOPE=deployments/.safe/<name>.<chainId>.cancelUpgrade.json SIGNER="--account proposer"
```

The canceller role cancels a pending operation. The next sync drops the
`schedule` block. The `nextImplementation` record stays, so the same
implementation can be scheduled again with the same operation id. Delete
the file by hand to drop the implementation. Do this only after the cancel
landed. A deleted record hides a live operation from the sync.

### 12.8 What the sync does

`script/upgrade-sync.sh` is the only writer of chain-derived record state.
It reads the timelock and the proxy, and it applies one rule:

| Chain | Record | Action |
| --- | --- | --- |
| waiting or ready | block without `readyAt` | add `readyAt` |
| waiting or ready | no block | write a block for an empty payload; an operation scheduled by hand becomes visible |
| unset | block without `readyAt` | keep it; the schedule has not landed |
| unset | block with `readyAt` | the operation was cancelled; drop the block |
| done, proxy on the new code | any | promote |

The sync refuses two chain states and asks you to investigate. The first: an
operation that is done while the proxy points elsewhere. The second: a
pending operation while the proxy already points at the new code. It also
refuses three damaged records and asks you to repair them by hand: a block
whose operation id differs from the one the records derive, a block without
a `data` field, and a proxy record whose `implementation` differs from the
implementation record. It never overwrites an existing
`previousImplementation_<n>` file. Run one sync at a time per deployment.
The test `test/tooling/upgrade-sync.t.sh` covers each refusal.

## 13. Void a withdraw request

`VoidWithdrawRequest` marks an id as used without a payout. The contract
emits `WithdrawRequestVoided`. A signed `Withdrawal` bundle stays valid until
its deadline. Only a used id stops the bundle at once.

Void first, and cancel second:

1. Void the id on the bridge.
2. Wait for the `WithdrawRequestVoided` event in a **finalized** block.
3. Cancel the matching Canton withdraw request, which credits the user back.

A `Withdraw` event for the id means that the payout happened. Do not cancel
the Canton request in that case. A void after the Canton credit leaves a
period in which an old bundle can still pay the id.

```bash
make manage SCRIPT=VoidWithdrawRequest SIG='run(bytes)' ARGS=0x0011deadbeef22 \
  RPC_URL=https://... SIGNER="--account bridgeAdmin"
```

The void works while the bridge is paused. A pause is the incident response,
and the void is part of the same response. A wrong void locks no funds. The
ETH stays in the bridge, and the Canton cancel credits the user back. The
`WithdrawRequestVoided` event records every void.
