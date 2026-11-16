#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

mapfile -t benchmarks < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' build/corpus-projects.txt)
failed=()
for benchmark in "${benchmarks[@]}"; do
    bin/bench "$benchmark" "$@" || failed+=("$benchmark")
done

if ((${#failed[@]})); then
    echo "failed: ${failed[*]}" >&2
    exit 1
fi
