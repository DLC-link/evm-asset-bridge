# Makefile
#
# Convenience targets for the evm-asset-bridge Docker-based integration-test
# (IT) stack (anvil + the one-shot Foundry deployer). See docker-compose.it.yml.

COMPOSE_IT := docker compose -f docker-compose.it.yml

.PHONY: it-up it-down it-logs

## Build the IT images and bring the stack up in the background.
it-up:
	$(COMPOSE_IT) up -d --build

## Tear the IT stack down: stops containers and removes volumes and any
## orphaned services, so nothing leaks between runs.
it-down:
	$(COMPOSE_IT) down -v --remove-orphans

## Follow logs for the whole IT stack (Ctrl-C to stop following).
it-logs:
	$(COMPOSE_IT) logs -f
