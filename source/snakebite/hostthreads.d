module snakebite.hostthreads;


private:

import core.thread: Thread, ThreadID;


// How a backend keeps the state one thread needs to run guest code
// (ADR-0006): its frame stack, its evaluator, its per-thread caches. The
// state for a thread is created the first time that thread enters guest
// code through the owning backend, and released when the thread ends. A
// state whose owner and thread are both gone is garbage like any other
// object, and the GC runs its destructor; nothing here runs one from a
// finalizer, because the GC finalizes garbage in no fixed order.
//
// A thread's own state lives only in that thread's own thread-local
// table (`_held`), never in anything another thread can reach: nothing
// here keeps a table of every thread's state, so nothing here keeps a
// backend alive through a thread that entered it once and moved on, and
// no stale entry can survive for a later thread that happens to get the
// same reused `ThreadID`. `current` reads that table directly, with no
// lock, on every call after this thread's first. Only the first call on
// a thread, which creates this thread's own state, calls
// `attachedThread` to make sure druntime knows the thread (ADR-0005).
//
// `State` is a class or a pointer to a struct. `destroy` is applied to
// the object it names when the state is released.
public struct PerThread(State) {
    // What every thread that holds a state of this `PerThread` shares:
    // the factory that makes a fresh state, and a number that tells this
    // `PerThread` apart from every other one sharing the same `_held`
    // table (the table is `static`, so it is one per `State` type, not
    // one per `PerThread!State` instance).
    private struct Core {
        State delegate() create;
        size_t id;
    }

    private struct Held {
        State state;
    }

    private Core* _core;
    private static Held[size_t] _held;
    private static bool _hooked;

    @disable this();
    @disable this(this);

    public this(State delegate() create) {
        import core.atomic: atomicOp;

        _core = new Core;
        _core.create = create;
        _core.id = atomicOp!"+="(nextId, 1);
    }

    // The calling thread's state, created on its first entry. No lock,
    // and no call to `attachedThread`, once this thread already holds
    // one (ADR-0006's fast path).
    public State current() {
        if (auto held = _core.id in _held)
            return held.state;

        return enter;
    }

    private State enter() {
        attachedThread;
        if (!_hooked) {
            onThreadEnd(&releaseThisThread);
            _hooked = true;
        }

        auto state = _core.create();
        _held[_core.id] = Held(state);
        return state;
    }

    private static void release(State state) {
        static if (is(State == class))
            destroy(state);
        else
            destroy(*state);
    }

    private static void releaseThisThread() {
        foreach (held; _held)
            release(held.state);
        _held = null;
    }
}


private shared size_t nextId;


// The calling thread's druntime identity. A thread druntime does not
// know, such as one a C library created, is registered here, so the GC
// scans its stack from now on, and is unregistered again when it ends.
//
// This never reads a `Thread` object's `id` property: that property is
// `synchronized(this)` (druntime's `ThreadBase.id`), and every entry and
// every callback would then take that object's monitor on every call.
// `pthread_self` gives the same value `Thread.id` would on this
// platform - druntime sets a thread's `m_addr` from `pthread_self` when
// it attaches the thread - without the lock, and without touching the
// `Thread` object at all. `Thread.getThis is null` is a thread-local
// check, so it costs no synchronization either.
public ThreadID attachedThread() {
    import core.sys.posix.pthread: pthread_self;
    import core.thread: thread_attachThis;

    if (Thread.getThis is null) {
        thread_attachThis;
        rt_moduleTlsCtor;
        markForeign;
    }
    return cast(ThreadID) pthread_self();
}


private extern(C) void rt_moduleTlsCtor();
private extern(C) void rt_moduleTlsDtor();


// What to run on the calling thread when it ends. A thread druntime
// created runs these from the module destructor below. A thread this
// module attached runs them from its `pthread` key destructor, which is
// the one hook such a thread offers.
private alias ThreadEndHook = void function();
private ThreadEndHook[] threadEndHooks;

private void onThreadEnd(ThreadEndHook hook) {
    threadEndHooks ~= hook;
}

// Reports a `Throwable` to stderr and swallows it: called only where the
// caller must stay `nothrow` because a `pthread` key destructor that
// throws terminates the process (finding 2.3).
private void report(in char[] what, Throwable throwable) nothrow {
    import core.stdc.stdio: fprintf, stderr;

    fprintf(stderr, "snakebite: %.*s threw: ",
        cast(int) what.length, what.ptr);
    try
        throwable.toString((in chunk) {
            fprintf(stderr, "%.*s", cast(int) chunk.length, chunk.ptr);
        });
    catch (Throwable)
        fprintf(stderr, "<could not format the exception>");
    fprintf(stderr, "\n");
}

private void runThreadEndHooks() nothrow {
    foreach (hook; threadEndHooks) {
        try
            hook();
        catch (Throwable throwable)
            report("a thread-end hook", throwable);
    }
    threadEndHooks = null;
}

static ~this() {
    runThreadEndHooks;
}


private __gshared imported!"core.sys.posix.pthread".pthread_key_t foreignKey;

shared static this() {
    import core.sys.posix.pthread: pthread_key_create;

    if (pthread_key_create(&foreignKey, &detachForeign) != 0)
        throw new Exception("could not create the foreign thread key");
}

private void markForeign() {
    import core.sys.posix.pthread: pthread_setspecific;

    pthread_setspecific(foreignKey, cast(void*) 1);
}

// A `pthread` key destructor: druntime's own documentation for
// `thread_detachThis` (threadbase.d) asks every caller to run
// `rt_moduleTlsDtor` and then the GC's own per-thread cleanup before
// detaching. A key destructor that throws terminates the process, so
// this is `nothrow` and never lets a hook's exception (finding 2.3)
// reach `pthread`.
private extern(C) void detachForeign(void*) nothrow {
    import core.internal.gc.proxy: gc_getProxy;
    import core.thread: thread_detachThis;

    runThreadEndHooks;

    try
        rt_moduleTlsDtor;
    catch (Throwable throwable)
        report("rt_moduleTlsDtor", throwable);

    gc_getProxy.cleanupThread(Thread.getThis);
    thread_detachThis;
}
