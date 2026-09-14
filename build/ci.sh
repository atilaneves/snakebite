#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

build/reggae.sh
ninja
bin/ut
bin/at
bin/at-release
build/test-repl.sh
bin/sb -b bytecode examples/rt-simple
build/benches.sh
