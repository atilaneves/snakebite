#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

# dmd's -cov drops one-only linkage on manifest-constant init symbols,
# which duplicates across the vendored dmd frontend/backend and fails
# to link. kcov instruments the already-built binary via DWARF/ptrace
# instead, sidestepping the compiler entirely.
command -v kcov > /dev/null

if [[ ! -f build.ninja ]]; then
    dub run "reggae@~>0.14.0" --compiler="${DC:-ldc}" -- -b ninja
fi
ninja bin/ut

rm -rf coverage coverage-runs
mkdir coverage-runs
trap 'rm -rf coverage-runs' EXIT

# Unit tests cover the backend and report helpers, but not the benchmark
# harness itself. Run every benchmark under kcov so benchmark changes are
# represented in the coverage report as well.
kcov --include-path="$PWD/source/snakebite,$PWD/bench" \
    coverage-runs/unit bin/ut

while IFS= read -r benchmark; do
    name=${benchmark##*/}
    kcov --include-path="$PWD/source/snakebite,$PWD/bench" \
        "coverage-runs/$name" bin/bench "$benchmark" -w 0 -r 1
done < <(find examples -mindepth 1 -maxdepth 1 -type d -print | sort)

kcov --merge coverage coverage-runs/*
