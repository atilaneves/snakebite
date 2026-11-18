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
// a GC object that the `Program` holds (its stores, and its runner, which
// the callback bridge holds). A loaded program does not grow
// (`loadedProgramGrows`), so no GC array grows from a record in `data`.
//
// The first word of `scanned` points to the `Program`, so a pointer into
// `scanned` keeps the `Program`, its stores and both blocks. A pointer into
// `data` keeps `data` only. Each holder of a pointer into `data` holds the
// `Program` too: the `Program` itself; its `Runner`, which holds the
// `Program`, and with it each frame of a run and each `Function.jit`; a
// start function, in `scanned`; and a slot of a callback entry, a GC root
// that holds the runner.
module snakebite.memory.program;


private:


import snakebite.failure.report: internalFailure;


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


private noreturn doesNotFit() @safe pure nothrow @nogc {
    internalFailure("the memory of a loaded program is full: the save and "
        ~ "the load do not agree on its size, or the program grows");
}


// Ends the process: a loaded program does not grow. The GC does not scan
// `ProgramMemory.data`, so a GC array that grew from a record in it would be
// reached only from memory that the GC does not scan.
public noreturn loadedProgramGrows(
    in string file = __FILE__, in size_t line = __LINE__,
) @safe pure nothrow @nogc {
    internalFailure("a loaded program does not grow", file, line);
}


public struct ProgramMemory {
    @disable this(this);

    public Region data;
    public Region scanned;

    // Whether a load took the memory (`reserve`): the program is loaded.
    public bool isTaken() const @safe pure nothrow @nogc {
        return scanned._block.length != 0;
    }

    // Ends the process unless the load used all of the memory that the file
    // gave: the save and the load agree on each allocation.
    public void checkFull() const @safe pure nothrow @nogc {
        if (!data.isFull || !scanned.isFull)
            internalFailure("a load did not use all of the memory that the "
                ~ "file gives: the save and the load do not agree on its "
                ~ "size");
    }

    // Takes the blocks for `need` from the GC, with `owner` in the first word
    // of `scanned`. Call it once, before the first allocation.
    public void reserve(in MemoryNeed need, const(void)* owner) {
        import core.memory: GC;

        data.take(need.data, GC.BlkAttr.NO_SCAN);
        scanned.take(need.scanned, 0);
        *cast(const(void)**) scanned.allocate(ownerBytes).ptr = owner;
    }
}


// Memory that is given out from the front of one GC block, whose size the
// file gives. The save counts what the load takes, so an allocation that
// does not fit is a fault of snakebite: the save and the load do not agree,
// or a loaded program grows.
public struct Region {
    @disable this(this);

    private void[] _block;
    private size_t _used;

    private void take(in size_t size, in uint attributes) {
        import core.memory: GC;

        if (size != 0)
            _block = GC.calloc(size, attributes)[0 .. size];
    }

    // Whether all of the block is given out.
    public bool isFull() const @safe pure nothrow @nogc {
        return _used == _block.length;
    }

    // `size` bytes of zeroed memory, aligned for any type.
    public void[] allocate(in size_t size) @trusted pure nothrow {
        if (size == 0)
            return null;
        const rounded = bytesFor(size);
        if (rounded > _block.length - _used)
            doesNotFit;
        auto bytes = _block[_used .. _used + size];
        _used += rounded;
        return bytes;
    }

    // As `allocate`, at the start of a page of the block. A page or more of
    // the GC starts at a page.
    public void[] allocateAtPage(in size_t size) @trusted pure nothrow {
        const start = atPage(_used);
        if (_block.length < pageAlignment || start > _block.length
                || bytesFor(size) > _block.length - start)
            doesNotFit;
        _used = start + bytesFor(size);
        return _block[start .. start + size];
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
