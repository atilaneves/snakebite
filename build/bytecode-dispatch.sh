#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

compiler=${LDC:-ldc2}
output=bin/bytecode-dispatch
mkdir -p bin
"$compiler" -O3 -release -boundscheck=off -mcpu=native \
    -of="$output" prototypes/bytecode-dispatch/main.d

if [[ ${1:-} == --perf ]]; then
    shift
    if ! command -v perf >/dev/null; then
        echo "perf is not available on this host" >&2
        exit 2
    fi
    for format in fixed32 direct variable; do
        perf stat -e cycles,instructions,branches,branch-misses \
            "$output" --format="$format" "$@"
    done
else
    "$output" "$@"
fi
