# evm-asset-bridge

BitSafeEvmAssetBridge: an upgradeable EVM contract that locks one asset
(ETH or one ERC20) and releases it on attestor-signed withdrawal. BETH
(bridged ETH on Canton) is the first deployment.

- Build: `forge build`
- Test: `forge test`
- Integration-test image: `make it-verify` (see `infra/docker/README.md`)
- The design spec is maintained locally, outside git (not tracked in this repo).

## Production deploy

`script/Deploy_BETH.s.sol` deploys the implementation behind a
`TransparentUpgradeableProxy`. The part of the file name after the underscore is
the deployment name. A second bridged asset gets its own `Deploy_<NAME>.s.sol`.

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
| `DEFAULT_ADMIN` | Address granted the default admin role (governs role management and the signature threshold) |
| `ADMIN_DELAY` | Default-admin transfer delay, in seconds |
| `BRIDGE_ADMIN` | Address granted `BRIDGE_ADMIN_ROLE` (pause, limits, rescue) |
| `PROXY_OWNER` | Owner of the `ProxyAdmin` created for the transparent proxy |
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

The deploy writes files that only your machine holds. Commit them right after
the deploy, or the source can never be verified again:

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

After deploy, the bridge admin sets the withdrawal rate limit with
`setWithdrawRateLimit(capacity, window)`. Withdrawals draw from a token
bucket that holds at most `capacity` base units and refills at
`capacity / window` per second, so a drained bucket is full again after
`window` seconds. A `capacity` of `0` disables the check, and the contract
deploys with `0`, so this step is what turns the limit on. `initialize`
cannot take the limit as a parameter because it already sits at the EVM
stack limit.

### Post-deploy: the withdrawal horizon

The horizon bounds how far a withdrawal `deadline` can sit past
`block.timestamp` (inclusive). The contract deploys with `0`, which disables
the bound. The attestors derive their signing mode from the
`withdrawalHorizon()` view. While the view returns `0`, they sign the fixed
sentinel deadline. When the view returns a non-zero value, they derive real
deadlines. Activation is therefore one admin transaction:
`setWithdrawalHorizon(horizon)`. That transaction invalidates every
unsubmitted sentinel bundle, and the attestors re-sign those requests in
derived mode. The suggested first value is 48 hours; tighten it later with
one admin transaction. `initialize` cannot take the horizon as a parameter
because it already sits at the EVM stack limit.

### Post-deploy: the sentry pause role

After deploy, the default admin MAY grant `SENTRY_ROLE` to one or more
monitoring-bot keys with `grantRole(SENTRY_ROLE, <bot>)`. A sentry can only
call `pause()`; only the bridge admin unpauses. A hot key is acceptable for
this role: it grants only a denial power, and the admin can always reverse it.

No sentry holder exists at launch. Until a monitoring bot exists, the runbook
keeps a pre-signed `pause()` Safe transaction to cover the gap.

### Post-deploy: the admin runbook

Post-deploy admin actions live in `script/manage/`. See
[script/manage/README.md](script/manage/README.md) for the action list, the
Safe flow, and the ordering rules.

## Deployment records

One deploy creates three contracts. It therefore writes three records:

```
deployments/
  BETH.proxy.<chainId>.json           <- the address every consumer calls
  BETH.implementation.<chainId>.json  <- the bridge ABI
  BETH.proxyAdmin.<chainId>.json      <- the contract that can upgrade the proxy
  solcInputs/<hash>.json              <- the exact compiler input
```

The middle part of the name is the role, not the contract name. An upgrade that
keeps the contract name still updates the same file.

Every record holds the address, the ABI-encoded constructor arguments, the
transaction receipt, the contract ABI, the compiler settings, and the git
commit. It holds nothing that names the machine that ran the deploy. The proxy
record holds five more fields: `implementation`,
`proxyAdmin`, `bridgeConfig`, `numDeployments`, and `history`.

Every record also opens with `schemaVersion`, which is `1` today. A consumer
outside this repo reads it to detect a migration.

`bridgeConfig` holds the whole `initialize` configuration, not just the
decimals fields:

```
asset, assetDecimals, targetDecimals, depositUnit, defaultAdmin, adminDelay,
bridgeAdmin, proxyOwner, attestors, threshold, depositLimits, withdrawLimits
```

The record holds the deploy-time configuration only. The post-deploy setters
change live state that no record shows: `setWithdrawRateLimit`,
`setWithdrawalHorizon`, and the `SENTRY_ROLE` grants. Read that state from
the contract itself.

An operator reads the live granularity rule from `targetDecimals` and
`depositUnit`, both inside `bridgeConfig`.

Each record holds the ABI of the contract at its own address. A consumer
therefore reads the address from `BETH.proxy.<chainId>.json`. It reads the
bridge ABI from `BETH.implementation.<chainId>.json`.

`history[]` lists every past implementation. Each entry names the address, the
contract name, the compiler input hash, the git commit, the transaction hash,
and the time. The six fields describe the old implementation, never the proxy,
so they are enough to verify that implementation later.

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

The command verifies the source of all three contracts. It does not send
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
`decimals()`. That function is OPTIONAL in EIP-20, so a token without it cannot
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

## Attestor signing (Rust)

Attestors authorize a withdrawal by signing an EIP-712 typed-data digest.
The contract verifies the digest with `_hashTypedDataV4`; the Rust attestor
stack produces the identical digest with [Alloy](https://docs.rs/alloy-sol-types).

The signed struct and its type string (field names are part of the digest —
they must match byte for byte):

```
Withdrawal(bytes withdrawRequestId,address destinationAddress,uint256 amount,uint256 deadline)
```

The domain has four fields. `verifyingContract` is the bridge PROXY address
of the target deployment, never the implementation address:

| Domain field | Value |
| --- | --- |
| `name` | `BitSafeEvmAssetBridge` |
| `version` | `1` |
| `chainId` | The target chain id (read live by the contract) |
| `verifyingContract` | The bridge proxy address |

Complete Rust flow:

```rust
use alloy_primitives::{Address, Bytes, B256, U256};
use alloy_signer::SignerSync;
use alloy_signer_local::PrivateKeySigner;
use alloy_sol_types::{eip712_domain, sol, SolStruct};

sol! {
    struct Withdrawal {
        bytes withdrawRequestId;
        address destinationAddress;
        uint256 amount;
        uint256 deadline;
    }
}

fn sign_withdrawal(
    signer: &PrivateKeySigner,
    bridge_proxy: Address,
    chain_id: u64,
    cid_bytes: Vec<u8>,        // the raw Canton WithdrawRequest cid bytes
    destination: Address,
    amount_wei: U256,
    deadline: U256,            // Unix seconds; see the derivation rule below
) -> eyre::Result<Vec<u8>> {
    let domain = eip712_domain! {
        name: "BitSafeEvmAssetBridge",
        version: "1",
        chain_id: chain_id,
        verifying_contract: bridge_proxy,
    };

    let message = Withdrawal {
        withdrawRequestId: Bytes::from(cid_bytes),
        destinationAddress: destination,
        amount: amount_wei,
        deadline,
    };

    let digest: B256 = message.eip712_signing_hash(&domain);
    let signature = signer.sign_hash_sync(&digest)?;

    // 65 bytes: r (32) || s (32) || v (1), v in {27, 28}, low-s form.
    Ok(signature.as_bytes().to_vec())
}
```

Rules the contract enforces on submission (`withdraw`):

- Signatures may arrive in ANY order; no sorting by signer address.
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

The deadline runs in one of two modes, and the contract's
`withdrawalHorizon()` view selects the mode. While the view returns `0`,
every attestor signs the same fixed sentinel deadline, a far-future constant
in the shared release, and the bound stays off. When the view returns a
non-zero value, every attestor derives the deadline alone, with the same
rule: `deadline = ledgerTimeOf(WithdrawRequest create) + withdrawalHorizon`.
Every input is a ledger record or the on-chain view: no local clocks, no
slack constant, no per-node horizon config. All attestors compute the same
value, so the signatures combine with no coordinator-proposed field.
Activation is one admin transaction (see the deploy notes); start long — 48
hours is suggested — and tighten later with one admin transaction.

A horizon change can land between two attestors' reads. The attestors then
derive different deadlines, sign different digests, and the signatures do not
combine. An attestor that sees a deadline mismatch defers the request to the
next signing tick, re-reads the horizon, and re-signs. The request ids stay
unused, so no funds are at risk. The same deferral covers activation day:
every unsubmitted sentinel bundle fails the new bound, and the attestors
re-sign those requests in derived mode.

A pause longer than the horizon expires every pending bundle. A re-sign alone
does not recover them: the derivation rule is deterministic, so it computes
the same expired deadline. The bridge admin raises the horizon above the age
of the oldest pending request; the attestors re-derive and re-sign; the admin
lowers the horizon after the backlog clears. The request ids stay unused, so
no funds are at risk.

## Voiding a withdraw request

`voidWithdrawRequest(bytes withdrawRequestId)` (`BRIDGE_ADMIN_ROLE`) marks an
id used without paying it and emits `WithdrawRequestVoided`. A signed
`Withdrawal` bundle stays valid until its deadline, so only a used id stops
it at once.
The order matters: void first, cancel second. When an operator proposes a
cancel for the matching Canton withdraw request, the admin voids the id
before the attestors confirm the cancel. Each attestor confirms only after
it sees the `WithdrawRequestVoided` event for the id in a **finalized**
block on its own RPC node. That check is positive evidence with one
finality anchor: a reorg or an incomplete log scan cannot fake it. A
`Withdraw` event for the id means the payout happened, so the attestor
rejects the cancel. The confirmed cancel then credits the user back on
Canton. A void after the credit leaves a window where an old bundle still
pays the id. The function reverts with `EmptyId` or
`WithdrawRequestAlreadyUsed` exactly as `withdraw` does, so a paid id
cannot be voided and a voided id cannot be paid. It works while the bridge
is paused, since a pause is the incident response and the void is part of
resolving it. A wrongful void locks no funds: the ETH stays in the bridge,
the Canton cancel credits the user back, and the `WithdrawRequestVoided`
event makes every void auditable.

Before rollout, cross-check the encoding against the live contract: the view
`withdrawalDigest(withdrawRequestId, destinationAddress, amount, deadline)`
returns the exact digest the contract verifies. Assert your locally computed
digest equals it. Note for raw-key or KMS setups: sign the digest bytes
directly (no `personal_sign` / Ethereum Signed Message prefix — the EIP-712
`\x19\x01` envelope is already inside the digest).

## Watching Deposit events (Rust)

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

Emit address: always the bridge PROXY address, never the implementation.

Complete Rust flow with [Alloy](https://docs.rs/alloy):

```rust
use alloy_primitives::address;
use alloy_provider::{Provider, ProviderBuilder};
use alloy_rpc_types::Filter;
use alloy_sol_types::{sol, SolEvent};

sol! {
    event Deposit(bytes32 indexed depositAccountIdHash, bytes depositAccountId, address indexed sender, uint256 amount);
}

#[tokio::main]
async fn main() -> eyre::Result<()> {
    // Values for the local evm-asset-bridge container (see infra/docker/README.md).
    // For another deployment, use its RPC URL and its proxy address.
    let provider = ProviderBuilder::new().connect("http://localhost:8545").await?;
    let bridge_proxy = address!("0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512");

    let filter = Filter::new()
        .address(bridge_proxy)
        .event_signature(Deposit::SIGNATURE_HASH)
        .from_block(0u64);

    for log in provider.get_logs(&filter).await? {
        let deposit = log.log_decode::<Deposit>()?.inner.data;
        println!(
            "deposit: account_id={} sender={} amount={}",
            deposit.depositAccountId, // Bytes prints as 0x-prefixed hex
            deposit.sender,
            deposit.amount,
        );
    }
    Ok(())
}
```

A poller advances `from_block` past the last block it saw. A pubsub setup
subscribes with `subscribe_logs` over WebSocket instead of `get_logs`.
