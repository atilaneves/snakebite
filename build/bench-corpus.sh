#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

benchmarks=(
    automem
    cerealed
    dub
    fearless
    mirror
    reggae
    tardy
    test_allocator
    unit-threaded
    vibe-d
    arsd-official
    emsi_containers
    botan
    libdparse
    dcd
    msgpack-d
    mir-algorithm
    dyaml
    dscanner
    dlib
    eventcore
    turtle
    ddox
)

for benchmark in "${benchmarks[@]}"; do
    bin/bench "$benchmark" "$@"
done
