#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

build/reggae.sh

build/check-bytecode-vm.sh
ninja bin/ut
bin/ut
build/acceptance.sh
build/test-repl.sh
build/sb.sh -b bytecode examples/rt-simple
build/benches.sh
