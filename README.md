# evm-asset-bridge

BitSafeEvmAssetBridge: an upgradeable EVM contract that locks one asset
(ETH or one ERC20) and releases it on attestor-signed withdrawal. BETH
(bridged ETH on Canton) is the first deployment.

- Build: `forge build`
- Test: `forge test`
- Integration-test image: `make it-verify` (see `infra/docker/README.md`)
- The design spec is maintained locally, outside git (not tracked in this repo).

## Production deploy

`script/Deploy.s.sol` deploys the implementation behind a
`TransparentUpgradeableProxy` and writes
`deployments/BitSafeEvmAssetBridge.<chainId>.json`. It reads its
configuration entirely from environment variables:

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

The output JSON also records `assetDecimals`, `targetDecimals`, and
`depositUnit`, so an operator can read the live granularity rule from the
deployment record.

`GIT_COMMIT` (optional) is recorded in the output JSON alongside the
compiler version for provenance; it defaults to `"unknown"` when unset.

Run with:

```
forge script script/Deploy.s.sol:Deploy --rpc-url <RPC_URL> --broadcast
```

### Post-deploy: the sentry pause role

After deploy, the default admin MAY grant `SENTRY_ROLE` to one or more
monitoring-bot keys with `grantRole(SENTRY_ROLE, <bot>)`. A sentry can only
call `pause()`; only the bridge admin unpauses. A hot key is acceptable for
this role: it grants only a denial power, and the admin can always reverse it.

No sentry holder exists at launch. Until a monitoring bot exists, the runbook
keeps a pre-signed `pause()` Safe transaction to cover the gap.

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

Every attestor derives the deadline alone, with the same rule:
`deadline = ledgerTimeOf(WithdrawRequest create) + HORIZON`. `HORIZON` is a
fixed constant in the versioned attestor-stack config. Each attestor reads the
same ledger time, so all signatures hash the same deadline. Choose a `HORIZON`
of a few hours, not weeks: it bounds how long a leaked signature bundle stays
valid. A mismatched `HORIZON` is safe: that signature does not combine, and the
withdrawal stalls until `threshold` attestors agree.

A pause longer than `HORIZON` expires every pending bundle. The request ids
stay unused, so no funds are at risk; the attestors re-sign the withdrawals
after the unpause.

Before rollout, cross-check the encoding against the live contract: the view
`withdrawalDigest(withdrawRequestId, destinationAddress, amount, deadline)`
returns the exact digest the contract verifies. Assert your locally computed
digest equals it. Note for raw-key or KMS setups: sign the digest bytes
directly (no `personal_sign` / Ethereum Signed Message prefix — the EIP-712
`\x19\x01` envelope is already inside the digest).

## Watching Deposit events (Rust)

Both `depositETH` and `depositERC20` emit the same event:

```solidity
event Deposit(
    bytes32 indexed depositAccountIdHash,
    bytes depositAccountId,
    address indexed sender,
    uint256 amount,
    uint256 depositNonce
);
```

- `topic0` (the event signature hash) is
  `0xf3ca88974ec5963addc617fe6c0c359d7196759e318be6ab0cade940986e30e2`,
  which is `keccak256("Deposit(bytes32,bytes,address,uint256,uint256)")`.
- `depositAccountIdHash` (`topic1`) is `keccak256(depositAccountId)`. Filter
  on it to follow one Canton deposit account.
- `sender` (`topic2`) is the EVM account that paid the deposit.
- The data part carries the raw `depositAccountId` bytes (the Canton deposit
  account id), `amount` (wei for ETH, base units for an ERC20 asset), and
  `depositNonce`.
- `depositNonce` is monotonic and dense: the first deposit gets 1, and each
  deposit increments it by exactly 1, with no gaps. Zero never names a real
  deposit, so a consumer can use 0 as a sentinel. Use the nonce as the dedup
  key, and prove completeness with a gap scan: a hole in the observed nonce
  sequence is a missed deposit. The view `depositNonce()` returns the last
  assigned nonce.

Emit address: always the bridge PROXY address, never the implementation.

Complete Rust flow with [Alloy](https://docs.rs/alloy):

```rust
use alloy_primitives::address;
use alloy_provider::{Provider, ProviderBuilder};
use alloy_rpc_types::Filter;
use alloy_sol_types::{sol, SolEvent};

sol! {
    event Deposit(
        bytes32 indexed depositAccountIdHash,
        bytes depositAccountId,
        address indexed sender,
        uint256 amount,
        uint256 depositNonce
    );
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
            "deposit: account_id={} sender={} amount={} nonce={}",
            deposit.depositAccountId, // Bytes prints as 0x-prefixed hex
            deposit.sender,
            deposit.amount,
            deposit.depositNonce,
        );
    }
    Ok(())
}
```

A poller advances `from_block` past the last block it saw. A pubsub setup
subscribes with `subscribe_logs` over WebSocket instead of `get_logs`.
