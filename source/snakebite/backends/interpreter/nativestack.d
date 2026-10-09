module snakebite.backends.interpreter.nativestack;


private:


import core.thread: Thread;
import core.thread.context: StackContext;


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
// a default Linux thread. Each live context holds this much address space
// (one mapping plus one guard page) on top of its own stack, so about 2.4
// GiB for a thread or a Fiber in total (measured), against about 2 GiB
// before. A process with very many live Fibers can reach the kernel's
// limit for mappings or for address space sooner than before.
public enum interpreterStackBytes = 512UL * 1024 * 1024;


public struct InterpreterStack {
    // Set from the switch onto this stack until the whole call - yield and
    // resume included - completes (`run`). The caller decides that a nested
    // entry, reached while this is set, runs in place: it never calls
    // `run` again.
    //
    // Also the destructor's guard against unmapping this stack out from
    // under a still-registered context - see `~this` below.
    public bool active;

    private ubyte* _guard;
    private ubyte* _base;
    private size_t _size;

    @disable this(this);

    public this(in size_t bytes) @system {
        import core.memory: pageSize;
        import core.sys.linux.sys.mman: MAP_NORESERVE;
        import core.sys.posix.sys.mman:
            MAP_ANON, MAP_FAILED, MAP_PRIVATE, PROT_NONE, PROT_READ,
            PROT_WRITE, mmap, mprotect;
        import std.conv: text;

        _size = roundUpToPage(bytes);
        const mappingSize = _size + pageSize;
        if (_size == pooledSize) {
            _guard = _pool.take;
            if (_guard !is null) {
                _base = _guard + pageSize;
                return;
            }
        }
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

    // Ordinarily gives this stack's mapping back: nothing needs it once no
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
        if (_size == pooledSize && _pool.put(_guard, _base, _size))
            return;
        const unmapped = munmap(_guard, _size + pageSize);
        if (unmapped != 0)
            assert(0, "could not release the interpreter's native stack");
    }

    // Runs `action` on this stack. Not reentrant: a caller whose context
    // is already `active` runs `action` in place instead.
    //
    // druntime scans a thread's stack from the live `%rsp` to the
    // `bstack` of the context that is current (`ThreadBase.m_curr`: the
    // thread's own or the active `Fiber`'s), so that context must name
    // this stack for as long as `action` runs on it. Everything the host
    // keeps between the entry and the switch is then outside that range,
    // and `GC.addRange` keeps it scanned. `m_lock` keeps druntime's suspend
    // handler from storing a new `tstack` for the context while `bstack`
    // and the live `%rsp` name different stacks. The context is still
    // scanned in that window, but from `tstack` to `bstack`, and
    // `Redirection` sets the two to the same address, so the range is
    // empty.
    //
    // A `Fiber.yield` inside `action` leaves through druntime's own
    // switch, not through here, and resumes on this stack: the context
    // stays redirected until `action` truly ends.
    public void run(scope void delegate() action) @system
    in (!active)
    {
        const activation = Activation(&active);
        auto context = currentContext;
        if (context is null) {
            // libc can call guest exit handlers after thread_term cleared
            // the main thread's context. There is no scanner to redirect,
            // but guest calls still need the interpreter's native stack.
            auto call = Call(action);
            snakebite_interpreter_call_on_stack(top, &runWithoutScanner, &call);
            return;
        }
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

    public const(void)* bottom() @nogc nothrow pure const {
        return _base;
    }
}


private size_t roundUpToPage(in size_t bytes) @safe @nogc nothrow pure {
    import core.memory: pageSize;

    return (bytes + pageSize - 1) / pageSize * pageSize;
}


// Stacks of the usual size that no context uses at the moment. A thread
// that ends hands its stack on to the next one that starts: that thread
// then pays neither for the mapping calls nor for the first page fault on
// a fresh stack.
private size_t pooledSize() @safe @nogc nothrow pure {
    return roundUpToPage(interpreterStackBytes);
}


private struct Pool {
    // What a pooled stack keeps resident. The rest goes back to the kernel
    // when the stack is released, so that one deep recursion does not stay
    // resident for the rest of the process.
    enum keptBytes = 64 * 1024;
    enum capacity = 16;

    // The link to the next entry is stored in the top bytes of the stack,
    // which the first call on it touches anyway.
    private ubyte* _head;
    private size_t _count;
    private shared bool _locked;

    // Null if the pool is empty.
    ubyte* take() @system nothrow @nogc {
        const lock = Lock(&_locked);
        auto guard = _head;
        if (guard is null)
            return null;
        _head = *linkOf(guard);
        --_count;
        return guard;
    }

    // Takes over `guard`'s mapping if there is room, and says so.
    bool put(ubyte* guard, ubyte* base, in size_t size) @system nothrow @nogc {
        if (size > keptBytes)
            madvise(base, size - keptBytes, MADV_DONTNEED);
        const lock = Lock(&_locked);
        if (_count == capacity)
            return false;
        *linkOf(guard) = _head;
        _head = guard;
        ++_count;
        return true;
    }

    private static ubyte** linkOf(ubyte* guard) @system nothrow @nogc {
        import core.memory: pageSize;

        return cast(ubyte**) (guard + pageSize + pooledSize - (ubyte*).sizeof);
    }

    ~this() @system nothrow @nogc {
        import core.memory: pageSize;
        import core.sys.posix.sys.mman: munmap;

        while (_head !is null) {
            auto guard = _head;
            _head = *linkOf(guard);
            munmap(guard, pooledSize + pageSize);
        }
    }
}


// Not in druntime's bindings for Linux.
private extern(C) int madvise(void* address, size_t length, int advice)
    @system nothrow @nogc;
private enum MADV_DONTNEED = 4;


private __gshared Pool _pool;


private shared static ~this() {
    destroy(_pool);
}


private struct Lock {
    private shared(bool)* _flag;

    @disable this(this);

    this(shared(bool)* flag) @system nothrow @nogc {
        import core.atomic: cas;

        _flag = flag;
        while (!cas(_flag, false, true)) {}
    }

    ~this() @system nothrow @nogc {
        import core.atomic: atomicStore;

        atomicStore(*_flag, false);
    }
}


// `interpreter_stack_amd64.S`. Calls `fn(arg)` with `%rsp` set to
// `newStackTop` for the duration of that one call, then restores it -
// see that file for the CFI reasoning that keeps this safe to unwind a
// `Throwable` through (ADR-0004).
private extern(C) void snakebite_interpreter_call_on_stack(
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


private extern(C) void runWithoutScanner(void* context) {
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

    this(in void* start, in void* end) @system nothrow {
        import core.memory: GC;

        _start = cast(void*) start;
        GC.addRange(_start, cast(ubyte*) end - cast(ubyte*) start);
    }

    ~this() @system nothrow @nogc {
        import core.memory: GC;

        GC.removeRange(_start);
    }
}


// Points `context` at the interpreter stack, and back at the stack it
// had on destruction. Locked in between the two moves of `%rsp`.
private struct Redirection {
    private StackContext* _context;
    private void* _saved;

    @disable this(this);

    this(StackContext* context, in void* top) @system nothrow @nogc {
        _context = context;
        _saved = context.bstack;
        setScanLock(true);
        context.bstack = cast(void*) top;
        context.tstack = cast(void*) top;
    }

    ~this() @system nothrow @nogc {
        setScanLock(true);
        _context.bstack = _saved;
        _context.tstack = _saved;
        setScanLock(false);
    }
}


// The two members of druntime's `Thread` that the switch needs and that
// druntime does not export. `__traits(getMember)` goes around their
// `package(core.thread)` visibility, so a druntime that renames or retypes
// one of them must fail here, with this message.
private ref Type threadMember(string name, Type)() @system nothrow @nogc {
    static assert(
        __traits(hasMember, Thread, name)
            && is(typeof(__traits(getMember, Thread.init, name)) == Type),
        "druntime's `core.thread.Thread." ~ name ~ "` of type `"
            ~ Type.stringof ~ "` is missing or has another type: the "
            ~ "interpreter stack switch needs it to "
            ~ (name == "m_curr"
                ? "find the context that druntime scans for the running thread"
                : "keep druntime's suspend handler off a context whose "
                    ~ "`bstack` and live `%rsp` name different stacks"),
    );
    return __traits(getMember, Thread.getThis, name);
}


// The context that druntime scans for the running thread.
private StackContext* currentContext() @system nothrow @nogc {
    return threadMember!("m_curr", StackContext*);
}


private void setScanLock(in bool locked) @system nothrow @nogc {
    import core.atomic: atomicFence;

    threadMember!("m_lock", bool) = locked;
    atomicFence();
}
