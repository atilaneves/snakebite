---
status: accepted
---

# The Interpreter's native stack grows in pieces

Issue #517: the Interpreter walks the tree with host recursion. A guest call
uses about 2.6 KB of native stack, and compiled D uses tens of bytes for the
same call. A thread stack of 8 MiB holds about 3,000 guest calls, and a
`core.thread.Fiber` of the default size (16 KiB) holds about six. Compiled
D reaches about 260,000 calls on the same thread. A guest that recurses
deeply is a valid program, and a guest `Fiber` of the default size that
recurses and yields (the shape of dlib) is also valid.

An earlier version gave each execution state a private walker stack of 512
MiB. That needed the private members of druntime's `Thread`, and it was a
large fixed size chosen for particular programs.

## Decision

The walker runs on the native stack that it is entered on, the base. Before
each guest call it compares the stack pointer with a limit. Below the
limit, the walk continues on a new `core.thread.Fiber` of 1 MiB, a piece,
and returns to the base when the deep part is done. Active pieces have no
fixed byte or count bound. A finite recursion that compiled D accepts must
not fail because it crosses an arbitrary walker stack bound. Resource
exhaustion can still end the process. Compiled D also exhausts resources:
an unbounded recursion ended with SIGSEGV in a separate native probe.
The earlier 256 MiB bound instead stopped valid 100,000-call recursion,
which completed in both compiled D and the Bytecode VM.

- The limit of a thread's stack is its middle. The bounds come from
  `pthread_getattr_np` and `pthread_attr_getstack`, once for each thread.
  The limit of a piece is half of its size below the entry of the piece.
  On any other stack (a guest `Fiber`), no room is known, and the first
  check moves the walk to a piece.
- A call from the walker to host code runs on the base, never on a piece.
  `Fiber.getThis`, `Fiber.yield` and `Thread.getThis` give host code the
  answer that compiled D gives. The walker on a piece stops with
  `Fiber.yield`, and one loop on the base calls the host function and then
  calls the piece again. Pieces do not call pieces. A callback from host
  code arrives on the base and can start its own loop.
- A `Throwable` that ends a piece goes to the loop as a value, and the loop
  throws it on the base or gives it to the piece below. A `Throwable` that
  a host function throws goes to the piece that waits, and the piece throws
  it again. The same object arrives at the guest `catch`.
- A finished piece goes to a free list of two for each thread. A piece that
  does not fit is destroyed, and druntime unmaps its stack. In a GC
  finalizer, `new` is not possible. Each thread keeps one more piece in
  reserve, made at the first entry outside a finalizer. A guest destructor
  that the collector runs takes a free piece, or the reserve. When it needs
  more, the run stops with a message that says so. A process-wide spare is
  made at startup for a collector that first enters guest code on a new
  host thread. That thread borrows the spare for its first piece and
  returns it when the piece ends. A mutex protects the spare for the whole
  use. The public Fiber API permits transfer between threads when a Fiber
  is not executing. This adds one 1 MiB stack per process and lock operations
  only for finalizers on threads that have no local piece.
- State that is local to a Fiber, such as the execution state, is looked up
  by the Fiber that the piece continues, or by the thread, and not by the
  piece (`Continuation` in `hostthreads.d`). Host code that runs on a piece,
  such as a destructor that a collection started by the walker calls, then
  finds the execution state that owns the piece.

Only the public API is used: `Fiber`, `destroy`, `GC.inFinalizer`, and
the two glibc functions. The module is
`source/snakebite/backends/interpreter/stackpieces.d`. The Bytecode VM does
not change.

## Considered options

**Guest calls without host stack (explicit frames).** Rejected. A caller's
remaining work after a call (an add, a cleanup, a `catch`) is in host
frames today, and ADR-0004 uses the host unwinder for guest exceptions. This
is a second walker of several thousand lines, and it is the design of the
Bytecode VM.

**The walker always on a piece.** Rejected. Every host call in every
program pays a `Fiber` switch.

**A mapping with `MAP_GROWSDOWN`.** Rejected. The kernel limits the growth
to `RLIMIT_STACK`, and druntime has no public way to scan a stack that it
did not make.

**A second `Thread` for the deep part.** Rejected. `Thread.getThis` and
thread-local storage change for host code.

## Consequences

ADR-0004 says that nothing catches a `Throwable` and throws it again. The
loop at the end of a piece does this. Only walker frames are between the end
of a piece and the next handler, so no host frame sees the difference.

These limits remain:

1. Host code that runs on a piece without a barrier crossing sees
   `Fiber.getThis` equal to the piece. The cases are the compiled
   destructor that a collection runs, when the walker started the collection
   with its own allocation, and the static initial value of a guest
   variable that needs a native constructor (it calls the host function
   directly, not through the crossing point of the walker).
2. Recursion that alternates guest and host code is limited by the base.
   Each round leaves host frames on the base. On a thread this is the 8 MiB
   stack. In a guest `Fiber` of the default size it is a small number of
   rounds.
3. One guest function whose own nesting needs more than 512 KiB of walker
   stack overflows a piece, and the process ends with SIGSEGV. On a thread
   stack the same function has 4 MiB.
4. Host code that a guest calls in a `Fiber` of the default size has less
   stack than in compiled D: the walker frames from the `Fiber` entry to the
   first check use between 2.6 KB (release build) and 3.6 KB (dmd debug
   build) of the 16 KiB.
5. Each piece is 1 MiB of address space and two mappings. A guest `Fiber`
   that is suspended in deep guest code keeps its pieces until it ends or
   the collector destroys it. With `vm.overcommit_memory` 2, or a small
   `vm.max_map_count`, a program with very many such Fibers can fail sooner
   than compiled D.
6. The fault handler finds a run by the address of the stack, and it has no
   lower bound for the stack. After a fault on a piece, the position text
   can name the wrong run.
7. Guest signal handlers on an alternate stack, `pthread_exit` and
   `pthread_cancel` in guest code, and a guest `Fiber` that moves to another
   thread while it has pieces are not supported and were not run.
8. A guest destructor that the collector runs has one reserve piece and the
   free pieces, and no more. A thread with no local piece borrows the process
   spare for its first piece. A destructor that recurses past them stops the
   run with a message.
9. Guest code in a guest `Fiber` always runs on a piece, because the size of
   the stack of a `Fiber` is not public, and so no room can be known. Each
   host call and each callback there costs one `Fiber` switch. A `qsort` of
   200,000 ints with a guest comparator, inside a guest `Fiber` of 1 MiB,
   took 4.34 s on master and 6.87 s on this design. On the main thread the
   time is unchanged.
10. Active recursion uses substantially more memory than compiled D. For
    the function `int depth(int n) { return n == 0 ? 0 : 1 + depth(n - 1); }`
    at 100,000 calls, the release Interpreter used 282,144 KiB peak RSS
    and 0.32 s elapsed time. Compiled D used 5,752 KiB and less than 0.01 s;
    the Bytecode VM used 40,964 KiB and 0.03 s. These process measurements
    include frontend and runtime work, so they do not isolate stack cost.
    The debug `bin/ut` stack tests used 774,032 KiB peak RSS in total.
    Only two free pieces and one finalizer reserve remain after a walk;
    other completed pieces are destroyed and their stacks are unmapped.

## Stack cost and preserved guarantees

The original problem is the walker host frames: they are much larger than
compiled guest frames. Pieces prevent the thread or guest Fiber stack from
setting an early recursion limit. They preserve host thread and Fiber
identity at native calls, GC scanning of suspended stacks, native layout,
and exception cleanup through the host unwinder.

Only the upper 512 KiB of each 1 MiB piece holds guest calls. The lower
512 KiB gives one guest function, native work without a crossing, and the
collector room for frames that have no guest-call check. This reserve
increases mapped address space; it does not require all reserved pages to
be resident. The measurements above do not separate this reserve from
active walker frames or other process memory. There is no measurement that
supports reducing the reserve while preserving that stack-room guarantee.

The cap did not reduce the cost of a successful walk. It rejected valid
walks that needed more pieces. Removing it permits those walks, while the
existing free list still limits retained stack storage after they return.
Reducing active host frames requires a change to walker execution and
exception handling, as described in the explicit-frame option above.
This change does not attempt that redesign. Infinite recursion can consume
more memory than compiled D before resource exhaustion ends the process.
