---
status: accepted
---

# The bytecode VM has a template JIT with tier-up

A bytecode handler loads its operands from the instruction, does its work,
and dispatches to the next handler with an indirect jump. For a simple
instruction, such as an add or a compare and branch, most of the executed
x86-64 instructions are the operand loads and the dispatch. A template
JIT removes them: each instruction becomes machine code with its operands
as immediates, and the code of the next instruction follows it. The
decision for a JIT of this kind, and the measurements behind it, are in
issue #873.

## Decision

A function that is hot gets x86-64 code for each of its instructions that
has a template. The JIT code of an instruction is a copy of the work of its
handler with the operands as immediates. The code is in `jit.d`. The
tier-up, the counting and the table that names the template of a handler
are in `vm.d`.

### JIT addresses are in the handler slots

The code of instruction `i` has the same signature as `Instruction.Handler`
and uses the same registers. Its address replaces `instructions[i].handler`.
No other table, side array or call needs to know that a function has JIT
code. Dispatch is the dispatch that already exists: a handler that jumps to
`pc.handler` reaches the JIT code of the next instruction, and JIT code
reaches a handler in the same way.

Every instruction of a hot function gets an address. An instruction with a
template gets its code. An instruction without a template gets a stub that
sets `pc` and jumps to the original handler. A jump to an instruction that
has no code at all, for example the word after the last instruction, goes
to a `ud2`.

The VM uses the handler words for nothing except dispatch, so a store to
them is enough. One thread compiles a function. It makes the code first, and
then stores each handler word with a release store of 8 aligned bytes. A
thread that runs the function sees, at each dispatch, a handler or JIT code,
and both are complete.

### The register map follows the compiler

JIT code must find `pc`, the activation, the dispatch state, the frame,
`r0` and `fp0` in the registers where the compiler that built the VM
put them. The calling convention of `Instruction.Handler` is not the same in
every compiler. `jit.d` has one map for `version (LDC)` and one for
`version (DigitalMars)`. A build with any other compiler has no JIT.

A map is read from the disassembly of a handler, so a new compiler version
can change it. Before the first JIT code is made, the JIT calls a small
stub with known values. The stub stores the registers of the map to memory.
If they differ from the values that were passed, the process stops with an
internal failure. The check is part of the one-time set-up of the JIT,
which also reads CPUID for BMI2. The shift instructions use `shlx`,
`shrx` and `sarx`, so without BMI2 they keep their handlers. Druntime's
`core.cpuid` has no public accessor for BMI2, so the JIT reads CPUID leaf 7
with inline assembly.

### JIT code has no frame and makes no calls

JIT code uses only the scratch registers of the map. It has no stack frame.
Guest calls and returns also set the activation and frame arguments for the
function they enter. JIT code does not call a function or use the stack. For
this reason:

- It needs no unwind information. A guest exception is thrown only by a
  real handler (a bounds failure, an assert, a call), and JIT code reaches
  a real handler with a jump, not a call. The unwinder never sees a JIT
  address on the native stack.
- It needs no GC stack map. It holds no pointer in a callee-saved register
  or in a native stack slot over a call, because it makes none. Guest
  values live in the guest frame, as they do for handlers.
- `r0` and `fp0` pass through unchanged. They survive in their registers.

### Exits to handlers

JIT code does not do all the work. It leaves for the real handler when an
instruction has no template, and when an operand does not fit what the
emitter handles. The exit depends on how the VM dispatches.

- **Chained dispatch** (a handler ends with a tail call to the handler of
  the next instruction): the stub loads `pc` with the address of the
  instruction, and jumps to the handler. `r0` and `fp0` are still in their
  registers.
- **Unchained dispatch** (a handler returns the next instruction to
  `dispatchLoop`, which passes `r0` and `fp0` from `DispatchState`): the
  stub first stores `r0` and `fp0` into `DispatchState`, as a handler does
  at its end, and then jumps.

A branch whose target is an instruction of the same function is a relative
jump inside the code of that function. Every other transfer is
an absolute jump, either to an original handler or through a live handler
slot. No JIT code uses a relative jump or call
across functions or across chunks of the code region, so the code region
can have any address, and chunks can be anywhere in memory.

### Guest calls and returns

With chained dispatch, a direct window call has a template if its site
has published the callee and its frame layout by the time the caller gets
JIT code. The template uses these facts as immediates. It claims the frame,
links the same activation as the handler, and jumps through the callee's
first handler slot. If the frame stack must grow or the callee reaches the
tier-up threshold, the original counting handler takes over before the
template changes the frame or the count. Sites that still need preparation
and calls through function values keep their handlers.

A return to a guest caller with no pending cleanup releases the frame and
jumps through the caller's resume slot. A value return can copy up to 64
bytes to the result place. A root return, a return with cleanup, and a
larger copy use their original handlers. Both transfers read live handler
slots so they work between functions at different tiers.

### Tier-up

A function is hot after 256 events (`jitThreshold` in `jit.d`). An event is a
call of the function, or one execution of one of its backward branches. A
function that loops once for a long time gets hot at its loop, and a
function that is short and called often gets hot at its calls.

The count is `Function.jitHeat`, a 32-bit value. An event adds
`2^32 / 256`, and the carry out of the add is the signal. A counting
**twin** of a call or backward-branch handler does this. The twin loads the
function of the activation, adds the step as an immediate to the memory
word, and branches on carry to a separate call that compiles. Three
instructions run in the common case, and the twin has no stack frame.
`jitCountEvents` replaces the handler of each backward branch and each call
by its twin, when the function is compiled to bytecode. When the JIT is
off, no twin is installed, and the VM pays no counting cost.

`Function.jitState` records `interpreted`, `compiling`, `compiled` or
`failed`. A thread wins the compile with a compare-and-swap. A thread that
loses, or that finds the JIT lock taken, goes on with the handlers. It does
not wait: the thread that holds the lock may be one that the GC suspended.
The function counts another 256 events and asks again.

The VM does not compile while `GC.inFinalizer` is true. A guest destructor
that runs in a finalizer can make a function hot. The compile allocates
from the GC, because the tables that classify handlers are associative arrays.
It also maps memory and takes a lock. A finalizer must not allocate from the
GC, and must not wait for a thread that a collection suspended. The function
stays in its handlers, and compiles at a later event.

The emitter allocates nothing for each instruction. It works in buffers that
a compile reuses, and in the code region. The cost of a compile is paid at
run time, so it must be small.

The code of a function is made from a snapshot of its instructions. A
counting twin is replaced by the handler it counts, so that the code
of a backward branch does not count a second time. A call keeps its twin as
the fallback. A call template adds the same event to the callee's count.

### Code memory

The code is in a `memfd` file. Each part of the file is mapped twice: a
write view, which the emitter uses, and an execute view, which the handler
words point to. No page changes protection, so a compile makes no
`mprotect` call, and no page is both writable and executable in one view.

The file starts with 1 MiB and grows on demand: `ftruncate` extends it, and
the next chunk is mapped in both views. Old chunks stay mapped, because their
code is in use. Functions are packed with 16-byte alignment. A function never
spans two chunks: when the room that a function can need is more than what
is left of the chunk, the function goes to a new chunk. Pages are made
present with `MADV_POPULATE_*` in parts of 128 KiB, so no compile takes a
page fault.

Code is never freed. A function that has JIT code keeps it until the process
ends.

With `bin/sb --jit-perf-map`, the JIT creates `/tmp/perf-<pid>.map` on the
first successful compilation. Each line contains the hexadecimal start
address, the hexadecimal size in bytes, and the mangled function name.
The JIT writes the line before it publishes the handler addresses. The map
stays on disk so `perf report` can read it after the process ends. The option
is off by default.

### Independent of stored bytecode

The JIT replaces handler words in the live instruction array, and the
compiler does not know about it. The JIT changes no operand and no table
entry of a function, so its relocation records stay true with the JIT on:
`inspection.misplacedRelocs` reads only those words, and the relocation
tests run with the JIT setting of the test run. No test scans the live
instructions of a function for addresses that no record names. The compiler
itself makes the same bytecode whether the JIT is on or off, except that the
JIT adds counting twins when it is on.

## Platform limits

- The JIT exists only in a build for Linux on x86-64 (`version (linux)
  version (X86_64)`) with LDC or DMD. In every other build the JIT code is
  not compiled, and `--no-jit` has no effect.
- It needs `memfd_create` and `MADV_POPULATE_*` (Linux 5.14).
- The shift instructions need BMI2.
- `--no-jit` on `bin/sb`, `bin/sb-repl` and `bin/bench` turns the JIT off.
  The unit test runner takes `--no-jit` and `--eager-jit`. The second
  makes a function hot at its first event. There are no environment
  variables.

## Consequences

- Hot code loses most of its operand loads and dispatch instructions. An
  instruction without a template still runs in its handler.
- A new handler gets no JIT code until it is given a template. It keeps
  working, because every instruction has a stub.
- A new calling convention of a compiler needs a new register map. The
  start-up check fails loudly when the map is wrong.
- A handler that changes the meaning of an operand must change its template
  with it. The matrix tests run with `--eager-jit` for this reason.
