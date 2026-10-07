# Snakebite

Alternative backends for the D programming language that shorten the
edit-to-unittest feedback cycle. One context: executing D code either
by interpreting it or by calling compiled code.

## Language

**Backend**:
A component that executes guest functions: the tree-walking
interpreter, the bytecode VM, or the CTFE fallback.
_Avoid_: engine, runtime

**Guest**:
The D code snakebite executes itself, and the values it creates.
_Avoid_: interpreted code, user code, script

**Host**:
The snakebite process and the compiled code linked into it, druntime
included.
_Avoid_: native side, runtime

**Barrier**:
The boundary between guest and host code. A call that crosses the
barrier in either direction is an FFI call.
_Avoid_: FFI boundary, bridge

**Root-owned**:
A declaration whose source belongs to the modules snakebite was asked
to run. Root-owned functions are executed by a backend; functions that
are not root-owned are called across the barrier.

**Native layout**:
The memory representation compiled D uses. Guest values always use
native layout, so crossing the barrier never copies or converts.
_Avoid_: marshalling, boxing

**Plan**:
The description, computed once and then reused, of how a call crosses
the barrier: per function for an ordinary call, per call site for a
C-variadic call, whose own extra arguments shape the plan too.
_Avoid_: call descriptor, thunk

**Resolver**:
The single component that turns a mangled symbol name into a host
address.
_Avoid_: symbol lookup, loader

**Control transfer**:
A return, break, continue, or goto that changes which guest statement
executes next, after required cleanup. A control transfer from cleanup
replaces the pending one.

**Call selection**:
The decision for one call, with three possible outcomes: run the
callee's own guest body, call its host body across the barrier, or run
snakebite's own builtin wrapper. Root ownership and the call's
requirements choose between the guest and barrier outcomes. A bodiless
declaration takes the builtin outcome instead when it is a compiler
intrinsic: one that dmd's `isBuiltin` classifies, or one of `core.math`,
`core.volatile` and `core.simd` that dmd's code generator inlines
(ADR-0013).

**Call arguments**:
The values supplied to a call: hidden context and type information,
declared parameter values or references, and any variadic extra values.

**Thread state**:
The data one host thread owns while it runs guest code on a backend,
including its copies of thread-local guest variables. Fibers on the same
thread share these variables.
_Avoid_: per-thread evaluator, thread context

**Execution state**:
The evaluator or VM state for guest calls on one native stack. Each Fiber
has its own execution state, separate from the thread's main stack.

**Halt**:
The end of a run with no more guest code. No `catch`, `finally`,
`scope` guard or destructor sees it, and druntime code that handles every
`Exception` lets it pass. The `Program` owns the actions (`HostActions`),
and the host that makes the program chooses them. `bin/sb` ends the
process. A REPL cell or an in-process test fails and the session goes on.
A failed check under `-checkaction=halt` and a guest fault are halts.
A `synchronized` block that a halt leaves does not unlock its mutex.
_Avoid_: abort, crash

**Guest fault**:
A halt for a hardware fault that compiled D would die of: a load, a store
or a call through an address that is not mapped (a null pointer included),
and an integer division that the hardware traps. The kind and the message
say what the hardware reported. The fault action of the `Program` prints
the message and the guest call stack (`bin/sb`) or throws a
`GuestFaultException` (a session). A guest fault in a destructor that the
garbage collector runs is not recoverable: for each host and each backend,
the process prints the report and ends with status 1, and no exception goes
through the collector.
_Avoid_: crash, trap
