# evm-asset-bridge IT keys

This directory holds the attestor key handoff file for the integration
test stack. The stack itself is one Docker image called `eth-sandbox`.

- The image, its addresses, its accounts and its chain flags:
  `../infra/docker/README.md`
- The private keys, one variable per attestor: `attestor-keys.env`
- The deploy logic the image runs: `../script/DeployIT.s.sol`
- The test that pins the deployed configuration: `../test/DeployIT.t.sol`

## Run it

```
make it-verify   # build the image, then check it
make it-up       # build the image, then start the container
make it-down     # stop and remove the container
```

The RPC then listens on `http://localhost:8545`.

## Safety

Every key in this directory is a PUBLIC, well-known Foundry test key.
Anyone can derive them from the public mnemonic that `attestor-keys.env`
records. This repo commits these keys on purpose for this disposable
local stack. **Never** send real funds to any of these addresses on any
network.
