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
    # from the Buildkite list of dmd/phobos
    libinputvisitor@1.2.2
    # intel-intrinsics@1.14.10  # static assert "Not yet supported" in xmmintrin.d at load
    derelict-ft@2.0.0-beta.5
    derelict-gl3@2.0.0-beta.8
    derelict-glfw3@4.0.0-beta.1
    derelict-sdl2@3.1.0-alpha.6
    undead@1.2.0
    scid@0.3.2
    requests@2.2.1
    # ggplotd@1.2.3  # both backends: AssertError at std/range/package.d(7147)
    diet-ng@1.8.4
    poodinis@9.0.2
    dagon@1.6.2
    ae@0.0.3928
    dxml@0.4.5
    mir-random@2.2.21
    optional@1.3.1
    dfmt@0.15.2
    # concurrency@5.0.5  # both backends: SIGSEGV (Interpreter names nursery.d(172))
    # excel-d@0.5.13  # dub describe fails: "Target 'excel-d' doesn't exist"
    ldapauth@1.1.0
    # lubeck@1.5.4  # dependency image does not compile (errors in mir-algorithm source)
    xlsxreader@3.1.0
    imageformats@7.0.2
    # mir@3.2.3  # dub describe fails: "Target 'mir' doesn't exist"
    # mir-core@1.7.4  # inline LLVM IR
    # mir-cpuid@1.2.11  # inline asm
    mir-optim@2.0.9
    dproto@2.1.6
    # vectorflow@1.0.2  # inline asm
    dunit@1.0.16
    sumtype@1.3.0
    pegged@0.4.9
    mustache-d@0.1.5
    # std_data_json@0.18.7  # both backends: SIGSEGV
    # taggedalgebraic@1.0.1  # Bytecode: internal failure on an array operation; Interpreter: ArrayIndexError
    # serialized@1.20.0  # pre-build command uses $DC, which is empty
    # mocked@4.2.1  # both backends: null pointer dereference in std.container.dlist
    argparse@2.1.0
    # vibe-core@2.14.0  # Bytecode: SIGSEGV; Interpreter: AssertError "had GC allocations!"
)

failed=()
for benchmark in "${benchmarks[@]}"; do
    bin/bench "$benchmark" "$@" || failed+=("$benchmark")
done

if ((${#failed[@]})); then
    echo "failed: ${failed[*]}" >&2
    exit 1
fi
