# Management scripts

This is the operator runbook for the post-deploy admin actions.

## 1. What these scripts are

`script/manage/` holds one script for each admin action. The root `script/`
folder holds the deploy scripts only. Each management file drives one contract
function. The file name matches that function.

A folder names a contract, and `DEPLOYMENT` names one instance of that
contract. The scripts for `BitSafeEvmAssetBridge` live in
`script/manage/BitSafeEvmAssetBridge/`. `DEPLOYMENT=BETH` picks the BETH
bridge, and the deployment records pin its addresses.

**Warning.** The guard checks the contract name only. It cannot tell two
deployments of the same contract apart. A wrong `DEPLOYMENT` value that
names another real `BitSafeEvmAssetBridge` deployment still passes every
check. Run `make manage-status DEPLOYMENT=<name> RPC_URL=<url>` first, and
confirm the printed bridge address. Fix `DEPLOYMENT` before you send a real
transaction.

A second deployment of the same contract needs no new script. It needs one
set of deployment records and one `.env.{network}.{deployment}` file. This
promise covers the management scripts only. The deploy script still needs
one new file for each deployment, and issue #42 tracks that gap.

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
set -a; source .env.sepolia.BETH; set +a
```

Pass `DEPLOYMENT=BETH` on a `make` line instead, when you do not load the
file. The management targets set no default, and they stop without it.

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
| `SetThreshold` | `BRIDGE_ADMIN` | `make manage SCRIPT=SetThreshold SIG='run(uint256)' ARGS=3` |
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

This example raises the signature threshold to 3:

```bash
make manage SCRIPT=SetThreshold SIG='run(uint256)' ARGS=3 \
  RPC_URL=https://... SIGNER="--account bridgeAdmin"
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
  RPC_URL=https://... SIGNER="--account bridgeAdmin"
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
  RPC_URL=https://... SIGNER="--account bridgeAdmin"
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

The attestors read `withdrawalHorizon()` to pick their signing mode. A zero
value means the fixed sentinel deadline. A non-zero value means derived
deadlines. One `SetWithdrawalHorizon` transaction therefore activates the
bound.

A change between two attestor reads splits their digests. The attestors defer
the request to the next signing tick. They then re-sign the request in the new
mode. Expect a short delay in withdrawals after this change. Start with a long
horizon, such as 48 hours.

```bash
make manage SCRIPT=SetWithdrawalHorizon SIG='run(uint256)' ARGS=172800 \
  RPC_URL=https://... SIGNER="--account bridgeAdmin"
```

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
never reads the signing key. A dry run still reads the queue of the service. A
dry run keeps the envelope file. Both forms accept the variable:

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

Keep the key out of every tracked file. `.env.sepolia.BETH` holds no secret.

## 10. Status of this tooling

`script/manage/safe/propose.sh` has offline tests in
`test/tooling/propose.t.sh`. A fake `curl` answers the service. A fake `cast`
answers the chain. CI runs the suite on every push.

The whole flow also ran against the live Safe Transaction Service. This repo
becomes public. The record therefore names no address and no transaction hash.

| Field | Value |
| --- | --- |
| Date | 2026-09-11 |
| Network | Sepolia |
| Action | `setWithdrawRateLimit` |
| Result | The Safe executed the transaction. |
| Proposer record | The service set the `proposedByDelegate` field. |
| Confirmations | The list held the Safe owner only. |
| Hash agreement | The stored `safeTxHash` matched the computed hash. |

The run proves three points. A delegate proposes a transaction. A delegate
never confirms a transaction. The hash that the script computes before the
signature matches the hash that the service stores.

One item stays unproven. The script maps each chain to a Safe short name. Only
the Sepolia short name `sep` ran live. Treat the first run on another chain as
a test.

## 11. Open question: how many Safes govern a deployment

The team has not decided this. The team discusses three shapes:

1. **Three Safes.** The deployment uses one Safe for each authority. The three
   authorities are `DEFAULT_ADMIN`, `BRIDGE_ADMIN` and the `ProxyAdmin` owner.
2. **Two Safes.** A slow Safe holds `DEFAULT_ADMIN`. The same slow Safe owns
   the `ProxyAdmin`. A fast Safe holds `BRIDGE_ADMIN`.
3. **One Safe.** One Safe holds all three authorities.

The tooling does not depend on the answer. `SAFE` names the Safe on every
invocation. An operator points each action at the Safe that holds its role.
A later change of shape needs no change to these scripts.
