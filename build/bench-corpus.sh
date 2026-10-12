#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

benchmarks=(
    automem@0.6.11
    cerealed@0.6.12
    dub@1.42.0
    fearless@0.0.4
    mirror@0.3.4
    reggae@0.17.0
    tardy@0.0.3
    test_allocator@0.3.4
    unit-threaded@2.2.6
    vibe-d@0.10.3
    arsd-official@12.1.2
    emsi_containers@0.9.0
    # botan  # inline asm
    # libdparse  # inline asm
    dcd@0.19.4
    msgpack-d@1.0.5
    # mir-algorithm  # inline LLVM IR
    dyaml@0.10.0
    dscanner@0.15.2
    dlib@1.8.1
    eventcore@0.9.39
    turtle@0.1.4
    ddox@0.16.24
)

failed=()
for benchmark in "${benchmarks[@]}"; do
    bin/bench "$benchmark" "$@" || failed+=("$benchmark")
done

if ((${#failed[@]})); then
    echo "failed: ${failed[*]}" >&2
    exit 1
fi
