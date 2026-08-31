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
The per-function description, computed once and then reused, of how a
call crosses the barrier.
_Avoid_: call descriptor, thunk

**Resolver**:
The single component that turns a mangled symbol name into a host
address.
_Avoid_: symbol lookup, loader
