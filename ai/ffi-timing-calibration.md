# FFI timing limit calibration

The fixed limit in `acceptance/at/ffi/cost.d` is 2.40 times a direct call.
It is based on independent process runs of known-good revision `49bf03a`,
not on a candidate's own variation. The previous 2.25 limit rejected all
40 calibration processes, including their existing flaky-test retries.

The calibration changed only the printed ratio precision from one to six
fractional digits. The benchmark loops and old assertion were unchanged.
Each process computes five ratios and reports their median. We took only
the first reported median per process: later retries must not select more
favorable calibration values. All 40 first attempts are included below.

Environment: Linux x86-64, AMD Ryzen Threadripper 1950X, DMD 2.113.0,
unoptimized acceptance build from the standard Ninja configuration.
Processes ran sequentially with normal CPU affinity. Other local profiling
batches were excluded with `/tmp/snakebite-profile-timing.lock`.

| Calibration statistic | Value |
| --- | ---: |
| Independent processes | 40 |
| Mean ratio | 2.322602 |
| Sample standard deviation (n - 1) | 0.024874 |
| Mean + 3 standard deviations | 2.397224 |
| Rounded up to the next 0.05 | 2.40 |
| Minimum | 2.293119 |
| Maximum | 2.452977 |

This is an empirical noise margin, not a statistical guarantee. One first
attempt exceeded mean + 3 standard deviations. A single host cannot
establish the distribution for every CPU or compiler. Keep the existing
retry policy for occasional outliers. Do not recalculate the threshold
from the revision under test: a slower or noisier candidate must not raise
its own limit.

After fixing the limit, a separate 40-process validation batch passed on
every first attempt. Its mean was 2.326082, sample standard deviation
0.021088, and range 2.295857 to 2.389312. No validation sample was used to
choose or adjust the limit. Runtime output still reports the median ratio,
now with enough precision to inspect small changes.

To repeat the experiment, build `bin/ut` and `bin/at` through Ninja and run
`bin/at -d -s at.ffi.cost.barrier.overhead` in 40 fresh processes. Capture
the first `ratio` line from each process, including failed processes. For
those 40 medians, use Python `statistics.mean` and `statistics.stdev`.
Round `mean + 3 * stdev` upward to a multiple of 0.05. Recalibration needs
an independently selected known-good revision, then a fresh validation
batch. Never silently update the bound during CI.

## First-attempt ratios

| Process | Calibration | Validation |
| --- | ---: | ---: |
| 1 | 2.319338 | 2.366689 |
| 2 | 2.322050 | 2.319714 |
| 3 | 2.326252 | 2.323983 |
| 4 | 2.325044 | 2.321253 |
| 5 | 2.452977 | 2.314085 |
| 6 | 2.357835 | 2.331511 |
| 7 | 2.298416 | 2.310035 |
| 8 | 2.321910 | 2.307765 |
| 9 | 2.315007 | 2.314867 |
| 10 | 2.309031 | 2.300419 |
| 11 | 2.328625 | 2.306725 |
| 12 | 2.312702 | 2.333405 |
| 13 | 2.317011 | 2.320728 |
| 14 | 2.317820 | 2.333376 |
| 15 | 2.321240 | 2.310374 |
| 16 | 2.331290 | 2.317575 |
| 17 | 2.309968 | 2.323137 |
| 18 | 2.293119 | 2.320010 |
| 19 | 2.307650 | 2.314637 |
| 20 | 2.310389 | 2.323611 |
| 21 | 2.313525 | 2.389312 |
| 22 | 2.309120 | 2.323213 |
| 23 | 2.309730 | 2.309545 |
| 24 | 2.311857 | 2.346971 |
| 25 | 2.343334 | 2.316444 |
| 26 | 2.319770 | 2.317638 |
| 27 | 2.319620 | 2.314019 |
| 28 | 2.314656 | 2.344920 |
| 29 | 2.320915 | 2.306515 |
| 30 | 2.348047 | 2.302706 |
| 31 | 2.316685 | 2.351177 |
| 32 | 2.306953 | 2.386456 |
| 33 | 2.300604 | 2.336193 |
| 34 | 2.303967 | 2.361626 |
| 35 | 2.335590 | 2.314921 |
| 36 | 2.312516 | 2.334240 |
| 37 | 2.325926 | 2.326932 |
| 38 | 2.328358 | 2.323624 |
| 39 | 2.328503 | 2.327079 |
| 40 | 2.336736 | 2.295857 |
