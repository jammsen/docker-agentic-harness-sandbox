#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
VERSION=$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$SCRIPT_DIR/Cargo.toml" | head -n 1)
IMAGE=${1:-harness-proxy:local}

if [ -z "$VERSION" ]; then
  echo "could not read package version from $SCRIPT_DIR/Cargo.toml" >&2
  exit 1
fi

exec docker build \
  --build-arg "HARNESS_PROXY_VERSION=$VERSION" \
  --tag "$IMAGE" \
  "$SCRIPT_DIR"
