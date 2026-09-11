# Management scripts

This is the operator runbook for the post-deploy admin actions.

## 1. What these scripts are

`script/manage/` holds one script for each admin action. The root `script/`
folder holds the deploy scripts only. Each management file drives one contract
function. The file name matches that function.

`script/manage/<DEPLOYMENT>/` holds the scripts for one deployment. `BETH` is
the first deployment. `script/manage/ManageBase.s.sol` holds the shared code.
`script/manage/BETH/BethManage.s.sol` binds that base to the BETH records.

Every script reads the deployment record in `deployments/`. The record names
the proxy address for the current chain. The record also names its own chain
id. The script stops when the two chain ids disagree.

## 2. The two modes

Every action script runs in one of two modes. The `SAFE` environment variable
picks the mode.

| Mode | How to select it | What the script does |
| --- | --- | --- |
| Direct broadcast | Leave `SAFE` unset. Add `--broadcast`. | It sends the transaction from your wallet. |
| Safe | Set `SAFE=0xYourSafe`. Omit `--broadcast`. | It writes a transaction envelope to `deployments/.safe/`. |

A Safe-mode run sends nothing. The script first simulates the call from the
Safe address. The simulation proves that the Safe holds the role. It also
proves that the arguments are valid. The script then writes the envelope file.

The envelope path is `deployments/.safe/<DEPLOYMENT>.<chainId>.<action>.json`.

Both modes build the calldata with the same `encode` function. A Safe
therefore signs the exact bytes that a direct broadcast sends.

Direct broadcast:

```bash
forge script script/manage/BETH/Pause.s.sol --sig 'run()' \
  --rpc-url $RPC_URL --broadcast --account sentry
```

Safe:

```bash
SAFE=0xYourSafe forge script script/manage/BETH/Pause.s.sol --sig 'run()' \
  --rpc-url $RPC_URL
```

Use a keystore account or a hardware wallet for a direct broadcast. A raw
private key on the command line enters your shell history.

## 3. The action table

Every command follows one template:

```bash
forge script script/manage/BETH/<Script>.s.sol --sig '<sig>' <arguments> \
  --rpc-url $RPC_URL <mode flags>
```

Take `<mode flags>` from section 2. The `Role` column names the sender that
the contract accepts. In Safe mode that sender is the Safe itself.

| Script | Role | `--sig` | Example arguments |
| --- | --- | --- | --- |
| `Status.s.sol` | none (read only) | `run()` | none |
| `Pause.s.sol` | `BRIDGE_ADMIN` or `SENTRY` | `run()` | none |
| `Unpause.s.sol` | `BRIDGE_ADMIN` | `run()` | none |
| `SetThreshold.s.sol` | `BRIDGE_ADMIN` | `run(uint256)` | `3` |
| `SetDepositLimits.s.sol` | `BRIDGE_ADMIN` | `run(uint256,uint256)` | `100000000 900000000` |
| `SetWithdrawLimits.s.sol` | `BRIDGE_ADMIN` | `run(uint256,uint256)` | `1 700000000` |
| `SetWithdrawRateLimit.s.sol` | `BRIDGE_ADMIN` | `run(uint256,uint256)` | `100000000000000000000 86400` |
| `SetWithdrawalHorizon.s.sol` | `BRIDGE_ADMIN` | `run(uint256)` | `172800` |
| `VoidWithdrawRequest.s.sol` | `BRIDGE_ADMIN` | `run(bytes)` | `0x0011deadbeef22` |
| `RescueERC20.s.sol` | `BRIDGE_ADMIN` | `run(address,address,uint256)` | `0xToken 0xTo 100` |
| `RescueETH.s.sol` | `BRIDGE_ADMIN` | `run(address,uint256)` | `0xTo 1000000000000000000` |
| `RescueSurplus.s.sol` | `BRIDGE_ADMIN` | `run(address,uint256)` | `0xTo 1000000000000000000` |
| `GrantRole.s.sol` | `DEFAULT_ADMIN` | `run(string,address)` | `SENTRY 0xYourSentry` |
| `RevokeRole.s.sol` | `DEFAULT_ADMIN` | `run(string,address)` | `SENTRY 0xOldSentry` |
| `RenounceRole.s.sol` | the role holder itself | `run(string,address)` | `SENTRY 0xYourOwnAddress` |
| `BeginDefaultAdminTransfer.s.sol` | `DEFAULT_ADMIN` | `run(address)` | `0xNewAdmin` |
| `AcceptDefaultAdminTransfer.s.sol` | the incoming admin | `run()` | none |
| `CancelDefaultAdminTransfer.s.sol` | `DEFAULT_ADMIN` | `run()` | none |
| `ChangeDefaultAdminDelay.s.sol` | `DEFAULT_ADMIN` | `run(uint256)` | `259200` |
| `RollbackDefaultAdminDelay.s.sol` | `DEFAULT_ADMIN` | `run()` | none |

Four notes on the table:

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
forge script script/manage/BETH/SetThreshold.s.sol --sig 'run(uint256)' 3 \
  --rpc-url $RPC_URL --broadcast --account bridgeAdmin
```

Read the live configuration first. The `make` target needs no wallet:

```bash
make manage-status DEPLOYMENT=BETH RPC_URL=https://...
```

## 4. Ordering rules that the contract enforces

Two changes need a fixed order. The contract enforces that order. No script
can enforce it for you. This section gives the order for each change.

### Grow the attestor set: raise, then grant

Run `SetThreshold` first. Run `GrantRole ATTESTOR` second.

A grant of the `ATTESTOR` role counts the new set. The grant reverts when the
threshold is at or below half of the new attestor count. Growing from 3
attestors to 4 therefore fails at a threshold of 2.

```bash
# 3 attestors, threshold 2. Add a fourth attestor.
forge script script/manage/BETH/SetThreshold.s.sol --sig 'run(uint256)' 3 \
  --rpc-url $RPC_URL --broadcast --account bridgeAdmin
forge script script/manage/BETH/GrantRole.s.sol \
  --sig 'run(string,address)' ATTESTOR 0xNewAttestor \
  --rpc-url $RPC_URL --broadcast --account defaultAdmin
```

### Shrink the attestor set: revoke, then lower

Run `RevokeRole ATTESTOR` first. Run `SetThreshold` second.

The reverse order fails. `SetThreshold` measures the threshold against the
current attestor count. That count is still the old, larger one. A threshold
of 2 against 4 attestors is not above half. The call therefore reverts.

A revoke never reverts on the threshold. The revoke can therefore leave the
attestor count below the threshold. Every withdrawal halts until you lower the
threshold. Lower it in the same session.

```bash
# 4 attestors, threshold 3. Remove one attestor.
forge script script/manage/BETH/RevokeRole.s.sol \
  --sig 'run(string,address)' ATTESTOR 0xOldAttestor \
  --rpc-url $RPC_URL --broadcast --account defaultAdmin
forge script script/manage/BETH/SetThreshold.s.sol --sig 'run(uint256)' 2 \
  --rpc-url $RPC_URL --broadcast --account bridgeAdmin
```

### The threshold bounds

`SetThreshold` accepts a value that obeys three rules:

- The value must be 2 or more. `MIN_THRESHOLD` is 2.
- The value must not exceed the attestor count.
- The value must stay above half of the attestor count.

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
forge script script/manage/BETH/SetWithdrawalHorizon.s.sol \
  --sig 'run(uint256)' 172800 \
  --rpc-url $RPC_URL --broadcast --account bridgeAdmin
```

## 6. The default admin transfer

`DEFAULT_ADMIN_ROLE` moves in two steps, with one delay between them. Five
scripts govern the role. Three drive the transfer. Two drive the delay.

| Step | Script | Sender |
| --- | --- | --- |
| 1 | `BeginDefaultAdminTransfer.s.sol` | the current admin |
| 2 | `AcceptDefaultAdminTransfer.s.sol` | the **incoming** admin |
| any | `CancelDefaultAdminTransfer.s.sol` | the current admin |

The incoming admin sends step 2. The current admin cannot send it. Step 2
reverts before the scheduled delay passes. Read `pendingAdminAt` from
`make manage-status` to see the schedule.

An incoming Safe proposes step 2 with `SAFE` set to that incoming Safe:

```bash
SAFE=0xYourIncomingSafe forge script \
  script/manage/BETH/AcceptDefaultAdminTransfer.s.sol --sig 'run()' \
  --rpc-url $RPC_URL
```

The two delay scripts are `ChangeDefaultAdminDelay.s.sol` and
`RollbackDefaultAdminDelay.s.sol`. The current admin sends both. A new delay
takes effect only after its own wait period passes. An increase waits up to
`defaultAdminDelayIncreaseWait()`. A decrease waits the difference between the
old delay and the new delay.

## 7. The Safe flow, end to end

The flow has three parts. You write the envelope. You propose it. The owners
then confirm it.

**Step 1. Write the envelope.** Set `SAFE` and omit `--broadcast`:

```bash
SAFE=0xYourSafe forge script script/manage/BETH/Pause.s.sol --sig 'run()' \
  --rpc-url $RPC_URL
```

The script prints the envelope path. For chain 11155111 the path is
`deployments/.safe/BETH.11155111.pause.json`.

**Step 2. Propose the envelope.** The proposer signs the Safe transaction
hash. The proposer then posts it:

```bash
make propose ENVELOPE=deployments/.safe/BETH.11155111.pause.json \
  RPC_URL=https://... SIGNER="--account proposer"
```

The `make` target calls `script/manage/safe/propose.sh`. Call the script
directly if you prefer:

```bash
RPC_URL=https://... SIGNER="--account proposer" \
  ./script/manage/safe/propose.sh deployments/.safe/BETH.11155111.pause.json
```

Set `DRY_RUN=1` to print the request. A dry run sends nothing. A dry run also
never reads the signing key.

**Step 3. The owners confirm.** The script prints the queue link on success.
The owners open that link. The owners then confirm the transaction. One owner
executes it.

The proposer needs no ETH. The proposer needs no owner rights. The proposer
must be a registered delegate of the Safe. Section 8 covers that registration.

## 8. Delegate registration stays manual

A Safe **owner** must register the delegate. The proposer cannot register
itself. This repo holds no script for the step, because owners keep their keys
in hardware wallets. A script here would serve almost nobody.

### The mechanism

The delegate signs an EIP-712 message. The message type is
`Delegate{address delegateAddress,uint256 totp}`. The domain is
`{name: "Safe Transaction Service", version: "1.0", chainId: <chainId>}`.
`totp` is the current Unix time divided by 3600. The division drops the
remainder, so the value changes once per hour.

The service records the delegate on the Safe. A proposal from that delegate
arrives with the `proposed_by_delegate` field set. The service never counts a
delegate as a confirmation. A proposer can therefore propose a transaction.
A proposer can never approve one.

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
https://developer.safe.global. Export the key before you propose:

```bash
export SAFE_API_KEY=...
```

`propose.sh` sends the key as a bearer token. The key travels on stdin, so a
local `ps` cannot show it. The variable is optional. One proposal sends one
request to the service, so a single run stays inside the anonymous limit.

## 10. Status of this tooling

`script/manage/safe/propose.sh` has offline tests in
`test/tooling/propose.t.sh`. A fake `curl` answers the service. A fake `cast`
answers the chain. CI runs the suite on every push.

**The script has never run against the live Safe Transaction Service.** Treat
the first live proposal as a test. Use a Safe that holds no funds. Choose an
action you can cancel.

Record the first successful live run here:

| Field | Value |
| --- | --- |
| Date of first live proposal | _not yet run_ |
| Chain | _not yet run_ |
| Safe address | _not yet run_ |
| Operator | _not yet run_ |

## 11. Open question: how many Safes govern a deployment

The team has not decided this. Three shapes are under discussion:

1. **Three Safes.** The deployment uses one Safe for each authority. The three
   authorities are `DEFAULT_ADMIN`, `BRIDGE_ADMIN` and the `ProxyAdmin` owner.
2. **Two Safes.** A slow Safe holds `DEFAULT_ADMIN`. The same slow Safe owns
   the `ProxyAdmin`. A fast Safe holds `BRIDGE_ADMIN`.
3. **One Safe.** One Safe holds all three authorities.

The tooling does not depend on the answer. `SAFE` names the Safe on every
invocation. An operator points each action at the Safe that holds its role.
A later change of shape needs no change to these scripts.
