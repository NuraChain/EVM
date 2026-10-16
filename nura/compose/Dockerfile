# syntax=docker/dockerfile:1

# Nura node image. The build context is the repository root:
#   docker build -f nura/compose/Dockerfile .
#
# The binary must be built from this repository. evmd/app.go never mints, so an
# upstream cosmos/evm binary computes a different app hash on the first block.

ARG GO_VERSION=1.25.9

FROM golang:${GO_VERSION}-bookworm AS build

WORKDIR /src
COPY . .

# A deploy platform's clone may be shallow or detached; VCS stamping is not
# worth a failed build. The Makefile still stamps the version from git when it
# can.
ENV GOFLAGS=-buildvcs=false

RUN --mount=type=cache,target=/go/pkg/mod \
	--mount=type=cache,target=/root/.cache/go-build \
	make build

FROM debian:bookworm-slim

RUN apt-get update \
	&& apt-get install -y --no-install-recommends ca-certificates curl jq \
	&& rm -rf /var/lib/apt/lists/*

# NODE_HOME is evmd's default home, so manual commands in the container shell
# find it without --home. Created here so a fresh named volume inherits the
# evmd ownership and 0750 mode.
RUN useradd --create-home --home-dir /home/evmd --shell /bin/bash evmd \
	&& install -d -o evmd -g evmd -m 0750 /home/evmd/.evmd

COPY --from=build /src/build/evmd /usr/local/bin/evmd

# The same scripts the systemd hosts run. Every value they read comes from the
# container environment, so their nura.env stays empty.
COPY --chmod=0755 nura/lib.sh nura/05_configure_node.sh nura/08_create_validator.sh /opt/nura/
COPY nura/config/genesis.json /opt/nura/genesis.json
COPY --chmod=0755 nura/compose/entrypoint.sh /usr/local/bin/nura-entrypoint
RUN echo "# Values come from the container environment." > /opt/nura/nura.env

# Chain-wide constants, matching nura.env.example and the genesis baked in above.
# Per-host values (MONIKER, peers, external address, checksum) come from
# docker-compose.yml.
ENV NODE_HOME=/home/evmd/.evmd \
	NODE_USER=evmd \
	CHAIN_ID=nura_1020-1 \
	EVM_CHAIN_ID=1020 \
	DENOM=anura \
	DISPLAY_DENOM=nura \
	MIN_GAS_PRICE_WEI=45000000000000 \
	SECONDS_PER_BLOCK=3 \
	KEYRING_BACKEND=file \
	VALIDATOR_KEY=validator \
	GENESIS_SOURCE=/opt/nura/genesis.json

USER evmd
# evmd creates ./data in whatever directory it runs from; inside NODE_HOME that
# is the real data directory.
WORKDIR /home/evmd/.evmd

EXPOSE 26656
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/nura-entrypoint"]
