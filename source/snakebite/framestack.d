module snakebite.framestack;


private:


public enum defaultFrameCapacity = 1024 * 1024;


// The frame stack every guest call reserves its parameter frame from,
// bump-allocated and popped LIFO. `push` is the only way to get bytes from
// it, and the `Frame` it returns is the only way to give them back: a
// call site never marks a position and pops back to it by hand, so it can
// never forget to, on a throw or any other path out of scope.
//
// Built on `std.experimental.allocator`'s `Region` building block, which
// supplies the fixed backing buffer, a bump pointer with a bounds check
// (overflow throws; no growth strategy yet), and a `deallocate` that frees
// exactly the block most recently handed out. That is all `Region`
// contributes: alignment above one byte is computed entirely by hand in
// `push`, below - `Region` is built with `minAlign = 1`, so it never
// rounds a request up on its own.
//
// A pushed frame can hold a guest pointer into GC-owned storage (an array's
// `ptr` field, for instance) for as long as the frame is live, and nothing
// else roots that storage. The backing buffer therefore stays registered
// with the GC for its whole lifetime, although `Mallocator` owns it.
public struct FrameStack {
    import core.memory: GC;
    import std.experimental.allocator.building_blocks.region: Region;
    import std.experimental.allocator.mallocator: Mallocator;

    // A byte position: how many bytes of the backing buffer were in use
    // at some earlier point. Never exposed outside this struct - `Frame`
    // is what a call site holds instead.
    private alias Mark = size_t;

    private Region!(Mallocator, 1) _region;
    private size_t _capacity;
    // The backing buffer's own base address, learned once at construction
    // (`allocateAll` hands back the whole buffer; `deallocate` immediately
    // frees it again, leaving the region as empty as a fresh one) since no
    // `Region` member exposes it directly. `popTo` needs it to build the
    // synthetic block it hands back to `Region.deallocate`.
    private ubyte* _base;

    @disable this(this);

    public this(size_t capacity) {
        _region = typeof(_region)(capacity);

        auto whole = _region.allocateAll;
        _capacity = whole.length;
        _base = cast(ubyte*) whole.ptr;
        const freed = _region.deallocate(whole);
        assert(freed, "could not reclaim the frame stack's own buffer");
        GC.addRange(_base, _capacity);
    }

    ~this() {
        GC.removeRange(_base);
    }

    private Mark mark() const {
        return _capacity - _region.available;
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
    public Frame push(in size_t size, in uint alignment) {
        import std.conv: text;

        const mark = this.mark;

        // `Region.allocate(0)` always returns `null` - it treats that as
        // a failed request, not a valid empty one - so a parameterless
        // function's zero-size frame would look like an overflow. There
        // is nothing to write into such a frame anyway, so this reserves
        // nothing for it and hands back a handle whose `base` no caller
        // will dereference.
        if (size == 0)
            return Frame(&this, mark, null);

        // The padding math below only lands a slot on its requested
        // alignment because the buffer's own base is aligned to at least
        // that much. `Mallocator` guarantees `platformAlignment`; a
        // request beyond that would be silently misaligned, so this
        // throws instead.
        if (alignment > Mallocator.alignment)
            throw new Exception(
                text("frame stack cannot honor a ", alignment,
                    "-byte alignment: the backing buffer is only aligned ",
                    "to ", Mallocator.alignment, " byte(s)"),
            );

        const alignedUsed = roundUp(mark, alignment);
        const padding = alignedUsed - mark;

        auto block = _region.allocate(padding + size);
        if (block is null)
            throw new Exception(
                text("frame stack overflow: need ", size,
                    " byte(s) at offset ", alignedUsed, " of ", _capacity),
            );

        return Frame(&this, mark, _base + alignedUsed);
    }

    // Frees every byte reserved since `mark`, in one `Region.deallocate`
    // call regardless of how many `push`es that covers - `Frame`'s
    // destructor is the only caller, and only ever with the mark it was
    // itself pushed at, so this always covers exactly the reservations
    // nested inside that one `Frame`, in the order they nested.
    private void popTo(in Mark mark) {
        const used = this.mark;
        // Nothing was reserved since `mark` - either this was a zero-size
        // reservation, or the reservations nested inside it already
        // popped themselves. `Region.deallocate` only accepts an empty
        // block when its pointer is `null`, and `_base + mark` is not
        // that, so this returns instead of handing it a block it would
        // reject.
        if (used == mark)
            return;

        auto block = _base[mark .. used];
        const popped = _region.deallocate(block);
        assert(popped, "frame stack popped out of LIFO order");
    }

    // The buffer base is already platform-aligned. This only aligns an
    // allocator offset; DMD's aggregate member-layout rules do not apply.
    private static size_t roundUp(
        in size_t offset,
        in uint alignment,
    ) @safe @nogc nothrow pure {
        const remainder = offset % alignment;
        return remainder == 0 ? offset : offset + alignment - remainder;
    }
}
