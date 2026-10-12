# Research: why the frontend uses an arena

This note describes the baseline at `9ef27cd8`, before the tests moved.
The resulting decision is [ADR-0015](
../docs/adr/0015-frontend-memory-uses-an-arena.md). Current ownership
validation runs in `bin/arena`; `bin/ut --check-arena` was removed.

## Question
Why does snakebite allocate DMD frontend data from an arena, and what
must remain covered if arena scans change to improve parallel `bin/ut`
performance?
## Findings
### The arena matches DMD's allocation lifetime
DMD builds AST and compiler objects that remain in its process-wide
compiler state. Its normal allocator is a bump allocator that does not
free or scan those objects. The first snakebite arena commit records the
concrete problem: before the change, parsing `import std;` in `sb-repl`
put the retained AST on the GC heap. The GC then scanned it during six
collections in the frontend and once more at exit. The commit routed
frontend allocations to an arena and kept the conservative GC for the
rest of the process. [Commit b590f528](
https://github.com/atilaneves/snakebite/commit/b590f528)
This is a default performance and memory policy, not the only supported
policy. `--lowmem` sends frontend allocations through the GC, like DMD's
`-lowmem`. The process GC remains active because snakebite runs guest D
and host code in one process. Disabling it would change guest runtime
behavior. DMD's own normal mode disables automatic GC for its compilation
work, but that does not mean explicit `GC.collect` is impossible; it
means DMD does not want its retained compiler graph collected as ordinary
GC data. [Commit b590f528](
https://github.com/atilaneves/snakebite/commit/b590f528),
[DMD memory allocator](
https://github.com/dlang/dmd/blob/master/compiler/src/dmd/root/rmem.d)
### The arena and guest GC have separate jobs
The proxy sends allocations to the arena only while a thread executes DMD
frontend code. Other host work and guest work use druntime's conservative
GC. Arena memory is never freed or scanned by that GC. The core invariant
is therefore: an arena object must not be the only reference to a GC
object. Frontend input arrays are copied so that DMD cannot retain host
GC memory through an input pointer. Debug checks catch DMD allocations
that escape the frontend boundary, and `--check-arena` looks for arena
words that point into GC blocks. [Current GC proxy](../source/snakebite/gc.d),
[frontend boundary](../source/snakebite/frontend/compiler.d)
The arena does not replace native layout or druntime. Guest data still
uses native D layout, and calls across the host/guest barrier use those
same values. Guest allocations, collection, and finalizer behavior still
go through druntime. The proxy forwards GC operations such as
`runFinalizers`; it handles arena allocations as permanent frontend
storage. This distinction matters: the arena is not a second guest heap.
[ADR-0005](../docs/adr/0005-no-frame-marker-around-host-calls-for-the-gc.md),
[ADR-0006](
../docs/adr/0006-host-threads-enter-guest-code-through-thread-local-state.md),
[ADR-0008](../docs/adr/0008-every-configuration-links-druntime-shared.md)
### Why the full-arena scan tests exist
The scan validates a cross-cutting ownership invariant. An arena word
that points into a GC block can be the only live reference to that block.
The collector cannot see the arena, so it can reclaim the block while
DMD still uses it. The tests exercise real frontend work, host library
cache initialization, deliberate pointer planting, pointer-free
`NO_SCAN` storage, and recorded stack addresses. They protect both the
invariant and the report's classification rules. The runner's
`--check-arena` path checks the entire arena after selected tests, because
an unexpected retained pointer may come from any earlier frontend call.
[Memory tests, now moved](../validation/arena/memory.d),
[replacement validation runner](../validation/main.d),
[arena report](../source/snakebite/gc.d)
The scan also has measurable cost when repeated. The supplied diagnosis
measured 21 whole-arena scans in the ordinary memory test module. A
single enum representation scan took 0.087 seconds with a small arena
and 4.22 seconds after full frontend prewarm. A parallel profiler sample
attributed 72% of its samples to arena scan functions. These measurements
support reducing redundant scans or scan work, while preserving a full
invariant check and its behavior tests. They do not show that the
invariant is unnecessary.
### History shows the scan is a regression guard, not routine work
The initial arena change added the full-arena invariant checker and
memory tests. Later failures exposed false positives and missing cases:
stack addresses captured by DMD closure frames were recorded and skipped
([commit 54aeb140](https://github.com/atilaneves/snakebite/commit/54aeb140));
pointer-free `NO_SCAN` blocks were excluded from the walk
([issue #571](https://github.com/atilaneves/snakebite/issues/571),
[fix commit](https://github.com/atilaneves/snakebite/commit/1d4dce04));
and a later review distinguished actual GC pointers from integer-table
values that happened to resemble addresses (issue #571 comments). These
cases show why scan changes must retain negative controls as well as the
planted real-pointer check.
Separate finalizer work gives a parallelism constraint. Issue #569
documents that forcing process-wide GC finalizer searches while other
threads allocate can hit a druntime race. The owner decision recorded in
that issue says `GC.collect` affects global state and is unsuitable for
parallel unit tests. This supports keeping tests that require forced
collection or finalization out of ordinary parallel `bin/ut` execution.
It is not a reason to weaken arena pointer checks.
[Issue #569](https://github.com/atilaneves/snakebite/issues/569)
## Design-record check
The checked `docs/adr/` set contains ADRs 0001 through 0014, with no ADR
about the frontend arena or its allocation policy. ADR-0005, ADR-0006,
and ADR-0008 cover adjacent GC requirements: host and guest roots,
thread attachment, and shared druntime. They do not record why DMD's
frontend uses an arena or define its pointer-ownership invariant. The
initial commit and source comments document that rationale, but there is
no dedicated design record. This note records the evidence; it does not
create an ADR.
## Implications for performance work
- Preserve the arena's default role for long-lived DMD frontend state,
  or measure and state the cost of changing that policy.
- Keep the guest and host conservative GC active, with druntime owning
  guest collection and finalizer semantics.
- Preserve checks for real arena-to-GC pointers, host caches, and frontend
  allocation boundaries. Keep tests that prove `NO_SCAN` data and
  recorded stack addresses do not produce false positives.
- Reduce duplicate whole-arena walks or narrow ordinary per-test scans
  only if a full-arena check remains available and the behavioral cases
  above still run against it.
- Do not use forced collection/finalizer activity as ordinary parallel
  unit-test setup. Issue #569 records the shared-state hazard.
## Measurements supplied for this investigation
Times are approximate. Other build activity occurred later. The rest-suite
`j32` run had one SIGSEGV in `rt_hasFinalizerInSegment` through
`GC.runFinalizers`, `_d_dso_registry`, and guest image unregister while the
Bytecode `programStatus` test ran. A repeat passed. This is one observed
failure; it does not establish a cause.
| Run | `j1` | `j32` |
| --- | ---: | ---: |
| Full suite | 79.62 s | 63.62 s |
| `ut.frontend.memory` | 8.08 s | 19.18 s |
| Rest suite, reported as `8059` | 30.97 s | 24.10 s repeat |
The controlled single-test comparison above was repeated: 0.084 seconds
with the small arena and 3.935 seconds after full prewarm. Both runs
executed the same one test and passed. A negative tag with no matching
tests made prewarm prepare all modules while preserving test selection.
The report holds the process-wide frontend lock throughout the walk.
Parsing, CTFE execution, and bytecode compilation also need that lock.
Thus more test workers cannot make those scans run concurrently with
frontend work. See the [report lock](../source/snakebite/frontend/compiler.d)
and [CTFE entry point](../source/snakebite/backends/ctfe/package.d).
Startup and prewarm took about 3.5 seconds. The serial forced-finalizer
pass took about 8 milliseconds. Neither explains most of the full run.
Disabling parallel GC marking reduced CPU time, but did not improve
elapsed time in these runs. Other build activity limits that comparison.
## Unverified points
The measurements above were supplied by the active parallel-performance
diagnosis and were not independently rerun for this note. The initial
arena rationale is present in commit b590f528's message; no earlier
GitHub issue or separate design proposal for that change was verified.
