# Snakebite

Alternative backends for the D programming language that shorten the
edit-to-unittest feedback cycle. One context: executing D code either
by interpreting it or by calling compiled code.

`bin/sb` runs a program the way its compiled `-unittest` build runs,
with the arguments after `--`.

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

**Full expression**:
A guest expression together with the temporary values whose lifetimes end
when that expression finishes. Its result can be read after those temporary
values are destroyed.

**Control transfer**:
A return, break, continue, or goto that changes which guest statement
executes next, after required cleanup. A control transfer from cleanup
replaces the pending one.

**Call selection**:
The decision for one call, with three possible outcomes: run the
callee's own guest body, call its host body across the barrier, or run
snakebite's own builtin wrapper. A compiler intrinsic has no host body
to call; ADR-0013 defines its builtin route and signature contract.

**Intrinsic reference**:
The result of native code that the compiler which built the host gives for
a compiler intrinsic. That is the guest result of the intrinsic. ADR-0013
records the owner's narrow constant-fabs exception for a dmd host.

**Call receiver**:
The object or enclosing context supplied to a callee as its hidden argument.
A direct call obtains it from its receiver expression or its caller; a delegate
carries it with the function value.

**Call arguments**:
The values supplied to a call: hidden context and type information,
declared parameter values or references, and any variadic extra values.

**Call window**:
The memory that a direct call from guest code to a compiled guest function
uses for the callee: `[scratch][activation][parameter slots]`, aligned to at
least 16 bytes. It starts above the frame of the caller; a window opened while
the call arguments evaluate starts above the open one. The caller evaluates
each call argument and the call receiver straight into its slot, so the call
copies no arguments and the return copies no result. Copies remain for
by-value struct arguments, a local passed as an argument, and a call receiver
that was not built in its slot. A **window call** is a call that uses one.
Virtual calls, function pointers, delegates, and callees with a closure,
variadics or page alignment take the general call path.

**Prepared facts**:
Information computed before a guest callback runs, so its execution can use
that information without asking frontend questions or building it on first use.

**Thread state**:
The data one host thread owns while it runs guest code on a backend,
including its copies of thread-local guest variables. Fibers on the same
thread share these variables.
_Avoid_: per-thread evaluator, thread context

**Execution state**:
The evaluator or VM state for guest calls on one native stack. Each Fiber
has its own execution state, separate from the thread's main stack. The
Interpreter's walker runs on the stack that it is entered on, the base. When
the stack is low, the walk continues on a piece, a 1 MiB `Fiber`, and host
calls from a piece run on the base (ADR-0015).

**Halt**:
The end of a run with no more guest code. No `catch`, `finally`,
`scope` guard or destructor sees it, and druntime code that handles every
`Exception` lets it pass. The `Program` owns the actions (`HostActions`),
and the host that makes the program chooses them. `bin/sb` ends the
process. A REPL cell or an in-process test fails and the session goes on.
A failed check under `-checkaction=halt` is a halt.
A `synchronized` block that a halt leaves does not unlock its mutex.
_Avoid_: abort, crash

**Guest fault**:
A hardware fault of the guest that compiled D would die of: a load, a store
or a call through an address that is not mapped (a null pointer included),
and an integer division that the hardware traps. It is not a halt and
nothing recovers from it. A handler for SIGSEGV and SIGFPE writes one line
to standard error (the kind, and the innermost guest function and the line
when the backend knows them), then the default action of the signal ends the
process, as it ends compiled D.
_Avoid_: crash, trap
