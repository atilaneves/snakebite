---
status: accepted
---

# Barrier cost is measured on pinned real projects

The cost of crossing the barrier decides whether snakebite is usable.
It has no absolute budget: the bar is that it stays negligible on real
dub projects. Umbrella #100 decision 5 orders this work by shape
first, then correctness, then performance, and it orders performance
by measurement, not by guessing a number up front. The only gate today
is `barrier.overhead` in `acceptance/at/ffi/cost.d`. It is a micro
benchmark of one call, `abs(int)`, and it asserts a barrier to
baseline ratio under 2.40. The directories under `examples/` do not
stand in for real projects. Only `examples/rt` has a real dub
dependency, and the maintainer rejected it as not representative.

`barrier.overhead` stays. It keeps its 2.40 ratio gate and keeps
running in CI.

A macro benchmark joins it: a suite of real dub projects, each pinned
to a commit. The bench harness fetches each project at its pin. No
project's source is copied into `examples/`. The suite has three
projects. Cerealed gives heavy template and range use over phobos,
with no dependencies of its own. unit-threaded's own test suite gives
nine subpackage archives and a task pool, so it exercises callbacks
and threads. One project that binds a C library gives C variadics and
C callback entries. Each project runs on both backends, with `dub
test` as the oracle for correctness. Each run reports the barrier's
share of total run time as its own row, and image build time
(ADR-0007) as another row.

The first pass over this suite only reports numbers. No macro gate
exists until a first measurement exists. A gate set before a
measurement is a guess.

Per-shape fast paths in the call stub (ADR-0001) are added only when
this suite shows a shape where they matter. No fast path is added on
guesswork ahead of a measurement.

## Considered options

**A percentage gate on the barrier's share of run time from day
one.** Rejected. A gate set before a measurement is a guess. It
either blocks work the guess got wrong, or nobody trusts it and it
gets ignored.

**`examples/rt` as the macro benchmark.** Rejected by the maintainer
as not representative of real dub projects.

## Consequences

The bench harness gains a fetch-and-pin step for each macro project.
A number measured today is comparable with one measured later only
while the pins stay unchanged. Bumping a pin invalidates the
comparison.
