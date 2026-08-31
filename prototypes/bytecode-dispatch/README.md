# Bytecode dispatch benchmark

This retained prototype answers one question: which initial instruction format
gives the shortest compile-and-run time for the Bytecode VM?

## Formats

- `fixed32` uses one 32-bit word per instruction and switch dispatch.
- `direct` stores a predecoded handler pointer and operand in each cell. Each
  handler tail-calls the next handler.
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

Select direct-threaded instructions. On the measured corpus, their median total
was 24.3735 ms. Fixed 32-bit dispatch took 46.3469 ms and variable-length
dispatch took 49.6212 ms. Encoding time was less than 0.02 ms for every format,
so execution time decided the result. The variable format had the smallest code
at 92 bytes, but its decoding cost did not recover that saving.

The production VM now uses direct-threaded instruction cells. Full-width D
integer constants remain in a constant table. Each cell contains a handler
pointer and a constant-table index or operand.

## Environment

- AMD Ryzen Threadripper 1950X, 16 cores and 32 threads
- Arch Linux 7.1.10-arch1-1, x86-64
- LDC 1.42.0
- DMD frontend 2.112.1
- LLVM 21.1.8
- CPU 2, nine separate processes, 2,000 corpus iterations per process

Raw timings are in `results-threadripper-1950x.csv`. The hardware counter
sample is in `perf-threadripper-1950x.txt`.
