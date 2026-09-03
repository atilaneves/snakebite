#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

if [[ ! -f build.ninja ]]; then
    # CI only installs the matrix compiler and exports it as $DC; locally
    # there is no $DC and ldc is the default.
    dub run "reggae@~>0.14.0" --compiler="${DC:-ldc}" -- -b ninja
fi

build/check-bytecode-vm.sh
ninja bin/ut
bin/ut
build/acceptance.sh
build/test-repl.sh
build/sb.sh -b bytecode examples/rt-simple
build/benches.sh
