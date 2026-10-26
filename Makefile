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
#   DEPLOYMENT names the script and the records. BETH is the production
#   bridge. CHYPE, CHYPE_DEVNET and CHYPE_TESTNET are the HyperEVM bridges.
#   BETH_DEVNET and BETH_TESTNET are the two Sepolia instances:
#
#   make deploy DEPLOYMENT=BETH_TESTNET RPC_URL=https://... SIGNER="--account deployer"
#
# SIGNER carries the signer flags straight to `forge script`. Foundry reads no
# private key from the environment, so a broadcast needs one of its wallet
# flags. Any flag foundry accepts works, such as:
#
#   SIGNER="--account deployer --sender 0xYourDeployer"
#   SIGNER="--ledger --sender 0xYourDeployer"
#
# Prefer a keystore account or a hardware wallet. A raw key on the command line
# enters your shell history.
#
# Every command takes SIGNER on the make line. Do not export it. One exported
# key would sign a deploy, an admin action and a Safe proposal alike.
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
	@PATH="$(FOUNDRY_BIN):$$PATH" forge script \
	  script/Deploy_$(DEPLOYMENT).s.sol:Deploy_$(DEPLOYMENT) \
	  --rpc-url "$(RPC_URL)" --broadcast $(SIGNER)
	@CHAIN_ID="$$(PATH="$(FOUNDRY_BIN):$$PATH" cast chain-id --rpc-url "$(RPC_URL)")" \
	  ./script/record.sh $(DEPLOYMENT)

record:
ifndef DEPLOYMENT
	$(error DEPLOYMENT is not set. Example: make record DEPLOYMENT=BETH)
endif
	CHAIN_ID="$(CHAIN_ID)" ./script/record.sh $(DEPLOYMENT)

# ---- Verification ----------------------------------------------------------
#
# make verify DEPLOYMENT=BETH_DEVNET CHAIN_ID=11155111
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
	$(error DEPLOYMENT is not set. Example: make verify DEPLOYMENT=BETH_DEVNET CHAIN_ID=11155111)
endif
ifndef CHAIN_ID
	$(error CHAIN_ID is not set. Example: make verify DEPLOYMENT=BETH_DEVNET CHAIN_ID=11155111)
endif
	DEPLOYMENT="$(DEPLOYMENT)" CHAIN_ID="$(CHAIN_ID)" \
	  CONTRACT="$(CONTRACT)" DRY_RUN="$(DRY_RUN)" ./script/verify.sh

# ---- Management ------------------------------------------------------------
#
# The management scripts live in script/manage/<MANAGE_CONTRACT>/. A folder
# names a contract, and DEPLOYMENT names one instance of it.
# script/manage/README.md holds the full list. It gives one make line for
# each action.
#
# make manage DEPLOYMENT=BETH SCRIPT=SetThreshold SIG='run(uint256)' ARGS=3 \
#   RPC_URL=https://... SIGNER="--account defaultAdmin"
#   Runs one admin action. SCRIPT names the file and the contract. SIG names
#   the `run` signature of that contract. ARGS holds the arguments.
#
# SAFE picks the mode. An empty SAFE selects a direct broadcast. The target
# then adds --broadcast and SIGNER. A SAFE address selects Safe mode. The
# target then sends nothing, and the script writes an envelope instead:
#
#   SAFE=0xYourSafe make manage DEPLOYMENT=BETH SCRIPT=Pause SIG='run()' \
#     RPC_URL=https://...
#
# Several arguments need one pair of quotes. The shell splits them again:
#
#   ARGS='10000000000000000000 3600'
#
# Status is read only. It therefore needs no SIGNER in either mode.
#
# make manage-status DEPLOYMENT=BETH RPC_URL=https://...
#   Prints the live configuration of the recorded bridge. It sends nothing.
#
# make propose ENVELOPE=deployments/.safe/BETH.11155111.pause.json \
#   RPC_URL=https://... SIGNER="--account proposer"
#   Proposes one written envelope to its Safe. A management script in Safe
#   mode writes the envelope first. SIGNER names the proposer key.
#   NONCE is optional. It pins the Safe nonce for a batch of proposals.

# The management scripts live under the contract they drive. MANAGE_CONTRACT
# names that folder. DEPLOYMENT names one instance of the contract, and it
# has no default: a default acts against the wrong bridge with no warning.
MANAGE_CONTRACT ?= BitSafeEvmAssetBridge

# These scripts send no transaction. They therefore need no signer.
MANAGE_READ_ONLY := Status

# MANAGE_FLAGS carries the mode. A Safe-mode run and a read-only run send
# nothing, so both leave the flags empty. A direct broadcast adds the two
# broadcast flags, and it demands a signer. MANAGE_MODE names the mode on
# screen, because an exported SAFE decides it and the operator cannot see it
# on the command line.
#
# No part of SIGNER reaches the output. It can carry --private-key or
# --password, and a terminal log keeps whatever a command prints. The operator
# passes SIGNER on the make line, so the line would only repeat what the
# command already shows.
ifneq ($(strip $(SAFE)),)
MANAGE_FLAGS :=
MANAGE_MODE := Safe mode. It writes an envelope for $(SAFE) and broadcasts nothing.
else ifneq ($(filter $(MANAGE_READ_ONLY),$(SCRIPT)),)
MANAGE_FLAGS :=
MANAGE_MODE := read only. It sends no transaction.
else
MANAGE_FLAGS := --broadcast $(SIGNER)
MANAGE_NEEDS_SIGNER := yes
MANAGE_MODE := direct broadcast. It signs and sends a transaction now.
endif

# ---- Upgrades ----------------------------------------------------------------
#
# The upgrade targets drive a proxy whose ProxyAdmin belongs to a timelock.
# Every target needs DEPLOYMENT and RPC_URL. Each one runs the sync before it
# acts, and again after a direct broadcast. script/manage/README.md section 12
# holds the operator sequence and every option.
#
# make upgrade-deploy   DEPLOYMENT=BETH RPC_URL=... SIGNER="--account deployer --slow" [CONTRACT=<path>:<Name>]
# make upgrade-schedule DEPLOYMENT=BETH RPC_URL=... SIGNER="--account proxyOwner" [DATA=0x...]
# make upgrade-execute  DEPLOYMENT=BETH RPC_URL=... SIGNER="--account proxyOwner"
# make upgrade-cancel   DEPLOYMENT=BETH RPC_URL=... SIGNER="--account proxyOwner"
# make upgrade-sync     DEPLOYMENT=BETH RPC_URL=...        (upgrade-status runs the same command)
#   SAFE=0x... selects Safe mode for schedule, execute and cancel.
#
# The timelock delay targets change the minimum delay of the timelock. Each one
# needs DEPLOYMENT, RPC_URL and DELAY, the new delay in seconds. They run no
# sync. Section 12.9 of the README holds the sequence.
#
# make timelock-delay-schedule DEPLOYMENT=BETH RPC_URL=... DELAY=86400 SIGNER="--account proxyOwner"
# make timelock-delay-execute  DEPLOYMENT=BETH RPC_URL=... DELAY=86400 SIGNER="--account proxyOwner"
# make timelock-delay-cancel   DEPLOYMENT=BETH RPC_URL=... DELAY=86400 SIGNER="--account proxyOwner"

UPGRADE_DIR := script/manage/upgrade

define UPGRADE_SYNC
@CHAIN_ID="$$(PATH="$(FOUNDRY_BIN):$$PATH" cast chain-id --rpc-url "$(RPC_URL)")" \
  RPC_URL="$(RPC_URL)" ./script/upgrade-sync.sh $(DEPLOYMENT)
endef

ifneq ($(strip $(SAFE)),)
UPGRADE_FLAGS :=
UPGRADE_MODE := Safe mode. It writes an envelope for $(SAFE) and broadcasts nothing.
define UPGRADE_POST_SYNC
@echo "Safe mode: propose the envelope with make propose. Then run make upgrade-sync after the Safe executes, or run the next upgrade command, which syncs first."
endef
else
UPGRADE_FLAGS := --broadcast $(SIGNER)
UPGRADE_NEEDS_SIGNER := yes
UPGRADE_MODE := direct broadcast. It signs and sends a transaction now.
UPGRADE_POST_SYNC = $(UPGRADE_SYNC)
endif

# $(error) inside a recipe stops make when the recipe expands, before any
# command runs. One function serves the nine targets.
upgrade_require = $(if $(DEPLOYMENT),,$(error DEPLOYMENT is not set. Example: make $(1) DEPLOYMENT=BETH RPC_URL=...))$(if $(RPC_URL),,$(error RPC_URL is not set. Example: make $(1) DEPLOYMENT=BETH RPC_URL=...))

.PHONY: upgrade-deploy upgrade-schedule upgrade-execute upgrade-cancel upgrade-sync upgrade-status
.PHONY: timelock-delay-schedule timelock-delay-execute timelock-delay-cancel

upgrade-deploy:
	$(call upgrade_require,upgrade-deploy)
	@DEPLOYMENT="$(DEPLOYMENT)" CONTRACT="$(CONTRACT)" PATH="$(FOUNDRY_BIN):$$PATH" forge script \
	  $(UPGRADE_DIR)/DeployNextImplementation.s.sol:DeployNextImplementation \
	  --sig 'run()' --rpc-url "$(RPC_URL)" --broadcast $(SIGNER)
	@CHAIN_ID="$$(PATH="$(FOUNDRY_BIN):$$PATH" cast chain-id --rpc-url "$(RPC_URL)")" \
	  ./script/record.sh $(DEPLOYMENT)
	$(UPGRADE_SYNC)

# One recipe serves schedule, execute and cancel. $(1) names the script. DATA
# reaches all three; only ScheduleUpgrade reads it.
define UPGRADE_ACTION
$(call upgrade_require,$@)
$(UPGRADE_SYNC)
@echo "$@: $(UPGRADE_MODE)"
@DEPLOYMENT="$(DEPLOYMENT)" DATA="$(DATA)" PATH="$(FOUNDRY_BIN):$$PATH" forge script \
	  $(UPGRADE_DIR)/$(1).s.sol:$(1) --sig 'run()' --rpc-url "$(RPC_URL)" $(UPGRADE_FLAGS)
$(UPGRADE_POST_SYNC)
endef

upgrade-schedule:
	$(call UPGRADE_ACTION,ScheduleUpgrade)

upgrade-execute:
	$(call UPGRADE_ACTION,ExecuteUpgrade)

upgrade-cancel:
	$(call UPGRADE_ACTION,CancelUpgrade)

upgrade-sync upgrade-status:
	$(call upgrade_require,$@)
	$(UPGRADE_SYNC)

# One recipe serves the three timelock delay targets. $(1) names the script.
# The scripts keep no record, so the recipe runs no sync. The operator gives
# the same DELAY on every command.
define TIMELOCK_DELAY_ACTION
$(call upgrade_require,$@)
$(if $(DELAY),,$(error DELAY is not set. Example: make $@ DELAY=86400 DEPLOYMENT=BETH RPC_URL=...))
@echo "$@: $(UPGRADE_MODE)"
@DEPLOYMENT="$(DEPLOYMENT)" PATH="$(FOUNDRY_BIN):$$PATH" forge script \
	  $(UPGRADE_DIR)/$(1).s.sol:$(1) --sig 'run(uint256)' "$(DELAY)" --rpc-url "$(RPC_URL)" $(UPGRADE_FLAGS)
endef

timelock-delay-schedule:
	$(call TIMELOCK_DELAY_ACTION,ScheduleUpdateDelay)

timelock-delay-execute:
	$(call TIMELOCK_DELAY_ACTION,ExecuteUpdateDelay)

timelock-delay-cancel:
	$(call TIMELOCK_DELAY_ACTION,CancelUpdateDelay)

# ---- the signing key --------------------------------------------------------
#
# SIGNER must come from the make line. An operator who exports it sets one key
# for every command, and `make propose` then signs the proposal with that admin
# key instead of the proposer key. $(origin ...) names the source of a value,
# so it tells an export apart from a make-line argument. A plain ifndef cannot:
# an exported value satisfies it.
#
# A proposal dry run signs nothing, so it needs no signer. propose.sh makes the
# same exemption, and it tests DRY_RUN the same way.
SIGNER_GOALS := $(filter deploy upgrade-deploy,$(MAKECMDGOALS))
ifeq ($(strip $(DRY_RUN)),)
SIGNER_GOALS += $(filter propose,$(MAKECMDGOALS))
endif
ifdef MANAGE_NEEDS_SIGNER
SIGNER_GOALS += $(filter manage,$(MAKECMDGOALS))
endif
ifdef UPGRADE_NEEDS_SIGNER
SIGNER_GOALS += $(filter upgrade-schedule upgrade-execute upgrade-cancel timelock-delay-schedule timelock-delay-execute timelock-delay-cancel,$(MAKECMDGOALS))
endif

ifneq ($(strip $(SIGNER_GOALS)),)
ifeq ($(origin SIGNER),environment)
$(error SIGNER comes from your environment. Pass it on the make line instead: make $(firstword $(SIGNER_GOALS)) SIGNER="--account <name>" ...)
endif
ifeq ($(origin SIGNER),undefined)
$(error SIGNER is not set. Example: make $(firstword $(SIGNER_GOALS)) SIGNER="--account <name>" ...)
endif
endif

.PHONY: manage manage-status propose

manage:
ifndef DEPLOYMENT
	$(error DEPLOYMENT is not set. Example: make manage DEPLOYMENT=BETH SCRIPT=Pause SIG='run()' RPC_URL=...)
endif
ifndef SCRIPT
	$(error SCRIPT is not set. Example: make manage DEPLOYMENT=BETH SCRIPT=Pause SIG='run()' RPC_URL=...)
endif
ifndef SIG
	$(error SIG is not set. Example: make manage SCRIPT=SetThreshold SIG='run(uint256)' ARGS=3)
endif
ifndef RPC_URL
	$(error RPC_URL is not set. Example: make manage SCRIPT=Pause SIG='run()' RPC_URL=...)
endif
	@echo "manage: $(MANAGE_MODE)"
	@DEPLOYMENT="$(DEPLOYMENT)" PATH="$(FOUNDRY_BIN):$$PATH" forge script \
	  script/manage/$(MANAGE_CONTRACT)/$(SCRIPT).s.sol:$(SCRIPT) \
	  --sig '$(SIG)' $(ARGS) --rpc-url "$(RPC_URL)" $(MANAGE_FLAGS)

manage-status:
ifndef DEPLOYMENT
	$(error DEPLOYMENT is not set. Example: make manage-status DEPLOYMENT=BETH RPC_URL=...)
endif
ifndef RPC_URL
	$(error RPC_URL is not set. Example: make manage-status DEPLOYMENT=BETH RPC_URL=...)
endif
	@DEPLOYMENT="$(DEPLOYMENT)" PATH="$(FOUNDRY_BIN):$$PATH" forge script \
	  script/manage/$(MANAGE_CONTRACT)/Status.s.sol:Status \
	  --sig 'run()' --rpc-url "$(RPC_URL)"

propose:
ifndef ENVELOPE
	$(error ENVELOPE is not set. Example: make propose ENVELOPE=deployments/.safe/BETH.11155111.pause.json)
endif
ifndef RPC_URL
	$(error RPC_URL is not set. Example: make propose ENVELOPE=... RPC_URL=...)
endif
	@RPC_URL="$(RPC_URL)" SIGNER="$(SIGNER)" NONCE="$(NONCE)" \
	  PATH="$(FOUNDRY_BIN):$$PATH" ./script/manage/safe/propose.sh "$(ENVELOPE)"
