# syntax=docker/dockerfile:1.7

# Compile Clementine
FROM rust:1.88.0 AS builder
WORKDIR /clementine

COPY .cargo .cargo
COPY Cargo.toml Cargo.lock ./
COPY core/Cargo.toml core/Cargo.toml
COPY circuits-lib/Cargo.toml circuits-lib/Cargo.toml
COPY bridge-circuit-host/Cargo.toml bridge-circuit-host/Cargo.toml
COPY crates/clementine-errors/Cargo.toml crates/clementine-errors/Cargo.toml
COPY crates/clementine-primitives/Cargo.toml crates/clementine-primitives/Cargo.toml
COPY crates/clementine-config/Cargo.toml crates/clementine-config/Cargo.toml
COPY crates/clementine-utils/Cargo.toml crates/clementine-utils/Cargo.toml
COPY crates/clementine-extended-rpc/Cargo.toml crates/clementine-extended-rpc/Cargo.toml
COPY crates/tx-sender-types/Cargo.toml crates/tx-sender-types/Cargo.toml
COPY crates/tx-sender-jsonrpc-client/Cargo.toml crates/tx-sender-jsonrpc-client/Cargo.toml
COPY crates/clementine-tx-sender/Cargo.toml crates/clementine-tx-sender/Cargo.toml

RUN mkdir -p core/src/bin circuits-lib/src bridge-circuit-host/src \
      crates/clementine-errors/src crates/clementine-primitives/src \
      crates/clementine-config/src crates/clementine-utils/src \
      crates/clementine-extended-rpc/src crates/tx-sender-types/src \
      crates/tx-sender-jsonrpc-client/src crates/clementine-tx-sender/src \
  && touch core/src/main.rs core/src/lib.rs core/src/bin/cli.rs \
    circuits-lib/src/lib.rs bridge-circuit-host/src/lib.rs \
    crates/clementine-errors/src/lib.rs crates/clementine-primitives/src/lib.rs \
    crates/clementine-config/src/lib.rs crates/clementine-utils/src/lib.rs \
    crates/clementine-extended-rpc/src/lib.rs crates/tx-sender-types/src/lib.rs \
    crates/tx-sender-jsonrpc-client/src/main.rs crates/clementine-tx-sender/src/lib.rs

RUN --mount=type=cache,target=/usr/local/cargo/registry \
  --mount=type=cache,target=/usr/local/cargo/git \
  cargo fetch --locked

COPY . .
RUN --mount=type=cache,target=/usr/local/cargo/registry \
  --mount=type=cache,target=/usr/local/cargo/git \
  --mount=type=cache,target=/clementine/target \
  cargo build --release --bin clementine-core \
  && cp target/release/clementine-core /tmp/clementine-core

FROM debian:bookworm-slim
RUN \
  apt-get update \
  && apt -y install gettext-base libssl-dev wget \
  && apt clean \
  && apt install -y --no-install-recommends ca-certificates \
  && update-ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY --from=builder /tmp/clementine-core /clementine-core

# Set up Clementine
ENTRYPOINT [ "/clementine-core" ]
EXPOSE 17000
