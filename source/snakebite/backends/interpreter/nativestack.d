module snakebite.backends.interpreter.nativestack;


private:


// A dedicated native stack that the walker's own recursion runs on. Every
// entry of guest code into the interpreter runs there, whichever native
// stack the host reached it on: the walker needs far more native stack
// for each guest call than compiled D needs for the same call (about 2 KB
// against about 32 bytes in a small function), and a thread or a
// `core.thread.Fiber` has a stack that is sized for compiled D.
//
// `Evaluator` owns one of these for each (thread, fiber) context, with the
// same lifetime as its `FrameStack` (ADR-0006).
//
// The size is address space that the kernel does not commit until the
// walker touches a page. 512 MiB is about 270000 nested calls of a small
// function: compiled D reaches about 261000 of them in the 8 MiB stack of
// a default Linux thread.
public enum interpreterStackBytes = 512UL * 1024 * 1024;


public struct InterpreterStack {
    // Set from the first entry that switches onto this stack until the
    // whole call - yield and resume included - completes (`run`). A nested
    // entry reached while this is set (a guest delegate passed to a host
    // algorithm, called from guest code that already runs on this stack)
    // runs in place.
    //
    // Also the destructor's guard against unmapping this stack out from
    // under a still-registered context - see `~this` below.
    public bool active;

    private ubyte* _guard;
    private ubyte* _base;
    private size_t _size;

    @disable this(this);

    public this(size_t bytes) @system {
        import core.memory: pageSize;
        import core.sys.linux.sys.mman: MAP_NORESERVE;
        import core.sys.posix.sys.mman:
            MAP_ANON, MAP_FAILED, MAP_PRIVATE, PROT_NONE, PROT_READ,
            PROT_WRITE, mmap, mprotect;
        import std.conv: text;

        _size = roundUpToPage(bytes);
        const mappingSize = _size + pageSize;
        _guard = cast(ubyte*) mmap(
            null, mappingSize, PROT_NONE,
            MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
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
    }

    // Ordinarily unmaps this stack's mapping: nothing needs it once no
    // call is switched onto it. `active`, though, means a switch never
    // unwound back through `run` -
    // a guest `Fiber` left suspended mid-call here, abandoned rather than
    // resumed to completion, or one `Fiber.reset` the way `core.thread`
    // documents: `tstack` set to this stack's own `top` and a fresh entry
    // frame written onto it, so the fiber goes on running here for good.
    // Either way that `Fiber`'s own `StackContext` still names this
    // mapping, and it stays in druntime's scan list for as long as the
    // `Fiber` object does - unmapping out from under it would leave the
    // next collection on any thread reading unmapped memory the moment it
    // reaches that context. Leaking the mapping instead, for exactly
    // those (rare, abandoned-fiber) cases, costs address space that is
    // never touched again; unmapping it could instead cost a segfault on
    // a thread that did nothing wrong.
    ~this() @system {
        import core.memory: pageSize;
        import core.sys.posix.sys.mman: munmap;

        if (_guard is null)
            return;
        if (active)
            return;
        const unmapped = munmap(_guard, _size + pageSize);
        if (unmapped != 0)
            assert(0, "could not release the interpreter's native stack");
    }

    // Runs `action` on this stack, or in place if it already runs here.
    //
    // druntime scans a thread's stack from the live `%rsp` to the
    // `bstack` of the context that is current (`ThreadBase.m_curr`: the
    // thread's own or the active `Fiber`'s), so that context must name
    // this stack for as long as `action` runs on it. Everything the host
    // keeps between the entry and the switch is then outside that range,
    // and `GC.addRange` keeps it scanned. `m_lock` makes druntime ignore
    // the context while its `bstack` and the live `%rsp` name different
    // stacks, exactly as `Fiber.switchIn` does, so a collection on
    // another thread never reads that pair.
    //
    // A `Fiber.yield` inside `action` leaves through druntime's own
    // switch, not through here, and resumes on this stack: the context
    // stays redirected until `action` truly ends.
    public void run(scope void delegate() action) @system {
        if (active) {
            action();
            return;
        }

        const activation = Activation(&active);
        auto context = currentContext;
        void* mark;
        assert(
            cast(ubyte*) &mark < cast(ubyte*) context.bstack,
            "the stack does not grow the way this switch assumes",
        );
        const abandoned = AbandonedFrames(&mark, context.bstack);
        // Locked until `runOnStack` starts on this stack.
        const redirection = Redirection(context, top);
        auto call = Call(action);
        snakebite_interpreter_call_on_stack(top, &runOnStack, &call);
    }

    // The initial `%rsp` for a call onto this stack: the stack's own high
    // end (x86-64 stacks grow down), 16-byte aligned as the SysV ABI
    // requires at a `call` instruction
    // (`snakebite_interpreter_call_on_stack`, interpreter_stack_amd64.S).
    // `_size` is a whole number of pages, already 16-byte aligned, so
    // this needs no further rounding.
    public void* top() @nogc nothrow pure const {
        return cast(void*) (_base + _size);
    }
}


private size_t roundUpToPage(in size_t bytes) @safe @nogc nothrow pure {
    import core.memory: pageSize;

    return (bytes + pageSize - 1) / pageSize * pageSize;
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




private struct Call {
    void delegate() action;
}


// `snakebite_interpreter_call_on_stack` knows plain C pointers only. The
// `Call` is on the caller's stack and stays readable on this one.
private extern(C) void runOnStack(void* context) {
    // The lock came with `Redirection` and ends here: from now on `%rsp`
    // and `bstack` name the same stack.
    setScanLock(false);
    // Locks again on the way out, before `%rsp` leaves this stack.
    const leaving = ScanLock.init;
    (*cast(Call*) context).action();
}


private struct ScanLock {
    @disable this(this);

    ~this() @system nothrow @nogc {
        setScanLock(true);
    }
}


private struct Activation {
    private bool* _flag;

    @disable this(this);

    this(bool* flag) @system nothrow @nogc {
        _flag = flag;
        *_flag = true;
    }

    ~this() @system nothrow @nogc {
        *_flag = false;
    }
}


private struct AbandonedFrames {
    private void* _start;

    @disable this(this);

    this(void* start, void* end) @system nothrow {
        import core.memory: GC;

        _start = start;
        GC.addRange(start, cast(ubyte*) end - cast(ubyte*) start);
    }

    ~this() @system nothrow @nogc {
        import core.memory: GC;

        GC.removeRange(_start);
    }
}


// Points `context` at the interpreter stack, and back at the stack it
// had on destruction. Locked in between the two moves of `%rsp`.
private struct Redirection {
    private imported!"core.thread.context".StackContext* _context;
    private void* _saved;

    @disable this(this);

    this(imported!"core.thread.context".StackContext* context, void* top)
        @system nothrow @nogc
    {
        _context = context;
        _saved = context.bstack;
        setScanLock(true);
        context.bstack = top;
        context.tstack = top;
    }

    ~this() @system nothrow @nogc {
        setScanLock(true);
        _context.bstack = _saved;
        _context.tstack = _saved;
        setScanLock(false);
    }
}


// The context that druntime scans for the running thread.
private imported!"core.thread.context".StackContext* currentContext()
    @system nothrow @nogc
{
    return __traits(getMember, imported!"core.thread".Thread.getThis, "m_curr");
}


private void setScanLock(bool locked) @system nothrow @nogc {
    import core.atomic: atomicFence;

    __traits(getMember, imported!"core.thread".Thread.getThis, "m_lock") = locked;
    atomicFence();
}
