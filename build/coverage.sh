#!/usr/bin/env bash
set -euo pipefail
cd "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

# dmd's -cov drops one-only linkage on manifest-constant init symbols,
# which duplicates across the vendored dmd frontend/backend and fails
# to link. kcov instruments the already-built binary via DWARF/ptrace
# instead, sidestepping the compiler entirely.
command -v kcov > /dev/null

if [[ ! -f build.ninja ]]; then
    dub run reggae --compiler="${DC:-ldc}" -- -b ninja
fi
ninja bin/ut

rm -rf coverage
kcov --include-path="$PWD/source" coverage bin/ut
