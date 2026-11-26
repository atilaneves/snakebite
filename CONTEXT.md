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

**Defined elsewhere**:
A declaration that the compile of the **Root modules** does not define: one
with no body or an `extern` one, and each declaration of a
dependency module that its archive defines. A call to it crosses the barrier,
except in a compile to a file: there it is a call to its name, which the
program connects to the bytecode of an **SBC file** that defines the name,
else to native code, when the program is made ready to run. A missing symbol
for it is an error when code that uses it runs, not when the program is made
ready to run, where the link of a native build fails (ADR-0017). Compare
**Definition**.

**Definition**:
The one decision, made for each declaration, of where it is defined
(`snakebite.language.definition`). It has three results: `rootOwned` (only the
root modules define it, and a backend executes it), `rootOrElsewhere` (the
root modules define it and another object can too, as for a template instance,
of which one copy is kept) and `definedElsewhere` (see **Defined elsewhere**).

**Native layout**:
The memory representation compiled D uses. Guest values always use
native layout, so crossing the barrier never copies or converts.
_Avoid_: marshalling, boxing

**Plan**:
The description, computed once and then reused, of how a call crosses
the barrier: per function for an ordinary call, per call site for a
C-variadic call, whose own extra arguments shape the plan too.
_Avoid_: call descriptor, thunk

**Program**:
The program as source: the input of a backend. The module qualifies the
name: this is `snakebite.program.Program`. Inside the bytecode compiler it is
imported as `SourceProgram`. Compare **Bytecode program**.

**Bytecode program**:
What one process holds of a compiled program while it runs: the compiled
functions, the signatures, the static storage, the call plans and the start
data. The bytecode compiler fills it on demand, or one function makes it
from **SBC files** (ADR-0021). It is
`snakebite.backends.bytecode.program.Program`, not the source `Program`.
The module qualifies the name, and inside the bytecode compiler the source
one is `SourceProgram`.

**Start data**:
What a backend gives to the runner (`snakebite.run`) to start a program, with
no frontend data in it. It holds one `ModuleStart` for each root module (its
constructors, destructors, unit tests and `main`, as handles to compiled
functions, and the names of the modules that it imports), and what follows
from them for the whole program: which `main` runs, and whether it is the C
entry point. `snakebite.start.data`. A backend builds it from the source
`Program`; the source `Program` holds the frontend modules, and the start data
holds what is left of them to run.

**Compilation unit**:
The source files that are given to one compile (ADR-0021). With `module` it
is one source file; with `package` it is the source files of one directory;
with `project` it is all the source files. A compile to a file writes one
**SBC file** for its compilation unit.
_Avoid_: unit

**SBC file**:
The `.sbc` file that a compile to a file writes. It holds a list of modules:
the functions and data that the modules of its compilation unit define, the
template instances that the compile made (each in the entry of the module that
declares the template), the symbol name of each definition, and a reference by
symbol name to each thing that is defined elsewhere. A native object file is
the inspiration for its content; a deviation needs a reason (ADR-0021).

**Root modules**:
The modules that are given to a compile as the files to compile. The meaning
is the one that it has in dmd. Compare **Root-owned**.

**Bytecode modules**:
All the modules of the program that `sb` compiles to bytecode. The other
modules are native code. A call to a function of a bytecode module is a call
to bytecode; a call to a function of any other module is a native call.
_Avoid_: project modules

**Static world**:
The static data, the type information, the class information, the plans and
the callable address of each function of one program. One shared module
builds these and connects them; a backend gives only the storage and the
word that stands for the guest body of a function.

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
and an integer division that the hardware traps. A load, a store or a call
through the address of a symbol that no object defines is a guest fault too,
of which compiled D does not die, because its link fails first (ADR-0017). It
is not a halt and nothing recovers from it. A handler for SIGSEGV and SIGFPE
writes one line to standard error (the kind, or for a symbol that no object
defines the failure that names it, and the innermost guest function and the
line when the backend knows them), then the default action of the signal
ends the process, as it ends compiled D.
_Avoid_: crash, trap
