# Makefile
#
# This Makefile has convenience targets for the evm-asset-bridge
# integration-test image: one container that runs anvil and deploys the
# BETH bridge into it. See infra/docker/README.md.

IT_IMAGE     := evm-asset-bridge:local
IT_CONTAINER := evm-asset-bridge

.PHONY: it-build it-up it-down it-logs it-verify

## Build the evm-asset-bridge image.
it-build:
	docker build -f infra/docker/Dockerfile -t $(IT_IMAGE) .

## Build the image and start the container in the background.
it-up: it-build
	-docker rm -f $(IT_CONTAINER)
	docker run -d --name $(IT_CONTAINER) -p 8545:8545 $(IT_IMAGE)

## Stop and remove the container. The `-` keeps the target idempotent
## when no container exists.
it-down:
	-docker rm -f $(IT_CONTAINER)

## Follow the container logs (Ctrl-C to stop following).
it-logs:
	docker logs -f $(IT_CONTAINER)

## Build the image and run the acceptance gate against it. CI runs the
## same script.
it-verify: it-build
	bash infra/docker/smoke-eth.sh $(IT_IMAGE)

# ---- Deployment ------------------------------------------------------------
#
# make deploy DEPLOYMENT=BETH RPC_URL=https://... SIGNER="--account deployer"
#   The target runs the deploy script. It then writes the deployment records.
#
# SIGNER carries the signer flags straight to `forge script`. Foundry reads no
# private key from the environment, so a broadcast needs one of its wallet
# flags. Any flag foundry accepts works, such as:
#
#   SIGNER="--account deployer --sender 0xYourDeployer"
#   SIGNER="--ledger --sender 0xYourDeployer"
#
# Prefer a keystore account or a hardware wallet. A raw key on the command line
# lands in your shell history.
#
# make record DEPLOYMENT=BETH CHAIN_ID=8453
#   Writes the records again from the last broadcast. Use it when the deploy
#   succeeded but the record step did not. CHAIN_ID is optional. Pass it when
#   more than one pending file waits.

FOUNDRY_BIN := $(HOME)/.foundry/bin

.PHONY: deploy record

deploy:
ifndef DEPLOYMENT
	$(error DEPLOYMENT is not set. Example: make deploy DEPLOYMENT=BETH RPC_URL=...)
endif
ifndef RPC_URL
	$(error RPC_URL is not set. Example: make deploy DEPLOYMENT=BETH RPC_URL=...)
endif
ifndef SIGNER
	$(error SIGNER is not set. Example: SIGNER="--account deployer --sender 0x...")
endif
	PATH="$(FOUNDRY_BIN):$$PATH" forge script \
	  script/Deploy_$(DEPLOYMENT).s.sol:Deploy_$(DEPLOYMENT) \
	  --rpc-url $(RPC_URL) --broadcast $(SIGNER)
	CHAIN_ID="$$(PATH="$(FOUNDRY_BIN):$$PATH" cast chain-id --rpc-url $(RPC_URL))" \
	  ./script/record.sh $(DEPLOYMENT)

record:
ifndef DEPLOYMENT
	$(error DEPLOYMENT is not set. Example: make record DEPLOYMENT=BETH)
endif
	CHAIN_ID="$(CHAIN_ID)" ./script/record.sh $(DEPLOYMENT)

# ---- Verification ----------------------------------------------------------
#
# make verify DEPLOYMENT=BETH CHAIN_ID=11155111
#   Submits the source of all three contracts to the explorer.
#
# Set the API key first. The per-chain variable wins:
#   export ETHERSCAN_API_KEY_11155111=...
#   export ETHERSCAN_API_KEY=...           # the fallback
#
# Optional: CONTRACT=proxy limits it to one recorded role. DRY_RUN=1 sends
# nothing.

.PHONY: verify

verify:
ifndef DEPLOYMENT
	$(error DEPLOYMENT is not set. Example: make verify DEPLOYMENT=BETH CHAIN_ID=11155111)
endif
ifndef CHAIN_ID
	$(error CHAIN_ID is not set. Example: make verify DEPLOYMENT=BETH CHAIN_ID=11155111)
endif
	./script/verify.sh
