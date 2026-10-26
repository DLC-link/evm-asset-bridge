# syntax=docker/dockerfile:1.7
#
# This image is one container that runs a local anvil chain AND deploys
# one BitSafeEvmAssetBridge (ETH) into it. Consumers start it and use it.
# They run no deploy step of their own. The healthcheck reports healthy
# only after the bridge exists. A compose service that waits on
# service_healthy starts against a ready bridge.
#
# The image bundles chain, deploy and healthcheck. A consumer imports it
# as a single compose service.
#
# THESE ARE PUBLIC, WELL-KNOWN TEST KEYS (see it/attestor-keys.env).
# NEVER send real funds to any address this chain funds.

# ---- solc fetch stage ----
# forge downloads solc itself when the binary is missing. That download
# has no timeout. It once stalled an image build for over two hours on a
# slow mirror. This stage fetches the pinned solc instead. It uses a
# bounded timeout and bounded retries. A bad mirror then fails the build
# fast.
#
# mirror.gcr.io is Google's Docker Hub pull-through mirror. It avoids the
# anonymous docker.io rate limit.
FROM mirror.gcr.io/library/alpine:3 AS solc
ARG TARGETARCH
ARG SOLC_VERSION=0.8.34
ARG SOLC_COMMIT=80d5c536
RUN set -e; \
    url="https://binaries.soliditylang.org/linux-${TARGETARCH}/solc-linux-${TARGETARCH}-v${SOLC_VERSION}+commit.${SOLC_COMMIT}"; \
    i=0; \
    until wget -T 60 -q -O /solc "$url"; do \
        i=$((i + 1)); \
        if [ "$i" -ge 5 ]; then echo "solc download failed: $url" >&2; exit 1; fi; \
        sleep 2; \
    done; \
    chmod 0555 /solc

# ---- runtime stage ----
FROM ghcr.io/foundry-rs/foundry:v1.8.1

WORKDIR /app

COPY --from=solc /solc /usr/local/bin/solc
# Point forge at the fetched binary. It then never downloads solc itself.
ENV FOUNDRY_SOLC=/usr/local/bin/solc

# Only the inputs forge needs to build and run the IT script are copied
# in. A change under test/ does not invalidate this image's cache.
# --chown: the base image runs as the non-root user `foundry`. Forge
# writes out/, cache/ and broadcast/ under /app.
COPY --chown=foundry:foundry foundry.toml remappings.txt ./
COPY --chown=foundry:foundry lib ./lib
COPY --chown=foundry:foundry src ./src
COPY --chown=foundry:foundry script ./script

# Prebuild the contracts. Then container startup only broadcasts the deploy.
RUN forge build

COPY --chmod=0555 infra/docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=0555 infra/docker/check-service.sh /check-service.sh

EXPOSE 8545

# A consumer may define its own probe instead. See infra/docker/README.md.
HEALTHCHECK --interval=2s --timeout=5s --retries=60 --start-period=5s \
    CMD ["/check-service.sh"]

# Clear the base image's entrypoint. Ours then runs directly.
ENTRYPOINT []
CMD ["/usr/local/bin/entrypoint.sh"]
