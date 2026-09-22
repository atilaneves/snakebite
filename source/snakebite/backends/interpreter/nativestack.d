module snakebite.backends.interpreter.nativestack;


private:


// A dedicated native stack the interpreter's own recursive tree walk runs
// on, instead of whatever stack a host-to-guest entry happened to be
// reached on.
//
// A host-to-guest entry (`Evaluator.runHostToGuest`, walker.d) can be
// reached on a guest-created `core.thread.Fiber`'s own stack, which
// druntime sizes for compiled D's few-hundred-bytes-per-frame recursion
// cost, not the tree walker's own (a nested guest call costs the visitor
// roughly 1.1-4.8 KB of native stack: `executeCall` -> `executeRaw` ->
// `visit` -> ... -> `executeCall` again). `Evaluator.runOnInterpreterStack`
// switches onto this stack for exactly that case - a host-to-guest entry
// reached while a guest `Fiber` is active (`Fiber.getThis`) - since a
// plain OS thread's own stack is already sized like compiled D's
// (`defaultInterpreterStackBytes`, below) and needs no switch. `Evaluator`
// owns one of these per (thread, fiber) context, the same lifetime
// `_frames` (`FrameStack`) already has (ADR-0006's
// `PerThread!(Evaluator, true)`).
//
// Running on a bigger stack does not make guest call depth unbounded -
// compiled D recursing this deep would eventually exhaust its own
// thread's stack too. `bytes` matches `RLIMIT_STACK`: the same budget
// compiled D's main thread, and any `core.thread.Thread` this process
// creates with no explicit size, already gets by default. This is
// therefore not a number tuned to make one guest program pass - it is
// "give the walker the stack a normal compiled-D thread has", which
// comfortably covers the walker's larger per-frame cost for the same
// call depth compiled D could reach in that same budget.
package struct InterpreterStack {
    import core.memory: GC;

    // Set from the first host-to-guest entry that switches onto this
    // stack until the whole call - yield/resume included - completes
    // (`Evaluator.runOnInterpreterStack`). A nested host-to-guest entry
    // reached while this is already set (a guest delegate passed to a
    // host algorithm, called from guest code already running on this
    // stack) runs in place: it already has the full budget, and yield()
    // suspending mid-recursion must not have this popped out from under
    // it by an unrelated switch-back.
    public bool active;

    private ubyte* _guard;
    private ubyte* _base;
    private size_t _size;

    @disable this(this);

    public this(size_t bytes) @system {
        import core.memory: pageSize;
        import core.sys.posix.sys.mman:
            MAP_ANON, MAP_FAILED, MAP_PRIVATE, PROT_NONE, PROT_READ,
            PROT_WRITE, mmap, mprotect;
        import std.conv: text;

        _size = roundUpToPage(bytes);
        const mappingSize = _size + pageSize;
        _guard = cast(ubyte*) mmap(
            null, mappingSize, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (_guard == cast(ubyte*) MAP_FAILED)
            throw new Exception(
                text("could not reserve ", mappingSize,
                    " bytes for the interpreter's native stack"),
            );

        _base = _guard + pageSize;
        if (mprotect(_base, _size, PROT_READ | PROT_WRITE) != 0) {
            import core.sys.posix.sys.mman: munmap;

            munmap(_guard, mappingSize);
            _guard = null;
            throw new Exception(
                text("could not commit ", _size,
                    " bytes for the interpreter's native stack"),
            );
        }

        // A transient D value the walker leaves only in a native local -
        // never stored into a guest frame or the frame stack - must still
        // stay visible to the collector for as long as it is live
        // (ADR-0005's own rule for guest state the GC does not otherwise
        // scan; `source/snakebite/framestack.d` registers the frame stack
        // itself the same way).
        GC.addRange(_base, _size);
    }

    ~this() @system {
        import core.memory: pageSize;
        import core.sys.posix.sys.mman: munmap;

        if (_guard is null)
            return;
        GC.removeRange(_base);
        assert(
            munmap(_guard, _size + pageSize) == 0,
            "could not release the interpreter's native stack",
        );
    }

    // The initial `%rsp` for a call onto this stack: the stack's own high
    // end (x86-64 stacks grow down), 16-byte aligned as the SysV ABI
    // requires at a `call` instruction
    // (`snakebite_interpreter_call_on_stack`, interpreter_stack_amd64.S).
    // `_size` is a whole number of pages, already 16-byte aligned, so
    // this needs no further rounding.
    public void* top() const {
        return cast(void*) (_base + _size);
    }
}


private size_t roundUpToPage(in size_t bytes) {
    import core.memory: pageSize;

    return (bytes + pageSize - 1) / pageSize * pageSize;
}


// `RLIMIT_STACK`: what a new native thread's stack is sized from when
// nothing overrides it, on this platform - see `InterpreterStack`'s own
// documentation for why this, and not a number picked for one guest
// program, is the right default.
package size_t defaultInterpreterStackBytes() {
    import core.sys.posix.sys.resource:
        getrlimit, rlimit, RLIMIT_STACK, RLIM_INFINITY;

    // 8 MiB: Linux's own out-of-the-box `RLIMIT_STACK` soft limit, used
    // whenever the real limit cannot be read or is unbounded (`ulimit -s
    // unlimited` gives every new thread a stack this same size in
    // practice - the kernel still has to commit it from somewhere; this
    // mirrors that in the one case `getrlimit` cannot answer "how big").
    enum fallbackBytes = 8UL * 1024 * 1024;

    rlimit limit;
    if (getrlimit(RLIMIT_STACK, &limit) != 0)
        return fallbackBytes;
    if (limit.rlim_cur == RLIM_INFINITY || limit.rlim_cur == 0)
        return fallbackBytes;
    return cast(size_t) limit.rlim_cur;
}


// `interpreter_stack_amd64.S`. Calls `fn(arg)` with `%rsp` set to
// `newStackTop` for the duration of that one call, then restores it -
// see that file for the CFI reasoning that keeps this safe to unwind a
// `Throwable` through (ADR-0004).
package extern(C) void snakebite_interpreter_call_on_stack(
    void* newStackTop,
    void function(void*) fn,
    void* arg,
) @system;


// Moving `%rsp` this way, on its own, is not enough: druntime's
// conservative GC also scans "the current native stack" on every
// collection, using a fixed record of that stack's own base
// (`core.thread.context.StackContext.bstack`) paired with a freshly read,
// live `%rsp` (`core.thread.threadbase.scanAllTypeImpl`). A guest
// `Fiber`'s own `StackContext.bstack` still names its own small stack
// while we are switched, so that scan reads `[our live %rsp .. the small
// stack's base)` - two unrelated mmap'd regions - and segfaults on the
// unmapped gap between them the instant a guest allocation collects.
// druntime does not expose a way to fix this from outside
// (`ThreadBase.pushContext`, the mechanism `Fiber` itself uses, is
// `package(core.thread)`), except through the one extension point
// `core.thread.fiber` documents for exactly this kind of case: a `Fiber`
// subclass gets `protected` access to `m_ctxt` (`fiber/base.d`'s own
// "Stack Management" section - the same access `allocStack`/`initStack`
// already rely on). `FiberContextAccess` is never instantiated for its
// own coroutine behaviour; its only job is to stand in that inheritance
// chain so its one static method can read and briefly mutate a *guest*
// `Fiber`'s `StackContext` while `Evaluator.runOnInterpreterStack` is
// switched onto its dedicated stack, then restore it - see that method
// for why this is safe across `Fiber.yield()`/resume too.
private abstract class FiberContextAccess : imported!"core.thread.fiber".Fiber {
    import core.thread.fiber: Fiber;
    import core.thread.context: StackContext;

    private this() {
        // Never actually called - `contextOf` is `static` - so the
        // delegate and stack size here are never used for anything.
        void delegate() unused = {};
        super(unused);
    }

    static StackContext* contextOf(Fiber fiber) {
        return fiber.m_ctxt;
    }
}

package imported!"core.thread.context".StackContext* fiberContextOf(
    imported!"core.thread.fiber".Fiber fiber,
) {
    return FiberContextAccess.contextOf(fiber);
}
