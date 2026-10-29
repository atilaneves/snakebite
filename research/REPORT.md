# Counted bytecode compile buffers

GPT-6.1 Sol, 2026-10-29. Local experiment. No push or PR.

## Result

This experiment reduced bytecode compile time by **12.2-14.2%** on five
projects. Separate CLI runs confirmed **12.2-13.2%** on the three primary
projects. Thus 3-8% is not a limit for this base.

This is not a 12-14% reduction in the full edit cycle. The benchmark's
backend latency fell by 3.4-5.6%. Frontend time is outside this change.
No native comparison was made.

The cost is more GC storage and copying during buffer growth. Peak process
RSS rose by up to 60.7 MiB, or 2.6%. See the memory limits below. Recommend
this small change for independent code review, with its memory cost stated.
Do not expand the buffer design to seek another gain in this experiment.

## Exact code and base

- Worktree: `.worktrees/bc-compile-buffers`.
- Branch: `bc-compile-buffers`.
- Baseline: `d02fd1f720e0d0d23e2a04cdd988d081f177d326`.
- First implementation: `af5ceb64`.
- Measured final code: `62e31af0`.
- Only production file changed:
  `source/snakebite/backends/bytecode/compiler.d`.
- Final production diff: 31 added lines and 9 removed lines.

`FunctionCompiler.CompileBuffer(T)` holds a GC-allocated capacity array and
a used slice. Append checks the used count against the stored capacity.
It starts at four elements, doubles when full, copies the used elements,
and then stores the new element. Growth checks for count and byte-size
overflow. Normal append does not call the D array capacity machinery.

The eight changed fields are `_instructions`, `_callSites`, `_allocations`,
`_exposedFrames`, `_deferredBindings`, `_operandTemps`, `_tempStarts`, and
`_tempSizes`. Existing array indexing, iteration, slicing, pointer access,
and duplication use the used slice through `alias this`. `assumeSorted`
needs an explicit `.data` because its template otherwise keeps the builder
type. No call argument arrays, frame-layout arrays, constants, exception
handlers, or other compiler buffers were changed.

This scope follows the fresh report: instructions alone had only a 3-4%
sample share. Call sites and temporary/frame metadata give a larger target
without changing layout, compilation order, inlining, or the VM.

## Original problem and required guarantees

Read the fresh research report, the compile-cost handoff, repo coding and
domain instructions, ADRs 0003, 0006, 0011 and frontend-arena 0015, the
saved #862 compile-cost comments, and the recorded introducing history.
Loaded `performance-patterns` and read the unlisted `linux-perf` skill at
`/home/atila/dotfiles/.agents/skills/linux-perf/SKILL.md`, including flow B
and the collection instructions.

Commit `31e401af` made function placeholders stable so recursive call sites
can refer to a function before its body is complete. The output arrays
also need persistent GC ownership. History does not require ordinary D
array append to construct them. Commit `66e8c7bc` requires the existing
single compiler-lock order. Commit `bd4679bf` and ADRs 0003/0006 require
complete callback preparation before an entry can reach a GC finalizer.

The change keeps these guarantees:

- Each active compiler owns separate capacity, including nested compiles.
- A published array is never returned to a pool or reused by another
  compile. The `Function` still holds ordinary GC-owned array slices.
- Branch and handler pointers are resolved after buffer growth and code
  compaction, as before. Stable `Function*` placeholders are unchanged.
- Typed `new T[]` keeps normal GC scanning. There is no arena allocation,
  custom allocator, manual free, finalizer, or new lock.
- Callback preparation, bytecode passes, native layout, and inlining
  decisions are unchanged. Finalizers never compile.

The baseline sample union of allocation and append work was evidence for
the target, not a forecast of the time that could be removed.

## Release benchmark

Used the existing `bin/bench -b bytecode -w 1 -r 5`, through the unchanged
shared `pinrun`. Built both release variants in this worktree. Kept the
baseline binaries before editing D. All builds used load-aware job counts.

The baseline was measured before the first candidate and again after the
final candidate. Baseline compile medians differed by at most 1.2%, below
the 5% repeat threshold. The table uses the second, adjacent baseline.
Each cell is the median of five measured rounds after one warm-up.

| Project | Base compile, ms | Final compile, ms | Reduction |
|---|---:|---:|---:|
| tardy 0.0.3 | 54.9 | 47.1 | 14.2% |
| automem 0.6.11 | 98.3 | 85.3 | 13.2% |
| argparse 2.1.0 | 466.7 | 405.0 | 13.2% |
| dxml 0.4.5 | 1627.9 | 1429.2 | 12.2% |
| dub 1.42.0 | 1531.4 | 1317.6 | 14.0% |

All five guest test runs passed. The final/base compile standard deviations
were 0.8/0.9, 1.2/1.2, 3.9/2.9, 13.0/13.1, and 12.9/19.0 ms, in table
order. The first baseline medians were 54.3, 98.2, 468.0, 1630.9, and
1521.9 ms. The first doubling candidate, before the overflow guard, gave
47.9, 84.3, 409.8, 1418.1, and 1323.2 ms.

The benchmark uses a repeated, collected heap. A second check used separate
release `bin/sb` processes, with alternating base/final runs. Each variant
had one warm-up and five accepted measured runs:

| Project | Base median (range), ms | Final median (range), ms | Reduction |
|---|---:|---:|---:|
| tardy | 56.9 (55.5-57.9) | 49.4 (48.6-51.1) | 13.2% |
| automem | 99.8 (95.4-103.4) | 87.3 (84.7-89.7) | 12.5% |
| argparse | 487.8 (469.3-503.6) | 428.4 (412.1-432.9) | 12.2% |

These are the CLI `compile:` values, not full process times.

## Accepted-run audit

- All benchmark blocks were accepted: both busy readings were below 5%.
  For the final comparison, other-busy was at most 1.0% and sibling-busy
  was at most 0.5%. Each block contains five measured compile rounds.
- Of 31 measured CLI processes, 30 were accepted. The rejected run was
  `cli-candidate-tardy-2.log`, with sibling-busy 16.3%. Its replacement was
  `cli-candidate-tardy-retry.log`. Accepted CLI maxima were other-busy 3.1%
  and sibling-busy 3.2%. No rejected time enters the table.
- All 18 profile runs were accepted: other-busy at most 1.5%, sibling-busy
  at most 2.7%. Every recording has zero `PERF_RECORD_LOST` records.
- The first baseline AWFY Storage and Towers rows had sibling-busy 7.7%
  and 17.8%. Repeated both with the existing tool. Replacement maxima were
  0.3% and 0.8%. The accepted AWFY maximum was 2.4%.
- `awfy-count` retains only its maximum sibling reading, not other-busy.
  Its instruction and bytecode counts are not timing evidence. No AWFY
  time or speedup is claimed.

## Profile check

Used the research baseline's unchanged `bin/sb-prof`, copied into this
worktree, and this worktree's final `bin/sb-prof`. Both have release flags,
frame pointers, and debug line tables. `readelf` confirmed debug sections.
No permission or kernel setting was changed.

Each project/variant had a warm-up and three recordings:

```sh
$T/pinrun perf record -e cycles:u --call-graph fp --user-callchains \
  -F 20000 -o experiment/profiles/NAME.data -- \
  timeout 180 SB_PROF -b bytecode PACKAGE
```

The kernel limited the requested 20 kHz rate to **8 kHz**. The logs and
recording headers show this limit. Used the research report's existing
reducers, copied without change, to include LTO inline append frames.

Shares below use cycle periods, pooled across three runs. The denominator
is samples whose stack identifies real bytecode compilation. These are
conditional sample shares, not phase timers or achievable time savings.

| Project | Base/final samples | Append share, base/final | Union, base/final |
|---|---:|---:|---:|
| tardy | 1117 / 1118 | 13.4% / 4.1% | 23.4% / 17.0% |
| automem | 1962 / 1919 | 12.3% / 4.0% | 20.1% / 13.7% |
| argparse | 8142 / 7937 | 14.9% / 6.4% | 22.2% / 16.2% |

The union includes GC/array self work and append paths, without double
counting. `Instruction[]`, `CallSite[]`, and `FrameRange[]` append frames
are absent from the final compile samples. Integer append shares fell from
2.4-2.9% to 0.4-0.5%; other integer arrays remain outside this scope.
Allocation, initialization, copying, and unrelated appends still cost time.
The profile supports the mechanism; release timings establish the gain.

## Memory and failed growth adjustment

The benchmark measures peak RSS in a fresh process, including the frontend:

| Project | Base RSS, MiB | Final RSS, MiB | Change |
|---|---:|---:|---:|
| tardy | 438.8 | 438.7 | -0.1 MiB |
| automem | 516.4 | 517.7 | +1.3 MiB |
| argparse | 1467.6 | 1489.1 | +21.5 MiB |
| dxml | 2324.3 | 2385.0 | +60.7 MiB |
| dub | 4008.5 | 4027.1 | +18.6 MiB |

Separate `--DRT-gcopt=profile:1` runs reported peak GC pool sizes of
92/92, 92/92, 145/176, 532/532, and 426/478 MiB, base/final in table order.
These are one-run pool peaks, not live retained heap or total allocated
bytes. They vary: an earlier baseline tardy run reported 70 MiB. A dxml
run also showed more GC time in the final process, 190 versus 101 ms.
Do not treat those one-run GC times as a stable phase measurement.

After the first Jev baseline, tested 1.5x growth to reduce spare capacity.
It kept the compile gain but did not improve measured memory. In particular,
dxml RSS rose to 2407.6 MiB, worse than doubling at 2385.0 MiB. Restored
doubling and kept the overflow guard. Did not try more growth variants.

Each growth allocates a new initialized array and copies the used prefix;
it does not extend a GC block in place. With final capacity C, full doubling
growth copies C-4 old elements and allocates 2C-4 element slots, before GC
rounding. This is a code-derived bound, not measured byte traffic. Total
allocated bytes, copy volume, and live retained heap were not measured:
the existing tools used here do not report those values. No new probe or
benchmark harness was added. The measured RSS increase is a real limit on
the recommendation, not evidence that memory is free.

## Validation

- Built `bin/ut` after every D edit. The first edit failed to build because
  `assumeSorted` kept the builder type; fixed with `.data`. Every edit that
  built then passed the focused 87-test exception/basic check.
- Final `bin/ut @Bytecode`: 6 forced-finalizer tests, then 2481 tests,
  all passed. Covers recursion, exceptions, closures, callbacks, and GC.
- Final `bin/ut ut.backends.bytecode ut.repl`: 97 tests passed.
- Final `bin/ut --lowmem @Bytecode`: 6 plus 2481 tests passed.
- An early explicit test-list run selected a hidden child-only internal
  failure fixture and ended as designed. The normal tag/package runs
  above exclude those fixtures. This was not a guest regression.
- All five corpus projects passed on both release variants.
- All 14 AWFY benchmarks passed and had exactly equal bytecodes per outer
  iteration. Host instruction differences were below 0.4%, not a gain.
- `git diff --check` passed. No new behaviour tests were added.
- Jev baseline, growth/guard review, and final review completed. Final
  correctness was 8.4 and performance 8.8. No further code change was
  justified by a concrete weak metric. Scores do not replace validation.

| AWFY benchmark | Base = final bytecodes per iteration |
|---|---:|
| Bounce | 115818042 |
| CD | 239499315 |
| DeltaBlue | 74384939 |
| Havlak | 263950265 |
| Json | 157075642 |
| List | 191088042 |
| Mandelbrot | 112708019 |
| NBody | 131250610 |
| Permute | 158669042 |
| Queens | 127550042 |
| Richards | 546975642 |
| Sieve | 259176042 |
| Storage | 135252042 |
| Towers | 201748842 |

This checks executed bytecode counts, not a byte-for-byte dump of all
compiled instruction operands. The experiment does not establish results
for other projects, low-memory performance, or other machine types.

## Reproduction and retained evidence

All artifacts are in this worktree's `experiment/`. `measurements.json`
contains the audited timing inputs and selected AWFY rows. Logs preserve
the rejected runs. `binaries.sha256` identifies both variants. Release
binaries are in `base/bin` and `candidate/bin`; the failed smaller-growth
binaries remain in `compact/bin`. The initial doubling variant is in
`doubling/bin`.

`profiles/` retains all 18 recordings, build-independent summaries,
symbols, reducers, run logs, and lost-record checks. Removed only this
experiment's large derived stack text after reducing it; the saved data
can reproduce that text. Build logs and Jev follow-up results remain too.

```sh
T=/home/atila/coding/d/snakebite/.worktrees/tools
export TMPDIR=$PWD/experiment/tmp
j=$(( $(nproc) - $(cut -d. -f1 /proc/loadavg) ))
[ "$j" -lt 1 ] && j=1
ninja -j$j -l$(nproc) bin/ut bin/sb bin/bench bin/sb-count bin/sb-prof
$T/pinrun timeout 900 bin/ut @Bytecode
$T/pinrun timeout 360 experiment/base/bin/bench \
  -b bytecode -w 1 -r 5 argparse@2.1.0
$T/pinrun timeout 360 bin/bench -b bytecode -w 1 -r 5 argparse@2.1.0
$T/awfy-count bin/sb-count bytecode "$PWD/experiment/awfy-candidate"
```

Other worktrees, shared tools, `sbc-*`, frontend arena, JIT, and runtime VM
were not changed. All work is local. No CI run, push, or PR was requested.
