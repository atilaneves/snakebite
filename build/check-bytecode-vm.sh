#!/usr/bin/env bash
set -euo pipefail
cd "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"

dmd_compiler=${DC:-dmd}
ldc_compiler=${LDC:-ldc2}
check_directory=$(mktemp -d)
trap 'rm -r -- "$check_directory"' EXIT

"$dmd_compiler" -c -of="$check_directory/vm-dmd.o" -Isource \
    source/snakebite/backends/bytecode/vm.d
"$ldc_compiler" -c -of="$check_directory/vm-ldc.o" -Isource \
    source/snakebite/backends/bytecode/vm.d
