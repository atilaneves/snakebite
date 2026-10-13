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

Fibers can suspend and resume guest calls out of nesting order on one
thread. Each Fiber therefore needs its own execution state within that
thread's state; its active frames must survive while other Fibers run.
Guest thread-local variables remain shared by all Fibers on that thread.

## Considered options

One global lock around every callback entry. Rejected: this
serialises the task pool, the workload that motivates threads in the
first place.

Forbid callbacks from threads a backend never entered. Rejected: this
is not how compiled D behaves.

## Consequences

`synchronized` is not used, per project rule. Locks use `core.sync`
primitives, and only on slow paths. `PerThread` owns the thread-local table,
Fiber keys, thread registration, and state destruction. `ExecutionStates`
owns the lifetime of execution entries for both backends.

An entry guard keeps its execution state active until the guest call returns
or unwinds. Nested entries on one stack share that state. A suspended Fiber
keeps its guard and its own state while another Fiber runs. When the owner
ends, an atomic flag marks the execution states as ended. The owner releases
idle entries on its thread. Active entries stay until their last guard ends;
that thread then releases its idle entries. Later guest finalizers can still
enter the reachable backend, but their completed entries no longer stay until
the thread ends. The ordinary path takes no lock. Guards allocate no memory,
and finalizer state still comes from the scanned C heap.

Guest thread-local variables have a separate lifetime. Live guest objects can
point into their storage after the owner ends. The execution-state module
calls the backend's idle cleanup only when no execution entry remains on the
calling thread. That cleanup releases an empty guest TLS table, including one
that a late finalizer made, but retains a table with variables. This also
keeps an empty table valid while an active VM or evaluator holds its address.

The original change, commit `332c8d3e`, released state when the owner ended
but kept state made by later finalizers until the thread ended. Historical
measurements after 3000 REPL cells that each left an object with a guest
destructor found 967 bytecode frame stacks (409 MiB resident, against 262 MiB
without the destructor) and 2550 interpreter states (1435 MiB, against
257 MiB). These were one run each, before the entry lifetime protocol. They
identify retained execution state as a reducible cost; they are not a current
benchmark of this decision. Backend reachability, late finalizers, guest TLS
pointers, nested entries, Fiber isolation, prepared callback facts, GC root
scanning, and native layout remain required.

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
