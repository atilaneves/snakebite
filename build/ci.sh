#!/usr/bin/env bash
set -euo pipefail
cd "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

if [[ ! -f build.ninja ]]; then
    # CI only installs the matrix compiler and exports it as $DC; locally
    # there is no $DC and ldc is the default.
    dub run reggae --compiler="${DC:-ldc}" -- -b ninja
fi

ninja bin/ut && bin/ut
build/benches.sh
