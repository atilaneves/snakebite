#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

build/setup-wasm32.sh

status=0
while IFS= read -r benchmark; do
    bin/bench "$benchmark" -w 0 -r 1 || status=1
done < <(find examples -mindepth 1 -maxdepth 1 -type d -print | sort)

wasm_examples=(rt-simple rt-cerealed-0 rt-cerealed-1 rt-ffi)
for benchmark in "${wasm_examples[@]}"; do
    bin/bench "$benchmark" -b wasm32-jit -w 0 -r 1 || status=1
done

# Wizard's fast interpreter currently supports Linux x86_64 only. Keep the
# Wasmtime row available on AArch64, where the setup script still supports it.
if [[ "$(uname -s)/$(uname -m)" == Linux/x86_64 ]]; then
    for benchmark in "${wasm_examples[@]}"; do
        bin/bench "$benchmark" -b wasm32-interpreter -w 0 -r 1 || status=1
    done
fi
exit "$status"
