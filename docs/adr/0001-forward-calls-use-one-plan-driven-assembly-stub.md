---
status: accepted
---

# Forward calls use one plan-driven assembly stub

Guest code calls host functions across the barrier. Issue #100 asked
for a chosen mechanism for this call. Issue #97 raced two candidates:
the cached arity dispatcher already in `source/snakebite/ffi/abi.d`
(D template dispatch tables over integer and float register counts,
one plan cached per call site) against libffi. Measured on a warm
`abs(int)` call:

| Mechanism               | Time (ns) | Ratio to direct call |
|--------------------------|-----------|-----------------------|
| Direct indirect call     | 2.56      | 1.0x                  |
| Cached arity dispatcher  | 4.11      | 1.6x                  |
| libffi, eager resolve    | 47.04     | 18.4x                 |
| libffi, deferred resolve | 47.07     | 18.4x                 |

libffi passed the exception gate but lost on speed. The dispatcher was
already production code, so issue #169 needed only this record.

The barrier now uses no third-party FFI library. Every forward call
goes through one mechanism: a hand-written assembly call stub, in a
`.S` file, for System V AMD64 on Linux only for now. The build
assembles the stub through reggae. The cached plan holds the
precomputed register moves and stack layout. The stub replays them at
call time.

The stub replaces the D template dispatch tables and the special-cased
`int(int)` fast path in `CallPlan.FastPath`. It also covers cases the
template path had to refuse: MEMORY-class parameters (aggregates over
16 bytes), a mixed INTEGER/SSE aggregate when both register files
spill, and variadic callees (the stub sets `AL` to the SSE register
count). The stub carries CFI directives, so exceptions unwind through
it (see ADR-0004).

The acceptance test `barrier.overhead`, in `acceptance/at/ffi/cost.d`,
checks the barrier cost against a direct call. The ratio must stay
under 2.40. The stub must meet this bound before it replaces the
dispatcher. The gate runs on the optimised acceptance build
`bin/at-release`; the unoptimised `bin/at` prints the same numbers
without gating.

The seam stays ABI-agnostic. Any other platform fails loudly.

## Considered options

- **Keep the template tables for register-only shapes, add the stub
  only for the long tail.** Rejected: two code paths to test, two
  places to hold unwind info, for no measured gain.
- **libffi.** Rejected: 18 times slower than a direct call in the #97
  race. Its 2026 call plan API reports 2.7x in its maintainer's own
  measurement, still behind the dispatcher's 1.6x, and it adds an
  external dependency.
- **dyncall.** Rejected: dyncall has no reusable plan. It pushes
  arguments on every call.

## Consequences

The D compiler no longer generates call code for the barrier. The
build gains an assembler step. Per-shape special cases are added only
when profiling on real projects shows a need (ADR-0011).

## Supersedes

The open work item in #169. The mechanism was already integrated;
this ADR is its record.
