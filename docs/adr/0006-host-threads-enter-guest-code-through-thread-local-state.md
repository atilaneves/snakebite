---
status: accepted
---

# Host threads enter guest code through thread-local state

Host code, such as unit-threaded's task pool, calls guest delegates
from threads a backend never entered before (#40). The evaluator and
the frame stack are per-context state, and they are not thread-safe.
Before this decision, the interim workaround was to force
unit-threaded's single-threaded flag; #35 and #40 call that a
restriction, not a solution. Callbacks must work from any thread, the
same as they do for compiled D. `runMain` (`backends/backend.d`)
passes the host's own arguments unchanged - nothing in this project
appends the single-threaded flag any more.

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

Automatic attach inherits druntime's own attach race (issue #40
review, finding 3): `thread_attachThis` allocates a `Thread` object
before the thread is registered, and a collection that runs in that
window can free it. Compiled D opens this window only where the
programmer wrote `thread_attachThis` by hand; a backend that attaches
a foreign thread by itself, on every such thread's first entry, opens
it far more often. The race is druntime's, not this project's - it
also reproduces through a bare `pthread` making the same two calls,
with no backend involved - so it is reported upstream rather than
worked around here.

## Known limitation

`thread_attachThis` allocates its `Thread` object, then registers it.
Between those two steps, druntime does not yet know the attaching
thread exists, so a `GC.collect` that runs on another thread in that
window does not suspend it or scan its stack. The new `Thread` object
has no other root, so the collect frees it, and the attaching thread
crashes on its own next use of it.

This reproduces in plain compiled D, with no snakebite code on the
stack: a bare `pthread` that calls `thread_attachThis` by hand, beside
another thread that calls `GC.collect`, crashes the same way. It is a
druntime bug, not a bug in this project.

unit-threaded's parallel task pool runs many unittest bodies at the
same time, so an explicit `GC.collect` one test starts can land inside
the attach window a wholly different, concurrently running test just
opened. Running the thread and frame stack tests together used to
fail about a third of the time this way (crashes, hangs, and wrong
values, all traced to this one window). The fix does not close the
window - only druntime can do that - it keeps every explicit collect
in this test binary from ever running while any thread's attach is
open, and keeps a new attach from opening while a collect is running,
through `tests/ut/threadsync.d`. Each foreign-thread test signals once
its own attach is done, before it allocates anything; each explicit
collect waits out any open attach first. This avoids the window
rather than masking it: the tests still prove a guest allocation on a
foreign thread survives a collection started from another thread, not
that the collection was skipped.
