#!/bin/bash

set -euo pipefail

IMAGE=glove80-zmk-config-docker
BRANCH="${1:-main}"
ZMK_REPO="${ZMK_REPO:-moergo-sc/zmk}"

docker build --build-arg ZMK_REPO="$ZMK_REPO" -t "$IMAGE" .
docker run --rm -v "$PWD:/config" -e UID="$(id -u)" -e GID="$(id -g)" -e BRANCH="$BRANCH" "$IMAGE"
