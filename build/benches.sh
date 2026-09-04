#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

while IFS= read -r benchmark; do
    bin/bench "$benchmark" -w 0 -r 1
done < <(find examples -mindepth 1 -maxdepth 1 -type d -print | sort)
