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
// table (`_held`), never in anything another thread can reach: no
// stale entry can survive for a later thread that happens to get the
// same reused `ThreadID`, and no thread ever sees another thread's
// entry. This is a lifetime of its own, though, not a weak one: the
// thread's own table holds every backend's state it ever entered, so a
// long-lived thread - a task pool worker, `main` - keeps every backend
// it ever entered alive for as long as the thread itself lives, even
// after the backend that made a given state is otherwise unreachable
// (finding 5, issue #40 review). `current` reads that table directly,
// with no lock, on every call after this thread's first. Only the
// first call on a thread, which creates this thread's own state, calls
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
    // The last `(core, state)` pair `current` returned on this thread,
    // checked before the associative-array lookup below. Almost every
    // callback in a run comes from the same backend as the one before
    // it, so this turns almost every entry into one integer compare
    // instead of a hash and a probe (finding 11). `size_t.max` never
    // matches a real `_core.id` (it starts at 1, see `nextId`), so an
    // empty cache never looks like a hit.
    private static size_t _cachedId = size_t.max;
    private static State _cachedState;

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
        if (_core.id == _cachedId)
            return _cachedState;

        if (auto held = _core.id in _held) {
            _cachedId = _core.id;
            _cachedState = held.state;
            return held.state;
        }

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
        _cachedId = _core.id;
        _cachedState = state;
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
        // Drop the cache along with the table: a state it still points
        // to is about to be destroyed, and a later entry on the same
        // thread must go through `enter` again to notice.
        _cachedId = size_t.max;
        _cachedState = State.init;
        // Let a later entry on this same thread register a fresh hook.
        // Without this, a thread that enters guest code again after its
        // hooks already ran - a `pthread` key destructor can run before
        // other destructors that then call guest code - would make a
        // state nothing ever releases (finding 10).
        _hooked = false;
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
// module attached runs them from its `pthread` key destructor
// (`detachForeign`), through `rt_moduleTlsDtor`, which reaches this
// module's own destructor the same way it reaches every other
// module's - never by calling `runThreadEndHooks` itself, which would
// be this module hand-rolling one piece of `rt_moduleTlsDtor` on the
// side (finding 6).
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

// Runs every hook this thread registered, then and only then. The
// array is taken out of `threadEndHooks` before any hook runs, so a
// hook that enters guest code again and registers a fresh hook of its
// own - or a second, unexpected call to this same function on this
// thread - never appends to, or reads, the list this call is still
// iterating: each call owns its own local copy, and a second call
// finds nothing left to run instead of a hook whose target is already
// gone (finding 2).
private void runThreadEndHooks() nothrow {
    auto hooks = threadEndHooks;
    threadEndHooks = null;
    foreach (hook; hooks) {
        try
            hook();
        catch (Throwable throwable)
            report("a thread-end hook", throwable);
    }
}

static ~this() {
    // druntime collects garbage after the main thread's module destructors.
    // Guest finalizers still need its state then. Keep that state rooted
    // until process exit; worker threads release theirs when they end.
    if (Thread.getThis !is null && Thread.getThis.isMainThread)
        return;
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

// A `pthread` key destructor: druntime's documentation for
// `thread_detachThis` (threadbase.d) says a caller MAY also run
// `rt_moduleTlsDtor` and then the GC's own per-thread cleanup first,
// but compiled D itself never does this for a foreign thread - it
// calls only `thread_attachThis` on entry and `thread_detachThis`
// before the thread exits. Many foreign threads attaching and
// detaching under concurrent collections crashed inside the GC's own
// per-thread cleanup, `cleanupThread`, reached only through that
// extra, non-public call - and only that call, never `thread_detachThis`
// alone, in every crash a stress run caught. This runs `rt_moduleTlsDtor`
// - every module's thread-local destructors, this one's own
// `static ~this` (`runThreadEndHooks`) included - the same call
// `attachedThread` made on entry was `rt_moduleTlsCtor`, so attach and
// detach run the same pair compiled D documents, symmetric this time
// (finding 6), then detaches through the same, sole public entry point
// compiled D uses, nothing more. A key destructor that throws
// terminates the process, so this is `nothrow` and never lets a
// destructor's exception (finding 2.3) reach `pthread`.
private extern(C) void detachForeign(void*) nothrow {
    import core.thread: thread_detachThis;

    try
        rt_moduleTlsDtor;
    catch (Throwable throwable)
        report("rt_moduleTlsDtor on a foreign thread's detach", throwable);
    thread_detachThis;
}
