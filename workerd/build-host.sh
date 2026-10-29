#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p dist/host-worker
cp config.capnp ./*.js dist/host-worker/
python3 ../devtools/build.py dist/host-worker/devtools
