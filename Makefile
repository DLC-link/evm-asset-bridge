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
