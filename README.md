# evm-asset-bridge

BitSafeEvmAssetBridge: an upgradeable EVM contract that locks one asset
(ETH or one ERC20) and releases it on attestor-signed withdrawal. BETH
(bridged ETH on Canton) is the first deployment.

- Build: `forge build`
- Test: `forge test`
- Integration-test image: `make it-verify` (see `infra/docker/README.md`)
- Upgrade through the timelock: `make upgrade-deploy`, `upgrade-schedule`, `upgrade-status`, `upgrade-execute`, `upgrade-cancel`, `upgrade-sync` (see [Upgrade through the timelock](script/manage/README.md#12-upgrade-through-the-timelock))

## Production deploy

`script/Deploy_BETH.s.sol` deploys the implementation behind a
`TransparentUpgradeableProxy`. It also deploys an OpenZeppelin
`TimelockController` that owns the `ProxyAdmin`. An upgrade therefore waits
`TIMELOCK_DELAY` seconds in public before it can execute. The part of the file
name after the underscore is the deployment name. A second bridged asset gets
its own `Deploy_<NAME>.s.sol`.

```
make deploy DEPLOYMENT=BETH RPC_URL=<url> SIGNER="--account deployer --sender 0xYourDeployer"
```

BETH has three deployment names. Sepolia hosts two instances, and each one
serves the attestors of one Canton network. The name keeps their records
apart. `Deploy_BETH_DEVNET.s.sol` and `Deploy_BETH_TESTNET.s.sol` subclass
`Deploy_BETH` and change the name only. Every name reads the same
environment variables, and `.env.sepolia.<NAME>` holds the Sepolia values.

| Name | Purpose | Network |
| --- | --- | --- |
| `BETH` | The production bridge | Ethereum mainnet |
| `BETH_DEVNET` | The instance whose attestors run against Canton devnet | Sepolia |
| `BETH_TESTNET` | The instance whose attestors run against Canton testnet | Sepolia |

That runs two steps. `forge script` broadcasts the deploy. `script/record.sh`
then writes the deployment records. The `make record` target repeats the
second step on its own:

```
make record DEPLOYMENT=BETH
```

`make record` reads the pending file that the deploy wrote. It needs
`CHAIN_ID=<id>` when more than one pending file waits. It names every match
when it stops. A local `forge test` run leaves one behind for chain 31337.

The deploy reads its configuration from the environment:

| Env var | Meaning |
| --- | --- |
| `ASSET` | Bridged asset address; `address(0)` for ETH, else the ERC20 address |
| `TARGET_DECIMALS` | Decimal places the target chain expresses; `10` for Canton, 1 to 10 |
| `DEFAULT_ADMIN` | Address granted the default admin role (governs role management and the signature threshold); in the mainnet deploy inputs, the multi-organisation Safe, which also drives the upgrade timelock |
| `ADMIN_DELAY` | Default-admin transfer delay, in seconds |
| `BRIDGE_ADMIN` | Address granted `BRIDGE_ADMIN_ROLE` (pause, limits, rescue) |
| `PROXY_OWNER` | Proposer, canceller, and executor of the timelock that owns the `ProxyAdmin`; in the mainnet deploy inputs, the multi-organisation Safe, same as `DEFAULT_ADMIN` |
| `TIMELOCK_DELAY` | Upgrade timelock delay, in seconds; an upgrade waits this long after its proposal |
| `ATTESTORS` | Comma-separated attestor addresses granted `ATTESTOR_ROLE` |
| `THRESHOLD` | Number of attestor signatures required per withdrawal |
| `DEPOSIT_MIN` | Minimum deposit amount (0 = no minimum) |
| `DEPOSIT_MAX` | Maximum deposit amount (`type(uint256).max` = no maximum) |
| `WITHDRAW_MIN` | Minimum withdrawal amount (0 = no minimum) |
| `WITHDRAW_MAX` | Maximum withdrawal amount (`type(uint256).max` = no maximum) |

### Signing the deploy

`SIGNER` carries the signer flags straight to `forge script`. Foundry reads no
private key from the environment, so a broadcast needs one of its wallet flags.
`make deploy` stops when `SIGNER` is unset.

```
cast wallet import deployer --interactive        # once, into the keystore
make deploy DEPLOYMENT=BETH RPC_URL=https://... \
  SIGNER="--account deployer --sender 0xYourDeployer"
```

A hardware wallet works the same way:

```
make deploy DEPLOYMENT=BETH RPC_URL=https://... \
  SIGNER="--ledger --sender 0xYourDeployer"
```

Prefer a keystore account or a hardware wallet. A raw private key on the
command line reaches your shell history. Make expands the variable into the
child process's argument list, where `ps` finds it. Make also exports the
variable into the child process's environment.

### Commit the records

The deploy writes files that only your machine holds. Commit them after the
deploy. The verify command needs them to verify the source:

```
git add deployments/BETH.*.<chainId>.json deployments/solcInputs/
git commit -m "chore(deployments): record BETH on chain <chainId>"
```

Commit both parts. The record files name a compiler input by hash, and
`deployments/solcInputs/` holds that input. `script/verify.sh` reads the
committed files. `broadcast/` and `out/` never leave your machine.

A local test run writes into the same folder. Its compiler input matches the
deployed one whenever the source matches, so an extra file is harmless.

### Post-deploy: the withdrawal rate limit

The bridge admin sets the withdrawal rate limit with
`setWithdrawRateLimit(capacity, window)`. Withdrawals draw from a token
bucket that holds at most `capacity` base units. The bucket refills at
`capacity / window` per second, so an empty bucket is full again after
`window` seconds. A `capacity` of `0` disables the check. `initialize` does
not set the rate limit.

### Post-deploy: the withdrawal horizon

The horizon bounds how far a withdrawal `deadline` can lie past
`block.timestamp`. The bound is inclusive. A horizon of `0` disables the
bound. The bridge admin sets the horizon with `setWithdrawalHorizon(horizon)`.
`initialize` does not set the horizon.

A new horizon invalidates every unsubmitted bundle whose deadline lies past
the new bound. The signers must then re-sign those requests.
[The withdrawal horizon rule](script/manage/README.md#5-the-withdrawal-horizon-rule)
gives the procedure.

### Post-deploy: the sentry pause role

The default admin can grant `SENTRY_ROLE` to monitoring-bot keys with
`grantRole(SENTRY_ROLE, <bot>)`. A sentry can only call `pause()`. Only the
bridge admin can unpause the bridge.

### Post-deploy: the admin runbook

Post-deploy admin actions live in `script/manage/`. See
[script/manage/README.md](script/manage/README.md) for the action list, the
Safe flow, and the ordering rules.

## Deployment records

One deploy creates four contracts. It therefore writes four records:

```
deployments/
  BETH.proxy.<chainId>.json                     <- the address every consumer calls
  BETH.implementation.<chainId>.json            <- the bridge ABI
  BETH.proxyAdmin.<chainId>.json                <- the contract that can upgrade the proxy
  BETH.timelock.<chainId>.json                  <- the contract that owns the ProxyAdmin
  BETH.nextImplementation.<chainId>.json        <- an implementation that waits for its upgrade
  BETH.previousImplementation_<n>.<chainId>.json <- an implementation the proxy left behind
  solcInputs/<hash>.json                        <- the exact compiler input
```

The middle part of the name is the role, not the contract name. An upgrade that
keeps the contract name still updates the same file.

Every record holds the address, the ABI-encoded constructor arguments, the
transaction receipt, the contract ABI, the compiler settings, and the git
commit. The proxy record holds five more fields: `implementation`, `proxyAdmin`,
`deployTimeConfig`, `numDeployments`, and `history`.

The ProxyAdmin record holds `createdBy`, which names the proxy. It also holds
`deployTimeConfig`, which has `owner`. At deploy time `owner` names the
timelock.
A deployment without a timelock record, such as BETH_DEVNET, sets `owner` to the
proxy owner.

The timelock record holds `deployTimeConfig`, which has `minDelay`,
`proposers`, `executors`, and `admin`. At deploy time the admin is the zero
address, so the timelock administers itself.

Every record also opens with `schemaVersion`, which is `2` today. A consumer
outside this repo reads it to detect a migration.

In the proxy record, `deployTimeConfig` holds the whole `initialize`
configuration, not just the decimals fields:

```
asset, assetDecimals, targetDecimals, depositUnit, defaultAdmin, adminDelay,
bridgeAdmin, proxyOwner, timelock, timelockDelay, attestors, threshold,
depositLimits, withdrawLimits
```

The deployment records track the deployment itself. That is the address and
the deploy facts of each contract that the tooling deploys, and the progress
of an upgrade through the timelock. The records never track business
configuration after the deploy. The roles, the attestors, the threshold, the
limits and the delays stay at their deploy-time values in
`deployTimeConfig`. The chain holds the live values.
When a record and the chain disagree, the chain is correct.

The record holds `targetDecimals` and `depositUnit` as deploy-time values.
`make manage-status` prints the live ones.

`make manage-status` prints the default admin, the attestors, the threshold,
the limits, and the delays. No status command prints the holders of
`BRIDGE_ADMIN_ROLE` or `SENTRY_ROLE`. No status command prints the ProxyAdmin
owner or the timelock proposers and executors. Check them with `cast call`:

```bash
cast call <timelock> "hasRole(bytes32,address)(bool)" $(cast keccak PROPOSER_ROLE) <account> --rpc-url $RPC_URL
cast call <proxyAdmin> "owner()(address)" --rpc-url $RPC_URL
```

Call `hasRole` on the bridge in the same way for `BRIDGE_ADMIN_ROLE` and
`SENTRY_ROLE`. `hasRole` checks one account that you name. To list every holder
of a role, read the `RoleGranted` and `RoleRevoked` events of the contract.

`make upgrade-status` syncs the upgrade records with the chain. It then prints
the upgrade state.

Each record holds the ABI of the contract at its own address. A consumer
therefore reads the address from `BETH.proxy.<chainId>.json`. It reads the
bridge ABI from `BETH.implementation.<chainId>.json`.

`history[]` lists every past implementation. Each entry names the address, the
contract name, the compiler input hash, the git commit, the transaction hash,
and the time. The six fields describe the old implementation, never the proxy,
so they are enough to verify that implementation later.

An upgrade through the timelock adds `BETH.nextImplementation.<chainId>.json`
before the switch and `BETH.previousImplementation_<n>.<chainId>.json` after
it. The new `history` entry names the previous file in its `record` field.
[Upgrade through the timelock](script/manage/README.md#12-upgrade-through-the-timelock)
holds the operator sequence and the record blocks that an upgrade writes.

`deployments/solcInputs/<hash>.json` is the standard-JSON compiler input that
produced the deployed bytes. The verify command submits that file. The
explorer then reaches an exact match with no local build.

## Verifying the source on an explorer

```
export ETHERSCAN_API_KEY_11155111=<key>
make verify DEPLOYMENT=BETH_DEVNET CHAIN_ID=11155111
```

The command reads every record for that deployment and chain, and it submits
the stored compiler input. The
explorer compiles the exact input that produced the deployed bytes, so it
reaches an exact match. The command needs no local build and no matching
checkout.

It asks the explorer first and skips a contract that already has verified
source, so you can run it as often as you like. It never runs during a deploy,
so a slow explorer cannot fail one.

| Env var | Required | Meaning |
| --- | --- | --- |
| `DEPLOYMENT` | yes | The deployment name, such as `BETH` |
| `CHAIN_ID` | yes | Picks the record files |
| `ETHERSCAN_API_KEY_<CHAIN_ID>` | one of the two | The key for that chain's explorer |
| `ETHERSCAN_API_KEY` | one of the two | The fallback key |
| `VERIFIER_URL_<CHAIN_ID>` | no | That chain's explorer host |
| `VERIFIER_URL` | no | The fallback host. Defaults to Etherscan V2 |
| `CONTRACT` | no | One recorded role only, such as `proxy` |
| `DRY_RUN` | no | Set to `1` to print the request and send nothing |

The command finds the roles by reading the file names in `deployments/`. The
role is a free label that the deploy script chooses, so a standalone contract
with one role works without a code change. `CONTRACT` accepts any role the
command found, and it lists them when it rejects one.

The script reads the per-chain key first, then the fallback. It prints which
variable supplied the key, and it never prints the value.

Etherscan's V2 endpoint accepts one key on every chain Etherscan itself
operates. A chain whose explorer is Blockscout or Routescan needs its own host
in `VERIFIER_URL_<CHAIN_ID>` and its own key.

The command does not run in CI. It runs on an operator's machine.

### Link the proxy on Etherscan

The command verifies the source of all four contracts. It does not send
Etherscan's separate proxy-link call, so the proxy page can miss the
"Read as Proxy" and "Write as Proxy" tabs. When the tabs are missing, open
the proxy address on Etherscan and use "More Options" > "Is this a proxy?".
Confirm the detected implementation. Repeat the step after an upgrade.

## Deposit granularity

Canton expresses 10 decimal places. ETH has 18. A deposit of 1 wei therefore has
no Canton representation, and the bridge would lock ETH that it can never mint.
The contract blocks this at the source.

`initialize` takes `targetDecimals` and reads the asset's own decimals. For ETH
it uses 18, because ETH has no contract to ask. For an ERC20 it calls
`decimals()`. That function is optional in EIP-20, so a token without it cannot
be bridged; `initialize` reverts.

From the two values the contract derives the deposit unit:

```
depositUnit = 10 ** (assetDecimals - targetDecimals)
```

Every deposit amount must be a whole multiple of that unit. A deposit that is
not reverts with `AmountNotRepresentable(amount, depositUnit)`. For ETH and
Canton the unit is `1e8` wei. A frontend reads `depositUnit()` and rounds the
amount down before it sends the transaction.

Four rules follow from the formula:

- The unit is `1` when `targetDecimals` is at or above `assetDecimals`. Every
  amount is then representable, and the check accepts everything.
- `initialize` reverts with `DecimalsOutOfRange` when `assetDecimals` sits
  outside 1 to 18. The value 18 is the idiomatic maximum precision for an ERC20,
  so a larger value is a misconfiguration.
- `initialize` reverts when `targetDecimals` sits outside 1 to 10. Canton's
  CIP-56 token standard sets 10 as the maximum precision, and this bridge
  targets Canton. A wider bound would admit a typo such as `100` for `10`, which
  clamps the unit to 1 and turns the check off without an error. A deployment
  for another chain needs a new bound in the contract.
- `setDepositLimits` rejects a band that holds no multiple of the unit. Such a
  band would block every deposit and warn nobody.

The withdraw path carries no granularity check. Canton cannot burn an amount it
cannot express, so the release amount is always representable by construction.

## Attestor signing

Attestors authorize a withdrawal by signing an EIP-712 typed-data digest.
The contract verifies the digest with `_hashTypedDataV4`. Any EIP-712
library produces the identical digest from the struct and domain below.

The signed struct and its type string (field names are part of the digest —
they must match byte for byte):

```
Withdrawal(bytes withdrawRequestId,address destinationAddress,uint256 amount,uint256 deadline)
```

The domain has four fields. `verifyingContract` is the bridge proxy address
of the target deployment, never the implementation address:

| Domain field | Value |
| --- | --- |
| `name` | `BitSafeEvmAssetBridge` |
| `version` | `1` |
| `chainId` | The target chain id (read live by the contract) |
| `verifyingContract` | The bridge proxy address |

The signature is 65 bytes: `r (32) || s (32) || v (1)`, with `v` in
`{27, 28}` and `s` in low-s form.

Rules the contract enforces on submission (`withdraw`):

- Signatures may arrive in any order; no sorting by signer address.
- Each signer may appear once; a duplicate reverts.
- Every submitted signature must recover to a current `ATTESTOR_ROLE` holder.
- At least `threshold` signatures are required; the caller must hold
  `ATTESTOR_ROLE`.
- Each `withdrawRequestId` executes once, forever.
- A bundle expires after its `deadline` (a Unix timestamp, inclusive): the
  contract rejects it when `block.timestamp > deadline`.
- A `deadline` further than the admin-set `withdrawalHorizon()` past
  `block.timestamp` is rejected. The bound is inclusive:
  `deadline == block.timestamp + horizon` passes. A horizon of `0` disables
  the bound.

The signers choose the `deadline`. A lower horizon can reject a bundle that
the signers signed under the old horizon. The signers then sign the request
again.

A signer checks its encoding against the live contract. The view
`withdrawalDigest(withdrawRequestId, destinationAddress, amount, deadline)`
returns the exact digest that the contract verifies. The locally computed
digest must equal it. Sign the digest bytes directly. Do not use
`personal_sign` or the Ethereum Signed Message prefix, because the digest
already holds the EIP-712 `\x19\x01` prefix.

## Voiding a withdraw request

`voidWithdrawRequest(bytes withdrawRequestId)` (`BRIDGE_ADMIN_ROLE`) marks an
id as used without a payout. It emits `WithdrawRequestVoided`. It reverts with
`EmptyId` or `WithdrawRequestAlreadyUsed` exactly as `withdraw` does. A paid
id therefore cannot be voided, and a voided id cannot be paid. The function
works while the bridge is paused.
[Void a withdraw request](script/manage/README.md#13-void-a-withdraw-request)
gives the order of the void and the Canton cancel.

## Deposit events

Both `depositETH` and `depositERC20` emit the same event:

```solidity
event Deposit(bytes32 indexed depositAccountIdHash, bytes depositAccountId, address indexed sender, uint256 amount);
```

- `topic0` (the event signature hash) is
  `0xacaea730ea841fae3326f72a7ff746b6e06c646840526bcaf5dabee5fd887ef8`,
  which is `keccak256("Deposit(bytes32,bytes,address,uint256)")`.
- `depositAccountIdHash` (`topic1`) is `keccak256(depositAccountId)`. Filter
  on it to follow one Canton deposit account.
- `sender` (`topic2`) is the EVM account that paid the deposit.
- The data part carries the raw `depositAccountId` bytes (the Canton deposit
  account id) and `amount` (wei for ETH, base units for an ERC20 asset).

The bridge emits the event from the proxy address, never from the
implementation address.

A consumer filters on the proxy address and `topic0`, and advances its
start block past the last block it saw.
