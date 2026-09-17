#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

for benchmark in ct-full rt-perf rt-cerealed-2; do
    bin/bench "$benchmark" -w 0 -r 1
done
