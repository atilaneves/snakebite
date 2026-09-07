# Bytecode guest return performance

Removing the extra guest return copy reduced the `rt-perf` runtime by 3.4%
on this host. The median of six batch medians fell from 90.1 ms to 87.0 ms.
The changed executable was faster in all six paired batches.

## Change

In `source/snakebite/backends/bytecode/vm.d`, `opCall` now passes the caller's
result slot to the guest callee. It passes null for void or discarded
results. This removes the scratch return buffer and the copy from that
buffer to the caller. Argument copies and the return-width limit are
unchanged.

The caller frame has a stable address throughout nested calls. The compiler
runs pending `finally` bodies before `opReturn` writes the result.

## Method

- Date: 2026-09-07.
- Baseline: `9888a25d209b96679fb737925871d8d2a2a05126`.
- Branch: `perf/vm-direct-return`.
- Host: Intel Core Ultra X7 358H, Linux 7.2.3-arch1-3, x86-64.
- Compiler: LDC 1.43.0, DMD frontend 2.113.0, LLVM 22.1.8.
- Build: repository Ninja release target, `-release -O -flto=thin`.
- CPU affinity: CPU 1 for each benchmark process.
- Six paired batches; three warmups and 30 measured runs per executable
  per batch. This gives 180 measured runs per executable.
- Batch order: before/after, after/before, repeated three times.
- The baseline executable was saved before the source change.
- No builds or tests ran during the paired benchmark measurements.

The benchmark's runtime includes VM construction and bytecode compilation.
Frontend time and GC between rounds are outside that timer. These results
compare two executables on this host; they are not a comparison against the
84 ms baseline from [issue #300]. CPU affinity and the source revision differ.

Commands, run from the worktree root:

```sh
dub run reggae --compiler=ldc -- -b ninja
ninja -j 6 bin/ut bin/bench bin/sb
cp bin/bench bin/bench-before
# Apply the VM change, then rebuild and run checks.
build/ci.sh
taskset -c 1 bin/bench-before rt-perf -b bytecode -w 3 -r 30
taskset -c 1 bin/bench rt-perf -b bytecode -w 3 -r 30
```

## Paired results

All values below are milliseconds. `B` is before, `A` is after, and sigma is
within-batch standard deviation. Values have the benchmark's 0.1 ms display
precision. All runs passed.

| Pair | B min | B median | B sigma | A min | A median | A sigma |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 89.7 | 90.4 | 0.3 | 86.6 | 87.2 | 0.4 |
| 2 | 89.1 | 90.0 | 0.4 | 85.7 | 86.6 | 0.5 |
| 3 | 89.6 | 90.2 | 0.3 | 86.5 | 87.1 | 0.3 |
| 4 | 89.5 | 90.3 | 0.3 | 86.6 | 86.9 | 0.3 |
| 5 | 89.1 | 90.0 | 0.9 | 86.2 | 86.7 | 0.6 |
| 6 | 89.0 | 89.7 | 0.3 | 87.3 | 88.2 | 0.4 |

The median of batch medians is 90.1 ms before and 87.0 ms after:
`(90.1 - 87.0) / 90.1 = 3.44%` less time, or a 1.036x speedup. This is
not a pooled median of all 180 runs. The lowest observed times were 89.0 ms
before and 85.7 ms after.

## Other workloads

Each row is one before/after pair with three warmups and 30 measured runs,
also on CPU 1. These checks have less evidence than the main comparison;
small differences within their variation are not established improvements.
All runs passed.

| Workload | Before median | After median | Before sigma | After sigma |
| --- | ---: | ---: | ---: | ---: |
| rt-simple | 5.5 ms | 5.4 ms | 0.3 ms | 0.3 ms |
| rt-ffi | 25.6 ms | 25.2 ms | 0.2 ms | 0.3 ms |
| rt-cerealed-0 | 5.5 ms | 5.5 ms | 0.3 ms | 0.3 ms |
| ct-easy | 29.3 ms | 27.9 ms | 0.3 ms | 0.4 ms |

A separate run of `rt-perf -b interpreter -b bytecode -w 3 -r 30` was
also made before and after the change, on CPU 1:

| Backend | Before min/median/sigma | After min/median/sigma |
| --- | ---: | ---: |
| bytecode | 89.6 / 90.3 / 0.3 ms | 87.6 / 88.3 / 0.4 ms |
| interpreter | 380.0 / 382.5 / 1.4 ms | 378.3 / 380.5 / 1.7 ms |

All runs passed. These two batches were separated by builds and checks;
the alternating bytecode batches give the main performance estimate.

## Evidence for the removed work

Disassembly of optimized `opCall` has eight calls to `memcpy@plt` before
and seven after. The removed call is the result copy after guest dispatch.
These are static call sites, not the number of copies per guest call.

Separate CPU profiles used this command for each executable:

```sh
perf record -e cpu-clock:u -F 999 --call-graph dwarf,8192 \
  -o before.data -- \
  taskset -c 1 bin/bench-before rt-perf -b bytecode -w 3 -r 30
perf record -e cpu-clock:u -F 999 --call-graph dwarf,8192 \
  -o after.data -- \
  taskset -c 1 bin/bench rt-perf -b bytecode -w 3 -r 30
```

There were 3,001 samples before and 2,933 after, with no lost samples.
The following are flat self-sample counts from the whole benchmark process
and its children. They include startup, frontend work, and GC between
rounds. Stack unwinding was incomplete, so these are not the filtered
backend-only percentages in issue #300. Profile timings are not included
in the paired timing results above.

| Sample location | Before | After |
| --- | ---: | ---: |
| opCall | 950 | 949 |
| opCopy | 249 | 274 |
| opConstant | 175 | 171 |
| opBranchFalse | 160 | 169 |
| FrameStack.reserve | 160 | 152 |
| FrameStack.commit | 159 | 159 |
| memcpy linkage stub | 186 | 112 |
| libc copy code at offsets 0x176400 through 0x1764ff | 316 | 257 |

The sampled copy work decreased. `opCall` remains the largest individual
cost; no new function replaced it as the leading cost. These short profiles
support the intended mechanism but do not give an exact saving per copy.
The libc offsets were checked against disassembly of this host's libc.

## Validation

- Before the change: 390 focused tests passed.
- After the D edit and a Ninja rebuild: the same 390 tests passed across
  the backend matrix.
- Focused modules: `ut.backends.call.nested`, `arrays`, `control_flow`,
  `ref_`, and `func`. These cover recursion, arrays, return widths, reference
  returns, void calls, and cleanup around returns.
- `build/ci.sh` passed: 1,685 unit tests, three acceptance tests, the REPL
  tests, and the configured example benchmarks.
- `git diff --check` passed.

Raw benchmark output, comparison script, JSON batch results, profiles, and
assembly are saved locally in `/tmp/vm-direct-return-results`. The worktree
is `/tmp/snakebite-vm-direct-return`; its `bin/bench-before` is the saved
baseline executable. Build and test logs use `/tmp/vm-direct-return-*.log`.

[issue #300]: https://github.com/atilaneves/snakebite/issues/300
