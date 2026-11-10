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
It does not call a function. It does not use the stack. For this reason:

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
an absolute `mov` and `jmp rax`. No JIT code uses a relative jump or call
across functions or across chunks of the code region, so the code region
can have any address, and chunks can be anywhere in memory.

### Tier-up

A function is hot after 256 events (`jitThreshold` in `vm.d`). An event is a
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
that runs in a finalizer can make a function hot. The compile can allocate
from the GC, because the first one builds the tables that classify handlers,
and they are associative arrays. It also maps memory and takes a lock. A finalizer must not allocate from the
GC, and must not wait for a thread that a collection suspended. The function
stays in its handlers, and compiles at a later event.

The emitter allocates nothing for each instruction. It works in buffers that
a compile reuses (they belong to the instance), and in the code region. The cost of a compile is paid at
run time, so it must be small.

The code of a function is made from a snapshot of its instructions. A
counting twin is replaced by the handler it counts, so that the code
of a backward branch does not count a second time. A call keeps its twin:
the code of the call still counts the events of the callee.

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

Code is never freed while its instance lives. The code region belongs to the
`Bytecode` instance that compiled the functions, not to the process. The
instance makes the region at its first JIT compile, and the destructor of the
instance unmaps every chunk and closes the file. A function that has JIT code
keeps it until its instance is destroyed. Each `Function` points to the JIT
state of its instance (`Function.jit`), so a tier-up finds the region, the lock
and the scratch buffers of its owner. The lock is one word in that state, so
two instances do not exclude each other.

Two things are not instance state. The CPU check (BMI2) and the check of the
calling convention have one answer for the process, so the first instance that
needs them makes them. The tables that classify handlers are the same for each
instance and nothing writes them after they are built, so they are `immutable`
and shared. A thread that needs them builds a copy and publishes it with a
compare-and-swap; the loser drops its copy and does not wait.

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

- Hot code loses most of its operand loads and dispatch instructions. Calls,
  returns and the other instructions without a template still run in
  handlers.
- A new handler gets no JIT code until it is given a template. It keeps
  working, because every instruction has a stub.
- A new calling convention of a compiler needs a new register map. The
  start-up check fails loudly when the map is wrong.
- A handler that changes the meaning of an operand must change its template
  with it. The matrix tests run with `--eager-jit` for this reason.
