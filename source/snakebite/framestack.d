module snakebite.framestack;


private:


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
    private ubyte[][] _allocations;

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

    public Mark mark() const {
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

    // Allocates aligned storage whose lifetime is the lifetime of this
    // frame stack. Used for closure objects, which can outlive the frame
    // that created them while a delegate still refers to them.
    public ubyte* allocate(in size_t size, in uint alignment) {
        import core.memory: pageSize;

        if (size == 0)
            return null;
        if (alignment == 0 || alignment > pageSize)
            throw new Exception("frame stack cannot honor this alignment");

        auto allocation = new ubyte[](size + alignment - 1);
        _allocations ~= allocation;
        const start = -cast(size_t) allocation.ptr & (alignment - 1);
        return allocation.ptr + start;
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
