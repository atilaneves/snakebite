# Wasm32 benchmarks

The `wasm32` row runs Dennis Korpel's DMD Wasm backend and Wasmtime as
external processes. It is selected by every example's `bench.backends`
file and by `bin/bench -b wasm32`.

## Setup

On Linux, install DMD, Dub, Make, Clang, LLD (`wasm-ld`), curl, tar, and
sha256sum. Then run:

```sh
build/setup-wasm32.sh
build/reggae.sh
ninja bin/bench
bin/bench rt-simple -b wasm32 -w 1 -r 10
```

`build/benches.sh` also runs setup before starting the benchmarks. Setup
downloads and builds tools under `.tools/wasm32`, which Git ignores. Set
`SNAKEBITE_WASM32_ROOT` to use another directory for both setup and the
benchmark. Set `JOBS` to limit parallel Make jobs.

The fixed versions are:

- [DMD PR #23584][dmd], revision
  `0864cee4e9d091355e86ef8457789142c97bcb10`.
- [Phobos Wasm build target][phobos], revision
  `0f0bf79d32c2b876e755c01ad1e34a5284caa39d`.
- Wasmtime 46.0.1.
- WASI SDK 33's sysroot, checked against the checksum in DMD's Makefile.

Clang and LLD come from the host system. Setup prints the compiler,
Wasmtime, and linker versions. It uses Clang and the WASI sysroot to
preprocess Phobos's C sources for ImportC. It does not change the upstream
sources or Snakebite's `dmd:frontend` dependency.

[dmd]: https://github.com/dlang/dmd/pull/23584
[phobos]: https://github.com/dkorpel/phobos/commit/0f0bf79d32c2

## What the row measures

Dub supplies the project sources, flags, import paths, and dependency
descriptions. Dependency archives are built for Wasm once before timing.
Each round then invokes DMD with `-mwasm32 -os=wasm -unittest` and runs the
result with Wasmtime. The original source files and test runner are used.

`cmp` includes the compiler frontend, code generation, and linking.
`run` includes all of `cmp`, Wasmtime startup and JIT compilation, and test
execution. Wasmtime's persistent code cache is disabled, so repeated
identical builds do not omit JIT compilation. RAM is the larger peak
resident memory value from the compiler and runtime processes.

The native `dmd`/`dub` row subtracts frontend time from its cells and
reports it below the table. Add that frontend time when comparing its full
cycle with `wasm32`. Dub command overhead and dependency preparation are
outside the Wasm row's timing.

Compilation errors, missing tools, and runtime failures produce `FAIL`
with the error on stderr. No tests are removed for this target. The
benchmark script attempts all examples and exits with failure if any row
fails.

Dub does not yet support `wasm32` in its DMD adapter. Project descriptions
therefore use Dub's host platform selection. Projects with platform
specific files, native libraries, or custom build commands can fail;
this adapter does not translate native libraries or run custom build
commands. The DMD and Phobos branches are experimental.

## Results with these revisions

On Linux x86_64, `rt-simple`, `rt-cerealed-0`, `rt-cerealed-1`, and `rt-ffi`
pass. The reported test counts are 22, 26, and 156 for the first three.
`rt-ffi` uses the process exit status.

`ct-easy`, `ct-full`, and `rt-perf` fail compilation because their binary
search uses a `long` array index. DMD rejects that 64-bit index on wasm32.
`rt` fails while building unit-threaded's integration package, which
imports `std.process.execute` and `Config`; these APIs are absent on WASI.
These failures also make `build/benches.sh` and `build/ci.sh` fail. The
example sources remain unchanged.
