#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

for benchmark in ct-full rt-perf rt-cerealed-2; do
    if [[ "$benchmark" == rt-cerealed-2 ]]; then
        # Until the combined-process shutdown bug is fixed, keep each
        # backend's unit-threaded writer in a separate process.
        for backend in dmd bytecode interpreter; do
            bin/bench "$benchmark" -b "$backend" -w 0 -r 1
        done
    else
        bin/bench "$benchmark" -w 0 -r 1
    fi
done
