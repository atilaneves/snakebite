#!/usr/bin/env bash
set -euo pipefail
cd "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

while IFS= read -r benchmark; do
    build/bench.sh "$benchmark" -w 0 -r 1
done < <(find examples -mindepth 1 -maxdepth 1 -type d -print | sort)
