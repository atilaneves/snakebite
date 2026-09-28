# Bytecode property-test latency after #449

The workload is Cerealed at
`3340ea8b1881588c30f7f363f3dec0d5d13ec372`. Both binaries use the normal
release build from `build/reggae.sh` and `ninja bin/sb`.

## Method

Run the binaries from the same working directory with a warm dependency
image. Alternate baseline/candidate and candidate/baseline order. Run one
measurement at a time, with no builds or other tests from this task running
beside it.

Property tests, pinned to CPU 1:

```sh
taskset -c 1 bin/sb /home/atila/coding/d/cerealed -- -s tests.property
```

Full suite, with its normal worker count:

```sh
bin/sb /home/atila/coding/d/cerealed
```

Record process wall time, unit-threaded test time, and reported bytecode
compile time. Compare each adjacent pair as well as the medians. Host load
changed during these measurements, so separate medians can be misleading.
For example, the first full-suite comparison crossed a load increase
between the baseline and candidate in one pair. Four of its five pairs
favoured the candidate, but the separate medians favoured the baseline.
The follow-up full-suite comparison used seven pairs.

These figures are local measurements, not a new CI performance threshold.
ADR-0011 still applies.

## Experiments

Test times below are medians in seconds. Each row names its own baseline;
the percentages must not be added together.

| Change | Baseline | Before | After | Decision |
| --- | --- | ---: | ---: | --- |
| Power-of-two alignment | #449 | 2.846 | 2.706 | Keep |
| Call frames and alignment | #449 | 2.883 | 2.779 | Keep |
| Local dispatch state | Call frames | 2.787 | 2.610 | Keep |
| Metadata accessors | Dispatch | 2.576 | 2.517 | Remove |
| Return fusion | Dispatch | 2.593 | 2.502 | Keep |

Each isolated comparison used three pairs, except the combined allocation
comparison, which used five. The combined reservation was not measured
separately from the alignment change.

Call frames use one reservation for the activation and values, and fill
activation fields without clearing them first. The metadata accessor
experiment did not give a consistent reduction across pairs.

The dispatch change removes a repeated store/load of the instruction
pointer. Moving exception unwinding out of the loop also prevents cleanup
delegates from capturing the loop's activation pointer. The release
assembly keeps both pointers in registers on the normal path.

Return fusion still performs the producer's write. The separate return
instruction remains available as a branch target. A cleanup range that
ends before the return still stops at that boundary.

## Comparison with #449

Five pairs compared `1c0d5c8d` with the retained changes before rebasing.
All 21 property tests and all 156 full-suite tests passed in every run.

| Workload | Test-time reduction | Wall-time reduction |
| --- | ---: | ---: |
| Property tests | 14.0% | 10.3% |
| Full suite | 11.5% | 5.4% |

The property test-time reductions ranged from 11.1% to 28.9%; full-suite
reductions ranged from 5.3% to 13.9%. This variation is why the final
comparison is repeated against the latest master after rebasing.

## Final comparison

The final baseline is master `49c34258`. The candidate is `2d057ffe`, with
the same production changes rebased onto that master. Each workload used
five alternating pairs after warm-up runs. Every run passed.

| Workload | Measurement | Master | Candidate |
| --- | --- | ---: | ---: |
| Property | Test time | 3.102 s | 2.632 s |
| Property | Process wall time | 4.295 s | 3.790 s |
| Property | Bytecode compile time | 91.1 ms | 93.1 ms |
| Full suite | Test time | 1.232 s | 1.066 s |
| Full suite | Process wall time | 2.242 s | 2.070 s |
| Full suite | Bytecode compile time | 80.9 ms | 81.1 ms |

The table contains separate medians. The median reductions within pairs
were 15.4% for property test time and 13.6% for full-suite test time. All
ten test-time pairs improved. Process wall time improved by a median of
13.0% and 7.7% within pairs. One property pair had a 3.7% wall-time increase
as startup and compile time varied; the other nine wall-time pairs
improved.

Bytecode compile time did not show a consistent change. These numbers
measure guest bytecode compilation, not the build of snakebite itself.

`build/ci.sh` passed after rebasing: 3,930 unit tests, acceptance tests,
REPL checks, the example, and benchmark checks. The new alignment test ran
on the full backend matrix first. Only CTFE was omitted after it failed to
convert a local variable's address to an integer.
