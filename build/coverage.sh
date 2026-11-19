#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

# dmd's -cov drops one-only linkage on manifest-constant init symbols,
# which duplicates across the vendored dmd frontend/backend and fails
# to link. kcov instruments the already-built binary via DWARF/ptrace
# instead, sidestepping the compiler entirely.
command -v kcov > /dev/null

build/reggae.sh
ninja bin/ut bin/bench bin/sb-prof

rm -rf coverage coverage-runs
mkdir coverage-runs
trap 'rm -rf coverage-runs' EXIT

# Unit tests cover the backend and report helpers, but not the benchmark
# harness itself. Run every benchmark under kcov so benchmark changes are
# represented in the coverage report as well.
# kcov exports paths below its output directory to child processes. Use
# absolute paths because children can change their working directory.
kcov --include-path="$PWD/source/snakebite,$PWD/bench" \
    "$PWD/coverage-runs/unit" bin/ut

# The optimized LDC build can chain handlers and compile scalar regions.
# Run the same guest program as the CLI tests with source lines for kcov.
scalar_jit_fixture="$PWD/tests/fixtures/scalar-jit"
kcov --include-path="$PWD/source/snakebite,$PWD/bench" \
    "$PWD/coverage-runs/scalar-jit" bin/sb-prof -b bytecode \
    --no-optimise-image "$scalar_jit_fixture"

while IFS= read -r benchmark; do
    name=${benchmark##*/}
    kcov --include-path="$PWD/source/snakebite,$PWD/bench" \
        "$PWD/coverage-runs/$name" bin/bench "$benchmark" -w 0 -r 1
done < <(find examples -mindepth 1 -maxdepth 1 -type d -print | sort)

kcov --merge coverage coverage-runs/*

# Source counters also report statements that ThinLTO omits from line tables.
python3 build/bytecode_coverage.py "$scalar_jit_fixture" \
    "$PWD/coverage/ldc-bytecode.info"
