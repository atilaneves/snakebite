---
status: accepted
---

# Host threads enter guest code through thread-local state

Host code, such as unit-threaded's task pool, calls guest delegates
from threads a backend never entered before (#40). The evaluator and
the frame stack are per-context state, and they are not thread-safe.
The interim workaround forces unit-threaded's single-threaded flag.
#35 and #40 call this a restriction, not a solution. Callbacks must
work from any thread, the same as they do for compiled D.

Every backend keeps its mutable execution state, such as the
evaluator, the frame stack, and per-thread caches, in thread-local
state. This state is created the first time a thread enters guest
code with none. Program-wide structures, such as the plan cache, the
callback pool (ADR-0003), and the resolver, are either immutable once
built, or guarded by a lock on their slow path only. Their fast path
takes no lock. A thread druntime does not know about is attached on
its first entry, so the GC can scan its stack (ADR-0005). The first
test of this decision is unit-threaded's task pool running without
the single-threaded flag. Guest code creating its own threads is the
other half of #40, and is separate work that this seam makes
possible.

## Considered options

One global lock around every callback entry. Rejected: this
serialises the task pool, the workload that motivates threads in the
first place.

Forbid callbacks from threads a backend never entered. Rejected: this
is not how compiled D behaves.

## Consequences

`synchronized` is not used, per project rule. Locks use `core.sync`
primitives, and only on slow paths. Each backend must release a
thread's state when the thread ends.
