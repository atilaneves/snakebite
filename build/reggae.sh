#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

# Apply generator, compiler and frontend version changes to existing builds
# too.
if [[ ! -f build.ninja || "${BASH_SOURCE[0]}" -nt build.ninja
      || build/compilers.sh -nt build.ninja || dub.selections.json -nt build.ninja ]]; then
    dmd=$(build/compilers.sh dmd)
    # Reggae builds the build description with the `dub` and the D compiler
    # on PATH: the ones of build/compilers.sh come first.
    PATH=$(build/compilers.sh path):$PATH
    if [[ -n "${REGGAE_BIN:-}" ]]; then
        "$REGGAE_BIN" -b ninja --dc="$dmd"
    else
        "$(build/compilers.sh dub)" run "reggae@~>0.18.0" --build=release \
            --compiler="$(build/compilers.sh ldc2)" -- -b ninja --dc="$dmd"
    fi
fi
