#!/usr/bin/env bash
set -euo pipefail
cd "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

for benchmark in ct-easy ct-full rt-perf rt-simple rt; do
    build/bench.sh "$benchmark" -w 0 -r 1
done
