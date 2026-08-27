#!/usr/bin/env bash
set -euo pipefail
cd "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

if [[ ! -f build.ninja ]]; then
    # CI only installs the matrix compiler and exports it as $DC; locally
    # there is no $DC and ldc is the default.
    dub run reggae --compiler="${DC:-ldc}" -- -b ninja
fi

ninja bin/ut
bin/ut

build/bench.sh examples/ct-easy -w 0 -r 1
build/bench.sh examples/ct-full -w 0 -r 1 -b ctfe -b dmd
build/bench.sh examples/bottom-up -w 0 -r 1 -b dmd -b interpreter
build/bench.sh examples/rt -w 0 -r 1 -b dmd
