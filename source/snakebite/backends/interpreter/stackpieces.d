module snakebite.backends.interpreter.stackpieces;


private:


import core.thread.fiber: Fiber;
import snakebite.internalfailure: internalFailure;
import snakebite.hostthreads: Continuation;
import core.sync.mutex: Mutex;


private enum pieceBytes = 1024 * 1024;
private enum freePieceCount = 2;


// The walker runs on the native stack that it is entered on, the base.
// Before a guest call it compares the stack pointer with `limit`; below it,
// the walk continues on a piece, a `Fiber` of its own, and comes back when
// the deep part is done. A host call from a piece runs on the base, so host
// code sees the stack and the `Fiber` that compiled D would give it. All
// pieces are called from one loop on the base (ADR-0015).
public struct StackPieces {
    // A guest call starts at an address at or above this one. Zero: no limit.
    public size_t limit;

    private Piece _current;

    // The walker is entered from host code, on the stack that the host code
    // runs on, and no walk is active on this evaluator. The limit is the one
    // of that stack until the entry ends.
    public Entry enter() @system {
        import core.memory: GC;

        if (!GC.inFinalizer) {
            if (_reserve is null)
                _reserve = new Piece;
        }
        limit = limitOfCurrentStack;
        return Entry(&this);
    }

    public struct Entry {
        private StackPieces* _stack;

        @disable this(this);

        public ~this() @safe @nogc nothrow pure {
            _stack.limit = 0;
        }
    }

    // Runs `work` with fresh stack under it.
    public void continueOnNewPiece(scope void delegate() work) @system {
        if (_current is null) {
            drive(work);
            return;
        }
        resumeBaseWith(_current, work, Deeper.yes);
    }

    // Whether the walker runs on the base, not on a piece.
    public bool onBase() const @safe @nogc nothrow pure {
        return _current is null;
    }

    // Runs a host call on the base.
    public void runOnBase(scope void delegate() call) @system {
        if (_current is null) {
            call();
            return;
        }
        resumeBaseWith(_current, call, Deeper.no);
    }

    private enum Deeper { no, yes }

    private void resumeBaseWith(
        Piece piece,
        scope void delegate() request,
        in Deeper deeper,
    ) @system {
        piece.request = request;
        piece.deeper = deeper == Deeper.yes;
        Fiber.yield;
        auto thrown = piece.incoming;
        if (thrown is null)
            return;
        piece.incoming = null;
        throw thrown;
    }

    // Called on the base. A callback under a host call is on the base and
    // can call this again.
    private void drive(scope void delegate() work) @system {
        const baseLimit = limit;
        auto top = take(null, work);
        Throwable thrown;
        while (top !is null) {
            top.incoming = thrown;
            thrown = null;
            _current = top;
            limit = top.limit;
            auto unhandled = top.call(Fiber.Rethrow.no);
            _current = null;
            limit = baseLimit;
            if (top.state == Fiber.State.TERM) {
                auto done = top;
                top = top.below;
                give(done);
                thrown = unhandled;
            } else if (top.deeper) {
                top = take(top, top.request);
            } else {
                try
                    top.request();
                catch (Throwable caught)
                    thrown = caught;
            }
        }
        if (thrown !is null)
            throw thrown;
    }

    private Piece take(Piece below, scope void delegate() work) @system {
        Piece piece;
        foreach (ref slot; _free)
            if (slot !is null) {
                piece = slot;
                slot = null;
                break;
            }
        if (piece is null)
            piece = takeReserveOrNew;
        piece.stack = &this;
        piece.of = Fiber.getThis;
        piece.below = below;
        piece.work = work;
        ++_live;
        return piece;
    }
}


private final class Piece: Continuation {
    public StackPieces* stack;
    public size_t limit;
    public Piece below;
    public void delegate() work;
    public void delegate() request;
    public bool deeper;
    public Throwable incoming;
    public bool borrowed;

    public this() {
        super(&run, pieceBytes);
    }

    private void run() @system {
        ubyte marker;
        limit = cast(size_t) &marker - pieceBytes / 2;
        stack.limit = limit;
        work();
    }
}


private Piece[freePieceCount] _free;
// Made by `enter` outside a finalizer. A finalizer cannot allocate, and
// a destructor that the collector runs always needs a piece to recurse on.
private Piece _reserve;
// A collector can first enter guest code on any host thread. Fiber's
// constructor needs GC storage, so this spare must exist before collection.
private __gshared Piece _finalizerReserve;
private __gshared Mutex _finalizerReserveLock;

shared static this() {
    _finalizerReserve = new Piece;
    _finalizerReserveLock = new Mutex;
}

// The pieces in use on this thread.
private size_t _live;

private Piece takeReserveOrNew() @system {
    import core.memory: GC;

    if (!GC.inFinalizer)
        return new Piece;
    if (_reserve is null && _live == 0) {
        _finalizerReserveLock.lock;
        auto piece = _finalizerReserve;
        _finalizerReserve = null;
        piece.borrowed = true;
        return piece;
    }
    if (_reserve is null)
        internalFailure(
            "A guest destructor that the collector runs needs more stack "
            ~ "than the one piece that is kept for it");
    auto piece = _reserve;
    _reserve = null;
    return piece;
}


private void give(Piece piece) @system {
    --_live;
    piece.stack = null;
    piece.of = null;
    piece.below = null;
    piece.work = null;
    piece.request = null;
    piece.reset;
    if (piece.borrowed) {
        piece.borrowed = false;
        _finalizerReserve = piece;
        _finalizerReserveLock.unlock;
        return;
    }
    if (_reserve is null) {
        _reserve = piece;
        return;
    }
    foreach (ref slot; _free)
        if (slot is null) {
            slot = piece;
            return;
        }
    destroy(piece);
}


private struct Bounds {
    public size_t low;
    public size_t high;
}


private Bounds _threadBounds;


// The guest uses the upper half of a thread's stack. The rest is for what
// has no check: the frames of one guest function, host code, the collector.
private size_t limitOfCurrentStack() @system {
    ubyte here;
    const stackPointer = cast(size_t) &here;
    if (_threadBounds.high == 0)
        _threadBounds = boundsOfThisThread;
    if (stackPointer < _threadBounds.low || stackPointer >= _threadBounds.high)
        return size_t.max;
    return _threadBounds.low + (_threadBounds.high - _threadBounds.low) / 2;
}


private Bounds boundsOfThisThread() @system {
    import core.sys.posix.pthread:
        pthread_attr_destroy, pthread_attr_getstack, pthread_attr_t,
        pthread_self;

    pthread_attr_t attributes;
    if (pthread_getattr_np(pthread_self, &attributes) != 0)
        return Bounds();
    scope(exit) pthread_attr_destroy(&attributes);
    void* low;
    size_t size;
    if (pthread_attr_getstack(&attributes, &low, &size) != 0)
        return Bounds();
    return Bounds(cast(size_t) low, cast(size_t) low + size);
}


// glibc's, and not in druntime's public bindings.
private extern(C) int pthread_getattr_np(
    imported!"core.sys.posix.sys.types".pthread_t,
    imported!"core.sys.posix.pthread".pthread_attr_t*,
) @system nothrow @nogc;
