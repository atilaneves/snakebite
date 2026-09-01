#!/usr/bin/env bash
set -euo pipefail
cd "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

if [[ ! -f build.ninja ]]; then
    # CI only installs the matrix compiler and exports it as $DC; locally
    # there is no $DC and ldc is the default.
    dub run "reggae@~>0.14.0" --compiler="${DC:-ldc}" -- -b ninja
fi

build/check-bytecode-vm.sh
ninja bin/ut
bin/ut
build/acceptance.sh
build/benches.sh
