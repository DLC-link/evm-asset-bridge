# Makefile
#
# Convenience targets for the BETH integration-test (IT) image: one
# self-contained container that runs anvil and deploys the bridge.
# See Dockerfile.beth-it and it/README.md.

IT_IMAGE     := beth-it
IT_CONTAINER := beth-it

.PHONY: it-up it-down it-logs

## Build the beth-it image and start the container in the background.
it-up:
	docker build -f Dockerfile.beth-it -t $(IT_IMAGE) .
	docker run -d --name $(IT_CONTAINER) -p 8545:8545 $(IT_IMAGE)

## Stop and remove the IT container. The `-` keeps the target idempotent
## when no container exists, like `compose down`.
it-down:
	-docker rm -f $(IT_CONTAINER)

## Follow the IT container logs (Ctrl-C to stop following).
it-logs:
	docker logs -f $(IT_CONTAINER)
