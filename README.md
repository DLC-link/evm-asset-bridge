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
| `DEFAULT_ADMIN` | Address granted the default admin role (governs role management) |
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

### Verify, then commit the records

Verify the source before you commit the records. `make verify` stops when
`HEAD` is not the deployed commit, and the record commit moves `HEAD`.

Then commit the records. The deploy writes files that only your machine holds:

```
git add deployments/BETH.*.<chainId>.json
git commit -m "chore(deployments): record BETH on chain <chainId>"
```

`script/verify.sh` reads the records. `broadcast/` and `out/` never leave your
machine, so a record is the only lasting copy.

## Deployment records

One deploy creates three contracts. It therefore writes three records:

```
deployments/
  BETH.proxy.<chainId>.json           <- the address every consumer calls
  BETH.implementation.<chainId>.json  <- the bridge ABI
  BETH.proxyAdmin.<chainId>.json      <- the contract that can upgrade the proxy
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

`bridgeConfig` holds the whole deploy configuration, not just the decimals
fields:

```
asset, assetDecimals, targetDecimals, depositUnit, defaultAdmin, adminDelay,
bridgeAdmin, proxyOwner, attestors, threshold, depositLimits, withdrawLimits
```

An operator reads the live granularity rule from `targetDecimals` and
`depositUnit`, both inside `bridgeConfig`.

Each record holds the ABI of the contract at its own address. A consumer
therefore reads the address from `BETH.proxy.<chainId>.json`. It reads the
bridge ABI from `BETH.implementation.<chainId>.json`.

`history[]` lists every past implementation. Each entry names the address, the
contract name, the git commit, the transaction hash, and the time. The five
fields describe the old implementation, never the proxy. `gitCommit` is the one
that lets an operator verify that implementation later.

## Verifying the source on an explorer

Verification needs the build that produced the deployed bytes. `make verify`
runs `forge verify-contract`, which compiles the source again on your machine.
Run it on the deploying machine, from the deployed commit.

```
export ETHERSCAN_API_KEY_11155111=<key>
make verify DEPLOYMENT=BETH CHAIN_ID=11155111
```

The command reads every record for that deployment and chain. It passes each
record's address, contract name, and encoded constructor arguments to
`forge verify-contract`.

forge skips a contract that already has verified source, so you can run the
command as often as you like. It never runs during a deploy, so a slow explorer
cannot fail one.

| Env var | Required | Meaning |
| --- | --- | --- |
| `DEPLOYMENT` | yes | The deployment name, such as `BETH` |
| `CHAIN_ID` | yes | Picks the record files |
| `ETHERSCAN_API_KEY_<CHAIN_ID>` | one of the two | The key for that chain's explorer |
| `ETHERSCAN_API_KEY` | one of the two | The fallback key |
| `VERIFIER_URL_<CHAIN_ID>` | no | That chain's explorer host |
| `VERIFIER_URL` | no | The fallback host. forge picks one otherwise |
| `CONTRACT` | no | One recorded role only, such as `proxy` |
| `ALLOW_COMMIT_MISMATCH` | no | Set to `1` to skip the build guard |
| `DRY_RUN` | no | Set to `1` to print the command and send nothing |

The command finds the roles by reading the file names in `deployments/`. The
role is a free label that the deploy script chooses, so a standalone contract
with one role works without a code change. `CONTRACT` accepts any role the
command found, and it lists them when it rejects one.

The script reads the per-chain key first, then the fallback. It prints which
variable supplied the key, and it never prints the value.

forge picks the explorer host for every chain Etherscan itself operates, and
one key serves them all. A chain whose explorer is Blockscout or Routescan
needs its own host in `VERIFIER_URL_<CHAIN_ID>` and its own key.

The command does not run in CI. It runs on an operator's machine.

### The build guard

The command compares each record's `gitCommit` against your `HEAD`. It stops on
a mismatch and names both commits. Without the guard a stale `out/` submits
source that never produced the deployed bytes, and nothing warns you.

Go back to the deployed commit and build again:

```
git checkout $(jq -r .gitCommit deployments/BETH.proxy.11155111.json)
forge build
make verify DEPLOYMENT=BETH CHAIN_ID=11155111
```

`ALLOW_COMMIT_MISMATCH=1` skips the check. Use it only when you know the local
build matches the deployed bytes.

The record commit is one such case. It adds JSON files and changes no source,
so the build still matches. Verifying before that commit avoids the question.

A teammate who never held that build compiles a different metadata hash, so the
explorer may reject the submission. See the note on remappings below.

### The remappings warning

Foundry writes the nested OpenZeppelin remappings as absolute paths into the
contract metadata. The metadata hash sits in the deployed bytecode, so a build
of the same commit on another machine produces a different hash. That is why
verification belongs on the deploying machine.

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
Withdrawal(bytes withdrawRequestId,address destinationAddress,uint256 amount)
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
    }
}

fn sign_withdrawal(
    signer: &PrivateKeySigner,
    bridge_proxy: Address,
    chain_id: u64,
    cid_bytes: Vec<u8>,        // the raw Canton WithdrawRequest cid bytes
    destination: Address,
    amount_wei: U256,
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

Before rollout, cross-check the encoding against the live contract: the view
`withdrawalDigest(withdrawRequestId, destinationAddress, amount)` returns the
exact digest the contract verifies. Assert your locally computed digest equals
it. Note for raw-key or KMS setups: sign the digest bytes directly (no
`personal_sign` / Ethereum Signed Message prefix — the EIP-712 `\x19\x01`
envelope is already inside the digest).

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
