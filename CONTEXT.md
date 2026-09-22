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
declaration takes the builtin outcome instead when dmd's own
`isBuiltin` classifies it as a compiler intrinsic (ADR-0013).

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
