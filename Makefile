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
# make deploy DEPLOYMENT=BETH RPC_URL=https://...
#   Runs the deploy script, then writes the deployment records.
#
# make record DEPLOYMENT=BETH
#   Writes the records again from the last broadcast. Use it when the deploy
#   succeeded but the record step did not.

FOUNDRY_BIN := $(HOME)/.foundry/bin

.PHONY: deploy record

deploy:
ifndef DEPLOYMENT
	$(error DEPLOYMENT is not set. Example: make deploy DEPLOYMENT=BETH RPC_URL=...)
endif
ifndef RPC_URL
	$(error RPC_URL is not set. Example: make deploy DEPLOYMENT=BETH RPC_URL=...)
endif
	PATH="$(FOUNDRY_BIN):$$PATH" forge script \
	  script/Deploy_$(DEPLOYMENT).s.sol:Deploy_$(DEPLOYMENT) \
	  --rpc-url $(RPC_URL) --broadcast
	./script/record.sh $(DEPLOYMENT)

record:
ifndef DEPLOYMENT
	$(error DEPLOYMENT is not set. Example: make record DEPLOYMENT=BETH)
endif
	./script/record.sh $(DEPLOYMENT)
