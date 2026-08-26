#!/usr/bin/env bash
set -euo pipefail
cd "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

compiler=ldc2
command -v "$compiler" > /dev/null 2>&1 || compiler=ldc

# The backends must be optimised for the numbers to mean anything, so this
# builds with LDC in release mode regardless of how bin/ut was built.
dub build -q --config=bench --compiler="$compiler" --build=release

exec bin/bench "$@"
