---
status: accepted
---

# Frontend memory uses an arena by default

DMD retains syntax trees and other compiler state for the life of the
process. Snakebite allocates that state from an arena by default, while
host and guest allocations continue to use druntime's conservative GC.
This keeps retained frontend state out of repeated GC scans.

The [original change][origin] records the problem: parsing `import std;`
in `sb-repl` put the syntax tree on the GC heap. Six collections during
frontend work, and another at exit, scanned that retained data. DMD's
normal allocation policy uses memory that it does not free or scan.
Snakebite needs that allocation lifetime while running guest D in the
same process, with ordinary collection and finalizer behavior.

## Decision

The process GC is a proxy around druntime's conservative collector. In
the default mode, allocations from a thread executing DMD code inside
the frontend boundary go to the arena. Allocations from other threads,
and from the same thread outside that boundary, go to the collector.
Holding the frontend lock alone does not select arena allocation.

Arena storage remains allocated until the process ends. The collector
does not scan it. Host code can retain references to frontend objects
without registering the arena as a GC root range.

The ownership rule is: **arena memory must never be the only reference
to a GC allocation**. Otherwise the collector can free an object that
DMD still uses. Calls that can create or change frontend objects must
enter through the frontend boundary. Host input arrays are copied into
frontend memory so DMD cannot retain their GC storage. Host allocations
and exceptions that leave the boundary must obey the same ownership rule.

Guest values retain native D layout. Druntime owns guest collection and
finalization. The GC roots, thread registration, and shared druntime
requirements in ADR-0005, ADR-0006, and ADR-0008 still apply.

## Considered options

**Allocate frontend state through the GC.** This remains supported through
`--lowmem`, like DMD's `-lowmem`. It permits collection of frontend data
that is no longer reachable, at the cost of scanning retained frontend
state. It is an explicit alternative to the default arena policy. Select
the mode before frontend allocation starts, so one run has a consistent
allocation policy.

**Disable collection for the whole process.** This would also affect host
and guest allocations and their automatic collection. DMD's compiler
process can choose that policy; Snakebite must preserve guest runtime
behavior. Disabling automatic collection is not the same as preventing
an explicit `GC.collect` call.

**Register the arena as a GC root range.** This would keep GC objects
referenced by the arena alive, but would require the collector to scan
the retained frontend state again. Copying inputs and enforcing the
ownership rule avoid that cost.

## Consequences

Default frontend memory use can grow for the life of the process.
Resetting compiler state does not reclaim arena storage. Changing this
lifetime requires a new ownership design for retained frontend objects.

Debug checks detect DMD objects allocated outside the frontend boundary.
The arena report conservatively checks for words that point into GC
blocks. It does not prove whether another owner also holds each block.
The tests must detect a deliberately stored GC pointer and cover real
frontend work, host library caches, qualified types, and CTFE arrays.
They must also exclude false reports from `NO_SCAN` storage and recorded
frontend stack addresses. See the [memory tests][tests] and the
[pointer-free storage regression][pointer-free].

By default, tests are unit tests in `bin/ut` and run in parallel.
Arena ownership validation runs in the separate debug binary `bin/arena`.
Its scans need stable arena contents and hold the frontend lock. Repeated
scans add serial work whose cost grows with all frontend memory retained
by the process. Some checks deliberately store GC pointers or force
collection. Keeping this work in a separate process removes it from the
parallel unit-test feedback loop.

`bin/arena` first runs the memory checks on one worker, before unrelated
tests enlarge the arena. It then runs the ordinary test corpus on one
worker and checks the complete arena for ownership violations. This
covers retained state from varied frontend operations. CI runs this
validation separately. `bin/ut` has no arena-check option.

The ownership checks are required. Their current repetition and scheduling
are implementation choices. Performance changes must preserve detection
of real ownership violations and the tests for false reports. A check
limited to new allocations must also account for changes to older arena
objects, which can acquire a GC pointer after an earlier check.

The allocation boundary is implemented in [the compiler][compiler]. The
[GC proxy][gc] selects the allocator and implements the arena report.

[origin]: https://github.com/atilaneves/snakebite/commit/b590f528
[pointer-free]: https://github.com/atilaneves/snakebite/issues/571
[tests]: ../../validation/arena/memory.d
[compiler]: ../../source/snakebite/frontend/compiler.d
[gc]: ../../source/snakebite/gc.d
