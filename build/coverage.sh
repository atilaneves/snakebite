#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

# dmd's -cov drops one-only linkage on manifest-constant init symbols,
# which duplicates across the vendored dmd frontend/backend and fails
# to link. kcov instruments the already-built binary via DWARF/ptrace
# instead, sidestepping the compiler entirely.
command -v kcov > /dev/null

build/reggae.sh
ninja bin/ut bin/bench bin/sb-coverage

rm -rf coverage coverage-runs
mkdir coverage-runs
fixture=$(mktemp -d)
trap 'rm -rf coverage-runs "$fixture"' EXIT

# Unit tests cover the backend and report helpers, but not the benchmark
# harness itself. Run every benchmark under kcov so benchmark changes are
# represented in the coverage report as well.
# kcov exports paths below its output directory to child processes. Use
# absolute paths because children can change their working directory.
kcov --include-path="$PWD/source/snakebite,$PWD/bench" \
    "$PWD/coverage-runs/unit" bin/ut

while IFS= read -r benchmark; do
    name=${benchmark##*/}
    kcov --include-path="$PWD/source/snakebite,$PWD/bench" \
        "$PWD/coverage-runs/$name" bin/bench "$benchmark" -w 0 -r 1
done < <(find examples -mindepth 1 -maxdepth 1 -type d -print | sort)

# The private compiled-call path needs LDC's optimized chained dispatcher.
# Exercise both forms of the end-to-end CLI fixture. LDC's own counters
# retain line coverage when optimized DWARF attributes emitter code to
# an inlined assembler helper. The focused recording supplements the bytecode
# backend. The unit and benchmark runs above retain whole-project coverage.
cp tests/fixtures/compiled-call-frames/main.d.in "$fixture/main.d"
mkdir "$fixture/listings"
coverage_options="--DRT-covopt=dstpath:$fixture/listings merge:1"
run_compiled_call_fixture() {
    local output_name=$1
    shift
    kcov --include-path="$PWD/source/snakebite/backends/bytecode" \
        "$PWD/coverage-runs/$output_name" bin/sb-coverage \
        "$coverage_options" -b bytecode "$@" | tee "$fixture/result"
    grep -Fx 'selective ABI checks passed' "$fixture/result"
}
run_compiled_call_fixture compiled-call-source "$fixture"
bin/sb-coverage "$coverage_options" -b bytecode "--save=$fixture/main.sbx" "$fixture"
run_compiled_call_fixture compiled-call-image "--load=$fixture/main.sbx"

kcov --merge coverage coverage-runs/*
python3 build/merge-ldc-coverage.py coverage/kcov-merged/codecov.json "$fixture/listings"
