#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

build/reggae.sh
ninja bin/bench
printf "\n"
echo "----------------------------------------"
bin/bench "$@"
printf "\n"
