# Complete frame-layout reuse in bytecode compilation

Issue: [#721](https://github.com/atilaneves/snakebite/issues/721).
Measured on 2026-10-13. These are local measurements, not CI thresholds.

## Result

Automem compilation fell from 239.6 ms to 104.9 ms (56.2%). Total process
latency fell from 1.371 s to 1.228 s (10.4%). All ten adjacent pairs improved
both measures. Median paired total saving was 138.8 ms, with a range of
105.0 to 213.2 ms. Peak RSS fell by a paired median of 11.7 MiB.

The frontend medians were 886.9 ms and 886.2 ms. Its paired median change
was +0.9 ms. The main gain therefore came from backend preparation.
Compilation is included in the reported run time; do not add those timers.

## Why

Temporary instrumentation at `FrameLayout.of` counted complete layout
builds by function pointer, entry semantic state, completed semantic state,
and body presence. Serial Automem made 12,423 complete layouts for 2,609
functions. All 12,423 requests entered and left at `PASS.semantic3done`;
all scanned a body. The most frequently rebuilt function had 278 builds.

With reuse, the same workload made 2,609 layouts for 2,609 functions.
Each body was scanned once. This removes 9,814 scans (79.0%). Instrumented
runs are evidence of work counts only, not the latency figures below.
All instrumentation was removed before the release comparison.

The bytecode backend already cached layouts for host entry. Compilation,
guest calls, enclosing-variable access, and shared static-chain planning
now use that same cache. The shared closure module accepts a layout
provider; it still owns all frame, heap-closure, and dual-context hop rules.
The interpreter continues to use its existing path.

## Guarantees

`FrameLayout.of` still completes body semantics and collects the full
body, including lowering temporaries and return-place storage. A layout
enters the cache only after that work returns. The backend owns the cache;
no cache value is stored solely in the frontend arena.

Misses use the existing recursive frontend lock and check the table again
under that lock. Completed entries remain lock-free reads. Callback layouts
are still prepared before host exposure, so a first call from a GC
finalizer does not build a layout. Recursive compiled-function placeholders
and their stable addresses are unchanged.

This follows ADR-0006 and the frontend-arena ADR-0015. The original shared
closure change, `271d7365`, put hop decisions in one module so the backends
could not disagree. Reuse changes how that module obtains complete
layouts, not those decisions. Parameter-only layouts remain separate.

## Method

Baseline: master `623b807341cdc410229ee07dddd6ba4749ece192`.
Candidate: `perf/721-frame-layout`, the source change in this PR.
Both binaries were built in the new worktree with `build/reggae.sh` and
`ninja bin/sb`, LDC 1.43.0, DMD frontend 2.113.0, LLVM 22.1.8,
`-release -O -flto=thin`. The baseline was copied before any D source edit.
The candidate was rebuilt after removal of the temporary diagnostics and
test-only API. There are no new performance regression tests.

SHA-256, baseline:

```text
e17cad3bbe08a539fc820c86183fe60aa744b31b0b052b6b5a36e816dd45c1e8
```

SHA-256, candidate:

```text
11a746e0b970b443641a57cfed5bf85f92bc1724be756b79c923b769542e22c4
```

Host: AMD Threadripper 1950X, 16 cores / 32 logical CPUs, Linux x86-64.
The desktop remained active. No CPU affinity was applied. Builds and other
tests from this task did not run beside timed samples.

Each sample starts a new process. One warm-up per binary and project is
excluded. Pair order alternates before/after and after/before. Both binaries
run from `/tmp` against the same installed package and warm dependency
images. Process latency uses Python `perf_counter` around `Popen.wait`,
without timeout polling. `/usr/bin/time` supplies peak RSS. Output checks
require zero failed tests or the expected modules-passed summary, as well
as exit status zero.

```sh
/tmp/perf721/sb-before automem@0.6.11 -b bytecode -- \
    --single --seed=42 --chrono
/tmp/perf721/sb-after automem@0.6.11 -b bytecode -- \
    --single --seed=42 --chrono
```

Substitute each pinned project below for cross-project checks. Run ten
pairs for Automem and five for each other project. Full process latency
includes package lookup, startup, preparation, execution, output and exit.
Compile timing covers the existing backend timer and excludes lock waiting.

## Cross-project results

All times in this table are milliseconds. Delta is the median of adjacent
paired after-minus-before differences, not the difference of medians.

| Project | Total before | Total after | Paired delta | Compile before/after |
| --- | ---: | ---: | ---: | ---: |
| automem@0.6.11 | 1370.8 | 1228.5 | -138.8 | 239.6 / 104.9 |
| msgpack-d@1.0.5 | 806.5 | 787.2 | -9.4 | 65.4 / 51.3 |
| sumtype@1.3.0 | 1219.1 | 1194.9 | +3.6 | 46.7 / 41.7 |
| cerealed@0.6.12 | 8949.9 | 8428.7 | -567.1 | 274.6 / 170.5 |

Compilation improved in every pair on all four projects. MessagePack total
improved in four of five pairs. Sumtype total improved in two of five;
its approximately 5 ms compile saving is too small to establish a total
latency gain above frontend and host noise in these samples.

Cerealed total improved in all five pairs, but its paired compile saving
was only 95.0 ms against a 567.1 ms total saving. Execution varied. Do not
attribute the rest of that total difference to layout reuse without further
controlled evidence. This change does not optimise VM dispatch.

## All measured pairs

Times are milliseconds. Warm-ups are excluded. These retain the spread and
pairing, including samples that were slower after the change.

### automem@0.6.11

| Pair | Total before | Total after | Compile before | Compile after |
| --- | ---: | ---: | ---: | ---: |
| 1 | 1341.2 | 1201.9 | 237.9 | 101.9 |
| 2 | 1371.9 | 1259.7 | 245.4 | 109.3 |
| 3 | 1330.6 | 1225.6 | 232.2 | 107.3 |
| 4 | 1374.3 | 1216.8 | 238.8 | 104.8 |
| 5 | 1355.0 | 1245.4 | 238.4 | 108.1 |
| 6 | 1437.1 | 1224.0 | 240.3 | 105.0 |
| 7 | 1439.5 | 1259.0 | 271.3 | 109.2 |
| 8 | 1369.6 | 1231.3 | 240.5 | 104.4 |
| 9 | 1346.7 | 1241.4 | 237.3 | 103.9 |
| 10 | 1381.2 | 1201.6 | 245.1 | 102.1 |

### msgpack-d@1.0.5

| Pair | Total before | Total after | Compile before | Compile after |
| --- | ---: | ---: | ---: | ---: |
| 1 | 810.6 | 779.5 | 65.4 | 50.9 |
| 2 | 779.2 | 792.6 | 64.2 | 52.5 |
| 3 | 789.2 | 787.2 | 64.9 | 51.3 |
| 4 | 806.5 | 787.1 | 66.9 | 50.8 |
| 5 | 806.7 | 797.3 | 67.7 | 53.2 |

### sumtype@1.3.0

| Pair | Total before | Total after | Compile before | Compile after |
| --- | ---: | ---: | ---: | ---: |
| 1 | 1176.6 | 1223.3 | 44.8 | 41.7 |
| 2 | 1237.0 | 1190.5 | 46.8 | 41.1 |
| 3 | 1219.1 | 1194.0 | 46.7 | 41.9 |
| 4 | 1191.3 | 1194.9 | 44.5 | 40.4 |
| 5 | 1227.6 | 1234.2 | 47.1 | 42.0 |

### cerealed@0.6.12

| Pair | Total before | Total after | Compile before | Compile after |
| --- | ---: | ---: | ---: | ---: |
| 1 | 8947.9 | 8575.1 | 264.2 | 170.0 |
| 2 | 8949.9 | 8382.8 | 272.3 | 177.3 |
| 3 | 8689.9 | 8480.4 | 274.6 | 180.2 |
| 4 | 9107.9 | 8428.7 | 276.1 | 170.5 |
| 5 | 9068.1 | 8066.7 | 287.0 | 165.9 |

## Remaining compilation cost

A separate release binary adds `-g --force-dwarf-frame-section` and
`--frame-pointer=all`. After warming its dependency image, twelve serial
Automem processes were recorded with `perf record -F 999 -e cycles:u
--call-graph fp`. This binary is used for caller evidence only, not the
release timing comparison above.

Of 26,986 recorded samples, 1,034 contain an observed
`Bytecode.compileFunction` frame. The following weights are conditional on
those compilation stacks. Inclusive rows overlap and must not be added.

| Mechanism | Inclusive compilation sample weight |
| --- | ---: |
| `FrameLayout.of` | 10.17% |
| `LocalsCollector` | 6.07% |
| `PlanCache.hasNativeSymbol` | 27.65% |
| `Resolver.resolve` | 15.77% |
| `mangledNameOf` | 9.62% |
| Conservative GC routines | 7.40% |

Callback-body preparation occurs above 83.47% of these samples: most
compilation is reached through that required preparation. This is not
proof that the callback traversal itself consumes that share. Disabling
preparation would break first execution from GC finalizers.

The next lead is repeated native-symbol probing during call selection,
including mangling and failed resolver lookups. Before changing it, count
requests and unique declarations/names, then establish the validity period
of both successful and failed answers. Preserve native-symbol precedence,
independently linked definitions, builtin selection and dependency-image
lifetime. This profile supports an investigation, not a measured gain from
such a change.

Stack sampling misses inlined or truncated frames. Unknown leaf symbols
account for 17.56% of the conditional compilation weight. LLVM rejected
some debug metadata during the profile build; explicit frame pointers still
provide callers. A zero sample count cannot prove a mechanism is free.
The before/after scan counts provide the direct evidence for layout reuse.

## Validation

The final change passes 3,849 focused existing tests and `build/ci.sh`.
Full CI includes serial and parallel unit runs, arena ownership checks,
acceptance tests, REPL, CLI and compiler-flag checks, and the existing
benchmarks. The final Cerealed benchmark passes 156/156 tests on each
backend. No performance regression tests or permanent instrumentation were
added. The temporary counter and the proposed count test were removed.
