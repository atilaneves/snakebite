// The memory of a program that a load made. The GC owns it, as it owns the
// memory of a program that a compile made, but a load takes it in two blocks
// whose sizes the file gives (`MemoryNeed`), not in one block for each array
// of each function. So a load asks the GC for few blocks, and starts no
// collection to get them.
//
// The GC scans `scanned`: guest code stores GC pointers in the static data,
// and the objects of the start data hold the runner. It does not scan
// `data` (`GC.BlkAttr.NO_SCAN`). A pointer in `data` points into the memory
// of the program, to host code and data, to code outside the GC heap, or to
// a GC object that a store of the `Program` holds; the first word of
// `scanned` points to the `Program`. So while any part of the program can be
// reached, the GC keeps the `Program`, its stores and both blocks.
module snakebite.memory.program;


private:


// Enough for any type that a program holds.
private enum alignment = 16;


// The alignment of a block of static data: the GC gives a block of a page or
// more at the start of a page, so a load lays out the data of a block as the
// compile that the save wrote did.
public enum pageAlignment = 4096;


// The bytes of the first word of `ProgramMemory.scanned`.
private enum ownerBytes = (size_t.sizeof + alignment - 1) & ~(alignment - 1);


// The bytes that an allocation of `size` bytes takes from a region.
public size_t bytesFor(in size_t size) @safe pure nothrow @nogc {
    return (size + alignment - 1) & ~(alignment - 1);
}


// The bytes that `Region.append` takes from a region to make an array of
// `length` elements of `T`, one append after the other.
public size_t appendedBytes(T)(in size_t length) @safe pure nothrow @nogc {
    size_t total, capacity;
    foreach (filled; 0 .. length)
        if (filled == capacity) {
            capacity = grownCapacity(capacity);
            total += bytesFor(capacity * T.sizeof);
        }
    return total;
}


private size_t grownCapacity(in size_t capacity) @safe pure nothrow @nogc {
    return capacity == 0 ? 16 : capacity * 2;
}


// The bytes that a load takes from each region of a `ProgramMemory`. A save
// counts them in the order that the load takes them, and the file holds the
// result. `scanned` starts with the first word.
public struct MemoryNeed {
    public size_t data;
    public size_t scanned = ownerBytes;

    // Counts an allocation of `size` bytes from `scanned` at the start of a
    // page (`Region.allocateAtPage`).
    public void scannedAtPage(in size_t size) @safe pure nothrow @nogc {
        scanned = atPage(scanned) + bytesFor(size);
    }
}


private size_t atPage(in size_t offset) @safe pure nothrow @nogc {
    return (offset + pageAlignment - 1) & ~(pageAlignment - 1);
}


public struct ProgramMemory {
    @disable this(this);

    public Region data;
    public Region scanned;

    // Takes the blocks for `need` from the GC, with `owner` in the first word
    // of `scanned`. Call it once, before the first allocation.
    public void reserve(in MemoryNeed need, const(void)* owner) {
        import core.memory: GC;

        data.take(need.data, GC.BlkAttr.NO_SCAN);
        scanned.take(need.scanned, 0);
        *cast(const(void)**) scanned.allocate(ownerBytes).ptr = owner;
    }
}


// Memory that is given out from the front of one GC block. An allocation
// that the block has no room for gets a GC block of its own, which the
// region holds.
public struct Region {
    @disable this(this);

    private void[] _block;
    private size_t _used;
    private uint _attributes;
    // The blocks of the allocations that did not fit.
    private void[][] _more;

    private void take(in size_t size, in uint attributes) {
        import core.memory: GC;

        _attributes = attributes;
        if (size != 0)
            _block = GC.calloc(size, attributes)[0 .. size];
    }

    // `size` bytes of zeroed memory, aligned for any type.
    public void[] allocate(in size_t size) @trusted pure nothrow {
        import core.memory: GC;

        if (size == 0)
            return null;
        const rounded = bytesFor(size);
        if (rounded <= _block.length - _used) {
            auto bytes = _block[_used .. _used + size];
            _used += rounded;
            return bytes;
        }
        auto more = GC.calloc(size, _attributes)[0 .. size];
        _more ~= more;
        return more;
    }

    // As `allocate`, at the start of a page of the block. A page or more of
    // the GC starts at a page.
    public void[] allocateAtPage(in size_t size) @trusted pure nothrow {
        import core.memory: GC;

        const start = atPage(_used);
        if (_block.length >= pageAlignment && start <= _block.length
                && bytesFor(size) <= _block.length - start) {
            _used = start + bytesFor(size);
            return _block[start .. start + size];
        }
        const more = size > pageAlignment ? size : pageAlignment;
        auto block = GC.calloc(more, _attributes)[0 .. more];
        _more ~= block;
        return block[0 .. size];
    }

    // A new `T` with its initial value.
    public T* make(T)() @trusted if (!is(T == class)) {
        import core.lifetime: emplace;

        return emplace(cast(T*) allocate(T.sizeof).ptr);
    }

    // A new object of class `T`, made with `args`.
    public T make(T, Args...)(auto ref Args args) @trusted if (is(T == class)) {
        import core.lifetime: emplace;

        return emplace!T(allocate(__traits(classInstanceSize, T)), args);
    }

    // An array of `count` new `T`, each with its initial value.
    public T[] array(T)(in size_t count) @trusted {
        import core.lifetime: emplace;

        auto elements = (cast(T*) allocate(count * T.sizeof).ptr)[0 .. count];
        static if (!__traits(isZeroInit, T))
            foreach (ref element; elements)
                emplace(&element);
        return elements;
    }

    // Appends `value` to `elements`, which has room for `capacity` elements.
    // When it is full, the elements move to a new array twice as large
    // (`appendedBytes`).
    public void append(T)(ref T[] elements, ref size_t capacity, T value) {
        if (elements.length == capacity) {
            capacity = grownCapacity(capacity);
            auto grown = array!T(capacity);
            grown[0 .. elements.length] = elements[];
            elements = grown[0 .. elements.length];
        }
        elements = elements.ptr[0 .. elements.length + 1];
        elements[$ - 1] = value;
    }
}
