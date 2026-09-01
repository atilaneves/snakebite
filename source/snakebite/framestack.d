module snakebite.framestack;


private:


public enum defaultFrameCapacity = 1024 * 1024;
private enum defaultFrameReservation = 1024 * 1024 * 1024;


// The frame stack every guest call reserves its parameter frame from,
// bump-allocated and popped LIFO. `push` is the only way to get bytes from
// it, and the `Frame` it returns is the only way to give them back: a
// call site never marks a position and pops back to it by hand, so it can
// never forget to, on a throw or any other path out of scope.
//
// A pushed frame can hold a guest pointer into GC-owned storage (an array's
// `ptr` field, for instance) for as long as the frame is live, and nothing
// else roots that storage. The committed part of the backing buffer
// therefore stays registered with the GC for its whole lifetime.
public struct FrameStack {
    import core.memory: GC;

    // A byte position: how many bytes of the backing buffer were in use
    // at some earlier point. Never exposed outside this struct - `Frame`
    // is what a call site holds instead.
    private alias Mark = size_t;

    // The reservation never moves. Only pages below `_committed` become
    // readable, so a large reservation costs address space, not physical
    // memory, until a guest call needs it.
    private ubyte* _base;
    private size_t _committed;
    private size_t _limit;
    private size_t _reservation;
    private size_t _used;

    @disable this(this);

    public this(
        size_t capacity,
        size_t reservation = defaultFrameReservation,
    ) @system {
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
    }

    ~this() @system {
        import core.memory: pageSize;
        import core.sys.posix.sys.mman: munmap;

        GC.removeRange(_base);
        if (_base !is null)
            assert(
                munmap(_base, _reservation + pageSize) == 0,
                "could not release the frame stack reservation",
            );
    }

    private Mark mark() const {
        return _used;
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
        import core.memory: pageSize;
        import std.conv: text;

        const mark = this.mark;
        if (size == 0)
            return Frame(&this, mark, null);

        // mmap returns a page-aligned address. A larger alignment would
        // need a separate alignment guarantee and could return a pointer
        // outside the reserved range.
        if (alignment == 0 || alignment > pageSize)
            throw new Exception(
                text("frame stack cannot honor a ", alignment,
                    "-byte alignment: the backing buffer is page-aligned"),
            );

        const alignedUsed = roundUp(mark, alignment);
        if (alignedUsed > _limit || size > _limit - alignedUsed)
            throw new Exception(
                text("frame stack overflow: need ", size,
                    " byte(s) at offset ", alignedUsed, " of ",
                    _limit),
            );

        const end = alignedUsed + size;
        commit(end);
        _used = end;
        return Frame(&this, mark, _base + alignedUsed);
    }

    private void popTo(in Mark mark) {
        assert(mark <= _used, "frame stack popped out of LIFO order");
        _used = mark;
    }

    private void commit(in size_t end) @system {
        import core.memory: pageSize;
        import core.sys.posix.sys.mman: PROT_READ, PROT_WRITE, mprotect;

        const committed = roundUpToPage(end);
        if (committed <= _committed)
            return;

        if (mprotect(
                _base + _committed,
                committed - _committed,
                PROT_READ | PROT_WRITE,
            ) != 0)
            throw new Exception("could not grow the frame stack");

        GC.removeRange(_base);
        GC.addRange(_base, committed);
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
