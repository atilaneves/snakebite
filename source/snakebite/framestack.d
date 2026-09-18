module snakebite.framestack;


private:

import snakebite.backends.temporarystack: TemporaryStack;
import snakebite.tlsstorage: TlsDescriptor, TlsSlots;


public enum defaultFrameCapacity = 1024 * 1024;
private enum defaultFrameReservation = 1024 * 1024 * 1024;


// The frame stack every guest call reserves its parameter frame from,
// bump-allocated and popped LIFO. `push` is the default way to get bytes
// from it, and the `Frame` it returns gives them back by itself: a call
// site never marks a position and pops back to it by hand, so it can
// never forget to, on a throw or any other path out of scope.
//
// `mark`/`reserve`/`release` are the exception, for a reservation whose
// lifetime is not any host function's lexical scope - the interpreter's
// expression-scoped temporaries outlive every call frame pushed while
// their expression evaluates. A caller of `reserve` owns the release and
// must pair its `mark` with a `scope(exit) release(mark)` of its own.
//
// A pushed frame can hold a guest pointer into GC-owned storage (an array's
// `ptr` field, for instance) for as long as the frame is live, and nothing
// else roots that storage. The committed part of the backing buffer
// therefore stays registered with the GC for its whole lifetime.
public struct FrameStack {
    import core.memory: GC;

    // A byte position: how many bytes of the backing buffer were in use
    // at some earlier point.
    public alias Mark = size_t;

    // The reservation never moves. Only pages below `_committed` become
    // readable, so a large reservation costs address space, not physical
    // memory, until a guest call needs it.
    private ubyte* _base;
    private size_t _committed;
    private size_t _limit;
    private size_t _reservation;
    private size_t _used;
    private void[][] _allocations;
    // Every base address handed to `GC.addRange` so far: one per grown
    // chunk (see `commit`), each removed in turn when this frame stack
    // goes out of scope.
    private ubyte*[] _registeredRanges;
    private TemporaryStack _cleanups;
    // Fiber frame stacks on one thread share these variable slots. A frame
    // stack used alone creates its own slots on first access.
    private TlsSlots* _tls;

    @disable this(this);

    public this(size_t capacity, TlsSlots* tls) @system {
        this(capacity, defaultFrameReservation, tls);
    }

    public this(
        size_t capacity,
        size_t reservation = defaultFrameReservation,
        TlsSlots* tls = null,
    ) @system {
        _tls = tls;
        import core.memory: pageSize;
        import core.sys.posix.sys.mman:
            MAP_ANON, MAP_FAILED, MAP_PRIVATE, PROT_NONE, PROT_READ,
            PROT_WRITE, mmap, mprotect;
        import std.conv: text;

        if (capacity == 0)
            capacity = 1;
        if (reservation < capacity)
            throw new Exception(
                text("frame stack reservation ", reservation,
                    " is smaller than its initial capacity ", capacity),
            );

        _limit = reservation;
        _reservation = roundUpToPage(reservation);
        const mappingSize = _reservation + pageSize;
        _base = cast(ubyte*) mmap(
            null,
            mappingSize,
            PROT_NONE,
            MAP_PRIVATE | MAP_ANON,
            -1,
            0,
        );
        if (_base == cast(ubyte*) MAP_FAILED)
            throw new Exception(
                text("could not reserve ", mappingSize,
                    " bytes for the frame stack"),
            );

        _committed = roundUpToPage(capacity);
        if (mprotect(_base, _committed, PROT_READ | PROT_WRITE) != 0) {
            import core.sys.posix.sys.mman: munmap;

            munmap(_base, mappingSize);
            _base = null;
            throw new Exception(
                text("could not commit ", _committed,
                    " bytes for the frame stack"),
            );
        }

        GC.addRange(_base, _committed);
        _registeredRanges ~= _base;
    }

    ~this() @system {
        import core.memory: pageSize;
        import core.sys.posix.sys.mman: munmap;

        foreach (registered; _registeredRanges)
            GC.removeRange(registered);
        if (_base !is null)
            assert(
                munmap(_base, _reservation + pageSize) == 0,
                "could not release the frame stack reservation",
            );
    }

    public Mark mark() const {
        return _used;
    }

    public size_t cleanupMark() const {
        return _cleanups.mark;
    }

    public void registerCleanup(
        size_t site,
        ubyte* address,
    ) {
        _cleanups.registerTemporary(address, site);
    }

    public void armCleanup(ubyte* address) {
        _cleanups.arm(address);
    }

    public void suspendCleanup(ubyte* address) {
        _cleanups.suspend(address);
    }

    public void finishCleanups(
        in size_t mark,
        scope void delegate(in size_t) destroy,
    ) {
        _cleanups.finish(mark, (in TemporaryStack.Entry entry) {
            destroy(entry.payload);
        });
    }

    // One `push` reservation: `base` is where its bytes start, `null` for
    // a zero-size reservation nothing will dereference. Pops itself, back
    // to the mark it was pushed at, the moment it goes out of scope -
    // copying it would let two handles pop the same bytes, so it can only
    // be moved.
    public struct Frame {
        private FrameStack* _stack;
        private Mark _mark;
        public ubyte* base;

        @disable this(this);

        ~this() {
            if (_stack !is null)
                _stack.popTo(_mark);
        }
    }

    // Bump-allocates `size` bytes aligned to `alignment` and hands back a
    // handle that frees them again when it goes out of scope.
    public Frame push(in size_t size, in uint alignment) @system {
        const mark = this.mark;
        return Frame(&this, mark, reserve(size, alignment));
    }

    // Bump-allocates like `push`, but hands back only the bytes (`null`
    // for a zero-size reservation): the caller owns giving them back with
    // `release`, in LIFO order. See the struct's own comment for who this
    // is for.
    public ubyte* reserve(in size_t size, in uint alignment) @system {
        import core.memory: pageSize;
        import std.conv: text;

        if (size == 0)
            return null;

        // mmap returns a page-aligned address. A larger alignment would
        // need a separate alignment guarantee and could return a pointer
        // outside the reserved range.
        if (alignment == 0 || alignment > pageSize)
            throw new Exception(
                text("frame stack cannot honor a ", alignment,
                    "-byte alignment: the backing buffer is page-aligned"),
            );

        const alignedUsed = roundUp(_used, alignment);
        if (alignedUsed > _limit || size > _limit - alignedUsed)
            throw new Exception(
                text("frame stack overflow: need ", size,
                    " byte(s) at offset ", alignedUsed, " of ",
                    _limit),
            );

        const end = alignedUsed + size;
        commit(end);
        _used = end;
        return _base + alignedUsed;
    }

    // Gives back everything reserved since `mark`. Only for `reserve`d
    // bytes: a `push`ed `Frame` gives its own back.
    public void release(in Mark mark) {
        popTo(mark);
    }

    // This thread's own storage for a thread-local guest variable,
    // starting from `descriptor`'s template on this thread's own first
    // touch of it (finding 1.3). No lock: this `FrameStack`, like the
    // `Vm` that owns it, belongs to exactly one thread.
    public void[] tlsSlotFor(const(TlsDescriptor)* descriptor) {
        if (_tls is null)
            _tls = new TlsSlots;
        return _tls.slotFor(descriptor);
    }

    // Allocates aligned storage whose lifetime is the lifetime of this
    // frame stack. Used for closure objects, which can outlive the frame
    // that created them while a delegate still refers to them.
    public ubyte* allocate(in size_t size, in uint alignment) {
        import core.memory: pageSize;

        if (size == 0)
            return null;
        if (alignment == 0 || alignment > pageSize)
            throw new Exception("frame stack cannot honor this alignment");

        // Captured values can own the only references to other GC objects.
        auto allocation = new void[](size + alignment - 1);
        _allocations ~= allocation;
        const start = -cast(size_t) allocation.ptr & (alignment - 1);
        return cast(ubyte*) allocation.ptr + start;
    }

    private void popTo(in Mark mark) {
        assert(mark <= _used, "frame stack popped out of LIFO order");
        _used = mark;
    }

    private void commit(in size_t end) @system {
        import core.memory: pageSize;
        import core.sys.posix.sys.mman: PROT_READ, PROT_WRITE, mprotect;

        const needed = roundUpToPage(end);
        if (needed <= _committed)
            return;

        // Double what is committed so far until it covers `end`, capped
        // at `_reservation` (`push` already checked `end` fits there).
        // A grow step that committed exactly what the caller asked for
        // registered one GC range per page a slow-growing call chain
        // ever touched - up to about 262000 ranges for one thread's
        // 1 GiB reservation, on a process-wide list every registration
        // locks and every collection walks. Doubling makes the number
        // of grow steps, and so the number of ranges, logarithmic in
        // the reservation instead of linear in the page count
        // (finding 4).
        size_t committed = _committed;
        while (committed < needed)
            committed = committed >= _reservation / 2
                ? _reservation : committed * 2;

        if (mprotect(
                _base + _committed,
                committed - _committed,
                PROT_READ | PROT_WRITE,
            ) != 0)
            throw new Exception("could not grow the frame stack");

        // Growing used to unregister the whole committed range and then
        // register the bigger one back (`GC.removeRange` then
        // `GC.addRange`). That opened a window with nothing registered
        // for bytes that were already live - already holding a guest
        // pointer some other frame still needs - so a collection that
        // ran inside the window skipped scanning them and could free
        // storage this thread was still using. Registering only the
        // newly committed bytes, at their own base address, never
        // unregisters anything already live: the range for the bytes
        // committed so far stays registered the whole time, and the
        // fresh range covers exactly the bytes this call is about to
        // hand out for the first time - nothing in between is ever
        // dropped from the GC's sight.
        auto grown = _base + _committed;
        GC.addRange(grown, committed - _committed);
        _registeredRanges ~= grown;
        _committed = committed;
    }

    private static size_t roundUpToPage(in size_t value)
        @safe @nogc nothrow
    {
        import core.memory: pageSize;

        const remainder = value % pageSize;
        return remainder == 0 ? value : value + pageSize - remainder;
    }

    private static size_t roundUp(
        in size_t offset,
        in uint alignment,
    ) @safe @nogc nothrow pure {
        const remainder = offset % alignment;
        return remainder == 0 ? offset : offset + alignment - remainder;
    }
}
