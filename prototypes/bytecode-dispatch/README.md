# Bytecode dispatch benchmark

This retained prototype answers one question: which initial instruction format
gives the shortest compile-and-run time for the Bytecode VM?

## Formats

- `fixed32` uses one 32-bit word per instruction and switch dispatch.
- `direct` stores a predecoded handler pointer and operand in each cell.
- `variable` uses a one-byte opcode and signed LEB128 operands.

The production VM contains only the selected format. This prototype keeps the
three small implementations so that a later workload can test the decision
again.

## Corpus

All formats compile and execute the same logical programs. The programs cover
an integral loop, a predictable loop branch, an input-dependent branch,
native-layout integer slot loads and stores, three nested calls, and a
recursive countdown. The harness rejects a run when format checksums differ.

This is the focused-kernel part of the temporary corpus. Shared behaviour tests,
examples, and `rt-perf` will become useful format evidence after the Bytecode
backend supports them.

## Run

```console
build/bytecode-dispatch.sh --iterations=2000
taskset -c 2 build/bytecode-dispatch.sh --iterations=2000
taskset -c 2 build/bytecode-dispatch.sh --perf --iterations=2000
```

The last command reports cycles, host instructions, branches, and branch
misses when Linux `perf` and host permissions permit access to those counters.
The release build uses `-O3 -release -boundscheck=off -mcpu=native`.

`compile_ns` measures encoding the logical programs into bytecode. It does not
measure the one-time build of the benchmark executable. `execute_ns` measures
the complete corpus. `total_ns` is their sum. `code_bytes` includes all stored
instruction data needed for dispatch and branch targets.

## Decision

Select fixed 32-bit instructions. On the measured corpus, its median total was
45.6111 ms. The direct format took 130.7156 ms and the variable format took
107.3358 ms. Encoding time was less than 0.02 ms for every format, so execution
time decided the result. The variable format had the smallest code at 92 bytes,
but its decoding cost did not recover that saving.

The production VM now uses fixed 32-bit instructions. Full-width D integer
constants remain in a constant table; an instruction contains its opcode and a
24-bit table index or operand.

## Environment

- AMD Ryzen Threadripper 1950X, 16 cores and 32 threads
- Arch Linux 7.1.10-arch1-1, x86-64
- LDC 1.42.0
- DMD frontend 2.112.1
- LLVM 21.1.8
- CPU 2, nine separate processes, 2,000 corpus iterations per process

Raw timings are in `results-threadripper-1950x.csv`. The hardware counter
sample is in `perf-threadripper-1950x.txt`.
