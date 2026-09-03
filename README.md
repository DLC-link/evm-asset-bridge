# evm-asset-bridge

BitSafeEvmAssetBridge: an upgradeable EVM contract that locks one asset
(ETH or one ERC20) and releases it on attestor-signed withdrawal. BETH
(bridged ETH on Canton) is the first deployment.

- Build: `forge build`
- Test: `forge test`
- The design spec is maintained locally, outside git (not tracked in this repo).

## Production deploy

`script/Deploy.s.sol` deploys the implementation behind a
`TransparentUpgradeableProxy` and writes
`deployments/BitSafeEvmAssetBridge.<chainId>.json`. It reads its
configuration entirely from environment variables:

| Env var | Meaning |
| --- | --- |
| `ASSET` | Bridged asset address; `address(0)` for ETH, else the ERC20 address |
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

`GIT_COMMIT` (optional) is recorded in the output JSON alongside the
compiler version for provenance; it defaults to `"unknown"` when unset.

Run with:

```
forge script script/Deploy.s.sol:Deploy --rpc-url <RPC_URL> --broadcast
```

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

## Voiding a withdraw request

`voidWithdrawRequest(bytes withdrawRequestId)` (`BRIDGE_ADMIN_ROLE`) marks an
id used without paying it and emits `WithdrawRequestVoided`. Use it when the
matching Canton withdraw request is cancelled and the user is credited back
on Canton: a signed `Withdrawal` bundle has no deadline, so without the void
it could still pay that id later. It reverts with `EmptyId` or
`WithdrawRequestAlreadyUsed` exactly as `withdraw` does, so a paid id cannot
be voided and a voided id cannot be paid. It works while the bridge is
paused, since a pause is the incident response and the void is part of
resolving it. Attestors should confirm a Canton cancel only when
`isWithdrawRequestUsed(id)` is true and no `Withdraw` event exists for the id.

Before rollout, cross-check the encoding against the live contract: the view
`withdrawalDigest(withdrawRequestId, destinationAddress, amount)` returns the
exact digest the contract verifies. Assert your locally computed digest equals
it. Note for raw-key or KMS setups: sign the digest bytes directly (no
`personal_sign` / Ethereum Signed Message prefix — the EIP-712 `\x19\x01`
envelope is already inside the digest).
