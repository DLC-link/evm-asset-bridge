# evm-asset-bridge IT stack

The EVM half of the cross-repo integration-test stack, packed into one
self-contained image called `beth-it`. The container runs a local anvil
chain, deploys one `BitSafeEvmAssetBridge` behind a
`TransparentUpgradeableProxy`, and then keeps the chain up. The contract
addresses are fixed and deterministic, so the DAML (Canton) and
dlc-attestor components can hardcode what they talk to.

## Run it

```
make it-up     # build the beth-it image and start the container
make it-logs   # follow the container logs (anvil + deploy output)
make it-down   # stop and remove the container
```

Anvil's RPC is published at `http://localhost:8545` (chain id 31337).

## The beth-it image

`Dockerfile.beth-it` builds the image:

- `forge build` runs at image build time, so the container never compiles
  at startup.
- `it/beth-it-entrypoint.sh` starts anvil, runs `script/DeployIT.s.sol`
  with broadcast, writes the `/tmp/beth-it-deployed` marker, and then
  waits on anvil. A deploy failure stops the container with a non-zero
  exit.
- `it/check-service.sh` is the container healthcheck. It passes only when
  the RPC answers and the marker file exists. "Healthy" therefore means
  "the bridge is deployed at the fixed addresses below", not just "the
  chain is up".

This mirrors the `dlc-solidity` IT image pattern that
`dlc-attestor-stack/it/docker-compose.yml` already consumes: chain,
deploy, and healthcheck in one image, imported as a single compose
service.

## ECR

The image lives in the private ECR repository:

```
903295530547.dkr.ecr.us-east-1.amazonaws.com/beth-it
```

Tags: the 7-char git SHA of the source commit, plus `latest`. Pull the
newest image (after `docker login` to the registry, see below):

```
docker pull 903295530547.dkr.ecr.us-east-1.amazonaws.com/beth-it:latest
```

The repository name differs from the GitHub repository name, so the
auto-provisioned `gh-oidc-build-*` role cannot push to it from CI. Push
manually:

```
aws ecr get-login-password --region us-east-1 --profile <profile> | \
  docker login --username AWS --password-stdin 903295530547.dkr.ecr.us-east-1.amazonaws.com
docker buildx build -f Dockerfile.beth-it \
  --platform linux/amd64,linux/arm64 \
  -t 903295530547.dkr.ecr.us-east-1.amazonaws.com/beth-it:$(git rev-parse --short HEAD) \
  -t 903295530547.dkr.ecr.us-east-1.amazonaws.com/beth-it:latest \
  --push .
```

## Importing the image in a consumer compose

Example service for `dlc-attestor-stack/it/docker-compose.yml`:

```yaml
  beth-chain:
    image: 903295530547.dkr.ecr.us-east-1.amazonaws.com/beth-it:${BETH_IMAGE_TAG}
    container_name: beth-chain
    hostname: beth-chain
    ports:
      - '8547:8545'
    healthcheck:
      test: ['CMD', '/check-service.sh']
      interval: 2s
      timeout: 2s
      retries: 45
```

A service that needs the bridge gates on it with
`depends_on: { beth-chain: { condition: service_healthy } }` and reaches
the chain at `http://beth-chain:8545`.

## Watching Deposit events

The top-level `README.md` documents the `Deposit` event signature and a
Rust (alloy) sample that reads the events. Against this container the RPC
is `http://localhost:8545` (or `http://beth-chain:8545` inside compose)
and the bridge proxy is `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512`.

## Accounts

All accounts are derived from the standard, well-known Foundry/Hardhat test
mnemonic (`test test test test test test test test test test test junk`,
path `m/44'/60'/0'/0/{index}`) that anvil uses by default with no
`--mnemonic` flag. See `attestor-keys.env` for the private keys and
`../script/DeployIT.s.sol` for the deployment logic.

| Index | Role | Address |
|---|---|---|
| 0 | deployer / ProxyAdmin owner | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` |
| 1 | defaultAdmin | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` |
| 2 | bridgeAdmin | `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC` |
| 3 | attestor #1 | `0x90F79bf6EB2c4f870365E785982E1f101E93b906` |
| 4 | attestor #2 | `0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65` |
| 5 | attestor #3 | `0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc` |
| 6 | test user | `0x976EA74026E726554dB657fA54763abd0C3a0aa9` |
| 7 | attestor #4 | `0x14dC79964da2C08b23698B3D3cc7Ca32193d9955` |
| 8 | attestor #5 | `0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f` |

Attestors #4 and #5 use indices 7 and 8, after the test user, so indices
0-6 stay stable for consumers that already hold those keys.

Threshold: 3 of 5 attestors. Asset: `address(0)` (native ETH). No deposit or
withdraw limits (`Limits(0, type(uint256).max)` both ways).

## Fixed contract addresses

Deploying from a fresh anvil chain (deployer nonce 0) with exactly the two
broadcast `CREATE`s in `script/DeployIT.s.sol` yields:

| Contract | Address |
|---|---|
| `BitSafeEvmAssetBridge` implementation | `0x5FbDB2315678afecb367f032d93F642f64180aa3` |
| `BitSafeEvmAssetBridge` proxy (the bridge) | `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512` |
| `ProxyAdmin` (auto-deployed by the proxy, owned by the deployer) | `0xCafac3dD18aC6c6e92c921884f9E4176737C052c` |

`script/DeployIT.s.sol` asserts the implementation and proxy addresses
after broadcasting, so any drift (e.g. an extra transaction sneaking in
before them) fails the deploy loudly instead of silently shipping a
different address to consumers who hardcoded the table above.

## Handing keys to a dlc-attestor node

See the header comment in `attestor-keys.env` for the exact
`ATTESTOR_N_EVM_PRIVATE_KEY` -> attestor container `EVM_PRIVATE_KEY`
mapping, modeled on `dlc-attestor-stack/it/docker-compose.yml` and
`dlc-attestor-stack/it/attestor-config.docker.toml`.

## Safety

Every key in this directory is a PUBLIC, well-known Foundry/Hardhat test
key. Anyone can derive them from the public mnemonic phrase above. They are
committed on purpose for this disposable local IT stack. **Never** send
real funds to any of these addresses on any network other than this repo's
local anvil.
