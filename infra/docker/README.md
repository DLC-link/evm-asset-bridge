# eth-sandbox

One container runs a local anvil chain and deploys one
`BitSafeEvmAssetBridge` (native ETH) into it. A consumer starts the
container and uses it. A consumer runs no deploy step.

This mirrors the `canton-sandbox` and `dlc-solidity` images that
DLC-link/dlc-attestor-stack already imports. Each image bundles chain,
deploy and healthcheck. A consumer adds each one as a single compose
service.

## Where to get it

```
public.ecr.aws/dlc-link/eth-sandbox:beth-<short-sha>
public.ecr.aws/dlc-link/eth-sandbox:latest
```

The registry is public. A pull needs no login.

The `beth-<short-sha>` tag names the source commit in
DLC-link/evm-asset-bridge. The publishing workflow prints the exact tag
in its run summary. List the published tags with:

```
aws ecr-public describe-images --repository-name eth-sandbox \
    --region us-east-1 --query 'imageDetails[].imageTags'
```

## How a consumer adds it

```yaml
  eth-sandbox:
    image: public.ecr.aws/dlc-link/eth-sandbox:beth-<short-sha>
    container_name: eth-sandbox
    hostname: eth-sandbox
    ports:
      - '8545:8545'
    healthcheck:
      test: ['CMD', '/check-service.sh']
      interval: 5s
      timeout: 5s
      retries: 30
```

A service that needs the bridge waits for it:

```yaml
    depends_on:
      eth-sandbox:
        condition: service_healthy
```

The chain answers at `http://eth-sandbox:8545` inside compose, and at
`http://localhost:8545` from the host.

## The healthcheck

The image ships `/check-service.sh` and declares it as the image
healthcheck. The probe passes only when the bridge proxy holds code.
Code at that address also proves that `initialize` ran, because the
constructor calls it in the same transaction. "Healthy" therefore means
the bridge is configured, not merely that anvil answers.

An inline probe does the same job:

```
cast code --rpc-url http://localhost:8545 \
    0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512 | grep -qv '^0x$'
```

## Chain parameters

The container runs anvil with these flags:

```
anvil --host 0.0.0.0 --port 8545 --chain-id 31337 \
      --slots-in-an-epoch 1 --block-time 1 \
      --mnemonic "test test test test test test test test test test test junk"
```

The image requires both timing flags. Neither one works alone.

`--slots-in-an-epoch 1` makes the `finalized` tag advance. Anvil's
default leaves `finalized` 64 blocks behind the head. A consumer that
scans up to `finalized` then sees nothing until block 65. The flag
narrows the gap to exactly 2 blocks.

`--block-time 1` keeps blocks coming when no transaction arrives.
`finalized` stops moving on an idle chain with the epoch flag alone. A
consumer then waits for finality on the very transaction it must
observe. It waits forever. Testing measured a 25-second freeze of
`finalized` on an idle chain.

## Accounts

Anvil derives every account from the standard, well-known
Foundry mnemonic `test test test test test test test test test test test
junk`, at path `m/44'/60'/0'/0/{index}`.

| Index | Role | Address |
|---|---|---|
| 0 | deployer and ProxyAdmin owner | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` |
| 1 | defaultAdmin | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` |
| 2 | bridgeAdmin | `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC` |
| 3 | attestor #1 | `0x90F79bf6EB2c4f870365E785982E1f101E93b906` |
| 4 | attestor #2 | `0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65` |
| 5 | attestor #3 | `0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc` |
| 6 | test user | `0x976EA74026E726554dB657fA54763abd0C3a0aa9` |

The private keys live in `../../it/attestor-keys.env`.

The threshold is 2 of 3 attestors. The asset is `address(0)`, native
ETH. The bridge sets no deposit or withdraw limits.

The container seeds nothing else. A test funds the bridge through
deposits.

## Contract addresses

| Contract | Address |
|---|---|
| implementation | `0x5FbDB2315678afecb367f032d93F642f64180aa3` |
| proxy, which consumers pin | `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512` |
| `ProxyAdmin`, deployed by the proxy | `0xCafac3dD18aC6c6e92c921884f9E4176737C052c` |

A CREATE address depends only on the sender and its nonce. Account 0
sends the two deploys as its first two transactions. The addresses
therefore repeat on every run. Nothing may send a transaction before
them. `script/DeployIT.s.sol` asserts both addresses and fails loudly on
drift.

## Reading Deposit events

The top-level `README.md` documents the `Deposit` event signature, its
topic layout, and a Rust sample that reads it.

## Building and testing it locally

```
make it-build     # build the image
make it-verify    # build, then run the local acceptance checks
make it-up        # build the image, then start the container
make it-logs      # follow the logs
make it-down      # stop and remove the container
```

`make it-verify` runs `infra/docker/smoke-eth.sh`. CI runs the same
script as its gate before any push. Every check runs inside the
container. The host therefore needs no Foundry install.

CI cannot publish the image yet. The workflow needs an AWS role that
nobody has created yet. Its header comment records the change to make.

## Safety

Every key this chain funds is a PUBLIC, well-known Foundry test key.
Anyone can derive them from the public mnemonic above. **Never** send
real funds to any of these addresses on any network.
