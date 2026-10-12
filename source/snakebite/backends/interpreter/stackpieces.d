module snakebite.backends.interpreter.stackpieces;


private:


import core.thread.fiber: Fiber;


enum pieceBytes = 1024 * 1024;
enum freePieceCount = 2;


// The walker runs on the native stack that it is entered on, the base.
// Before a guest call it compares the stack pointer with `limit`; below it,
// the walk continues on a piece, a `Fiber` of its own, and comes back when
// the deep part is done. A host call from a piece runs on the base, so host
// code sees the stack and the `Fiber` that compiled D would give it. All
// pieces are called from one loop on the base (ADR-0015).
public struct StackPieces {
    // A guest call starts at an address at or above this one. Zero: no limit.
    public size_t limit;
    // What `ownerOfCurrentPiece` gives back: the evaluator of this stack.
    public void* owner;

    private size_t _baseLimit;
    private Piece _current;

    // The walker is entered at the top level on the current stack.
    public void enter() @system {
        limit = _baseLimit = limitOfCurrentStack;
    }

    // Runs `work` with fresh stack under it.
    public void continueOnNewPiece(scope void delegate() work) @system {
        import core.memory: GC;

        if (GC.inFinalizer && !hasFreePiece) {
            work();
            return;
        }
        if (_current is null) {
            drive(work);
            return;
        }
        resumeBaseWith(_current, work, true);
    }

    // Runs a host call on the base.
    public void runOnBase(scope void delegate() call) @system {
        if (_current is null) {
            call();
            return;
        }
        resumeBaseWith(_current, call, false);
    }

    // The evaluator whose walker runs on the piece that is running now, or
    // null if the code is not on a piece.
    public static void* ownerOfCurrentPiece() @system {
        auto piece = cast(Piece) Fiber.getThis;
        return piece is null ? null : piece.stack.owner;
    }

    private void resumeBaseWith(
        Piece piece,
        scope void delegate() request,
        in bool deeper,
    ) @system {
        piece.request = request;
        piece.deeper = deeper;
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
            piece = new Piece;
        piece.stack = &this;
        piece.below = below;
        piece.work = work;
        return piece;
    }
}


private final class Piece: Fiber {
    StackPieces* stack;
    size_t limit;
    Piece below;
    void delegate() work;
    void delegate() request;
    bool deeper;
    Throwable incoming;

    this() {
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


private bool hasFreePiece() @safe @nogc nothrow {
    foreach (piece; _free)
        if (piece !is null)
            return true;
    return false;
}


private void give(Piece piece) @system {
    piece.stack = null;
    piece.below = null;
    piece.work = null;
    piece.request = null;
    foreach (ref slot; _free)
        if (slot is null) {
            piece.reset;
            slot = piece;
            return;
        }
    destroy(piece);
}


private struct Bounds {
    size_t low;
    size_t high;
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


// glibc's, and not in druntime's bindings.
private extern(C) int pthread_getattr_np(
    imported!"core.sys.posix.sys.types".pthread_t,
    imported!"core.sys.posix.pthread".pthread_attr_t*,
) @system nothrow @nogc;
