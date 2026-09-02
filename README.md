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
