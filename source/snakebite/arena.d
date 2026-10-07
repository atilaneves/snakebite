// The frontend's bump allocator. dmd allocates this way when it runs
// without `-lowmem` (`dmd.root.rmem.allocmemoryNoFree`): memory is
// handed out once, never reused and never freed, because an AST node
// lives until the compiler exits. Unlike dmd's, this arena is one
// reserved range of address space per region, so any thread can ask
// "is this pointer arena memory?" with a range compare and no lock.
module snakebite.arena;


private:


// dmd's own alignment (`allocmemoryNoFree`): enough for any scalar D has,
// `real` and SIMD vectors included.
public enum arenaAlignment = 16;


// Address space one region reserves. It costs no memory: pages are
// committed as the arena reaches them. A request that does not fit in
// what a region has left starts a new region, big enough for it.
private enum regionReservation = size_t(64) << 30;


// Pages are committed in steps this big, so a run of small requests
// does not make one `mprotect` call each.
private enum commitStep = size_t(4) << 20;


private struct Region {
    ubyte* base;
    size_t reserved;
    // How far the arena got in this region. Read by `walk` only for a
    // region the arena has left; the current region's end is `_top`.
    size_t used;
}


// Readers load the list with one acquire load and never take a lock. A
// list is never changed once published; adding a region publishes a new
// list, and the old one stays valid for a reader still holding it.
private struct RegionList {
    size_t length;
    Region* regions;
}


private shared(RegionList*) _regions;


// Only the thread that holds the frontend lock allocates, so the bump
// state needs no lock of its own.
private __gshared ubyte* _top;
private __gshared ubyte* _committed;
private __gshared ubyte* _end;


// `size` bytes of zeroed arena memory, `arenaAlignment` aligned. The
// memory is never reused, so it is zero the first and only time it is
// handed out. Only the thread that holds the frontend lock calls this.
public void* arenaAllocate(in size_t size) nothrow @nogc {
    if (size == 0)
        return null;

    const rounded = (size + arenaAlignment - 1) & ~(arenaAlignment - 1);
    if (rounded > cast(size_t) (_end - _top))
        startRegion(rounded);
    if (rounded > cast(size_t) (_committed - _top))
        commit(rounded);

    auto result = _top;
    _top += rounded;
    return result;
}


// Whether `pointer` is inside memory the arena reserved. Safe on any
// thread at any time.
// @trusted: compares `pointer` with the region bounds and never reads
// through it.
public bool isArenaMemory(in void* pointer) @trusted nothrow @nogc {
    import core.atomic: atomicLoad, MemoryOrder;

    auto list = cast(RegionList*) atomicLoad!(MemoryOrder.acq)(_regions);
    if (list is null)
        return false;

    foreach (region; list.regions[0 .. list.length])
        if (pointer >= region.base && pointer < region.base + region.reserved)
            return true;
    return false;
}


// How many bytes from `pointer` to the end of the arena memory handed
// out so far in its region. A block reallocated out of the arena copies
// at most this much: the arena does not record block sizes, and the
// bytes past the old block's end but before this point are readable
// arena memory whose value does not matter to the new block.
public size_t arenaBytesAfter(in void* pointer) nothrow @nogc {
    size_t bytes;
    while (!tryBytesAfter(pointer, bytes)) {}
    return bytes;
}


// False when the arena moved on to a region the list it read does not
// have yet: `startRegion` publishes the new list before it moves `_top`,
// so the next try finds it.
private bool tryBytesAfter(in void* pointer, out size_t bytes) nothrow @nogc {
    import core.atomic: atomicLoad, MemoryOrder;

    auto list = cast(RegionList*) atomicLoad!(MemoryOrder.acq)(_regions);
    assert(list !is null);

    foreach (i, region; list.regions[0 .. list.length]) {
        const limit = region.base + region.reserved;
        if (pointer < region.base || pointer >= limit)
            continue;
        if (i + 1 != list.length) {
            bytes = bytesBefore(pointer, region.base + region.used);
            return true;
        }
        const top = cast(const(ubyte)*) atomicLoad!(MemoryOrder.acq)(
            *cast(shared(ubyte*)*) &_top);
        if (top < region.base || top > limit)
            return false;
        bytes = bytesBefore(pointer, top);
        return true;
    }
    assert(0, "not arena memory");
}


private size_t bytesBefore(in void* pointer, in ubyte* end) nothrow @nogc {
    return pointer < end ? end - cast(const(ubyte)*) pointer : 0;
}


// Every word of arena memory handed out so far, in address order. Only
// the thread that holds the frontend lock calls this, so the arena does
// not grow during the walk.
public void walkArenaWords(scope void delegate(const(void*)* word) nothrow @nogc visit)
    nothrow @nogc
{
    import core.atomic: atomicLoad, MemoryOrder;

    auto list = cast(RegionList*) atomicLoad!(MemoryOrder.acq)(_regions);
    if (list is null)
        return;

    foreach (i, region; list.regions[0 .. list.length]) {
        const end = i + 1 == list.length ? _top : region.base + region.used;
        for (auto word = cast(const(void*)*) region.base;
                cast(const(ubyte)*) word < end; ++word)
            visit(word);
    }
}


// Every word of arena memory that can hold a pointer, in address order:
// `walkArenaWords` without the blocks that `recordPointerFreeBlock` named.
// Only the thread that holds the frontend lock calls this.
public void walkArenaPointerWords(scope void delegate(const(void*)* word) nothrow @nogc visit)
    nothrow @nogc
{
    import core.atomic: atomicLoad, MemoryOrder;

    auto list = cast(RegionList*) atomicLoad!(MemoryOrder.acq)(_regions);
    if (list is null)
        return;

    // Blocks are recorded in the order the arena hands them out, which is
    // the order of this walk.
    size_t next;
    foreach (i, region; list.regions[0 .. list.length]) {
        const end = i + 1 == list.length ? _top : region.base + region.used;
        for (auto word = cast(const(void*)*) region.base;
                cast(const(ubyte)*) word < end; ++word) {
            while (next < _pointerFreeCount
                    && _pointerFree[next].end <= cast(const(ubyte)*) word)
                ++next;
            if (next < _pointerFreeCount
                    && _pointerFree[next].start <= cast(const(ubyte)*) word) {
                word = cast(const(void*)*) _pointerFree[next].end - 1;
                continue;
            }
            visit(word);
        }
    }
}


// Every word handed out since `mark` (the start of the arena when it is
// null), then moves `mark` to the end of what is handed out. Only the
// thread that holds the frontend lock calls this.
public void walkArenaWordsSince(
    ref const(ubyte)* mark,
    scope void delegate(const(void*)* word) nothrow @nogc visit)
    nothrow @nogc
{
    import core.atomic: atomicLoad, MemoryOrder;

    auto list = cast(RegionList*) atomicLoad!(MemoryOrder.acq)(_regions);
    if (list is null)
        return;

    size_t first;
    if (mark !is null)
        foreach (i, region; list.regions[0 .. list.length])
            if (mark >= region.base && mark < region.base + region.reserved)
                first = i;

    foreach (i, region; list.regions[0 .. list.length]) {
        if (i < first)
            continue;
        const end = i + 1 == list.length ? _top : region.base + region.used;
        auto start = i == first && mark !is null ? mark : region.base;
        for (auto word = cast(const(void*)*) start;
                cast(const(ubyte)*) word < end; ++word)
            visit(word);
    }
    mark = _top;
}


// Bytes of arena memory handed out so far, across every region.
public size_t arenaUsed() nothrow @nogc {
    import core.atomic: atomicLoad, MemoryOrder;

    auto list = cast(RegionList*) atomicLoad!(MemoryOrder.acq)(_regions);
    if (list is null)
        return 0;

    size_t total;
    foreach (i, region; list.regions[0 .. list.length])
        total += i + 1 == list.length ? _top - region.base : region.used;
    return total;
}


// A block the arena handed out for a D array (druntime asks for it
// APPENDABLE): how much it can hold, and how much of it the array uses.
// druntime appends to an array in place while its block has room, as it
// does in a GC block; without this, every append would copy the whole
// array into a new block, and the arena, which never reuses memory,
// would grow with the square of the array.
public struct ArenaArray {
    size_t capacity;
    size_t used;
}


// The arena's arrays by block start, in C heap memory: the GC does not
// scan it, and it holds only arena addresses and sizes. Only the thread
// that holds the frontend lock reads or changes it.
private struct ArraySlot {
    const(void)* start;
    ArenaArray array;
}

private __gshared ArraySlot[] _arraySlots;
private __gshared size_t _arrayCount;


public void recordArenaArray(in void* start, in ArenaArray array) nothrow @nogc {
    if (2 * (_arrayCount + 1) > _arraySlots.length)
        growArraySlots;
    auto slot = &_arraySlots[findArraySlot(_arraySlots, start)];
    if (slot.start is null)
        ++_arrayCount;
    *slot = ArraySlot(start, array);
}


// The array whose block starts at `start`, or null when no block does.
public ArenaArray* arenaArray(in void* start) nothrow @nogc {
    if (_arraySlots.length == 0)
        return null;
    auto slot = &_arraySlots[findArraySlot(_arraySlots, start)];
    return slot.start is null ? null : &slot.array;
}


// Blocks that druntime allocated NO_SCAN: they hold no pointer, so a word
// in one is data whatever its value. In C heap memory, like the arrays
// above, and merged when a block follows the one before it. Only the
// thread that holds the frontend lock reads or changes it.
private struct PointerFreeRange {
    const(ubyte)* start;
    const(ubyte)* end;
}

private __gshared PointerFreeRange* _pointerFree;
private __gshared size_t _pointerFreeCount;
private __gshared size_t _pointerFreeCapacity;


// `size` bytes at `start`, a block just handed out by `arenaAllocate`.
public void recordPointerFreeBlock(in void* start, in size_t size) nothrow @nogc {
    import core.stdc.stdlib: realloc;

    const first = cast(const(ubyte)*) start;
    const end = first + ((size + arenaAlignment - 1) & ~(arenaAlignment - 1));
    if (_pointerFreeCount != 0 && _pointerFree[_pointerFreeCount - 1].end is first) {
        _pointerFree[_pointerFreeCount - 1].end = end;
        return;
    }
    if (_pointerFreeCount == _pointerFreeCapacity) {
        const capacity = _pointerFreeCapacity == 0 ? 4096 : 2 * _pointerFreeCapacity;
        auto grown = cast(PointerFreeRange*) realloc(
            _pointerFree, capacity * PointerFreeRange.sizeof);
        if (grown is null)
            outOfMemory;
        _pointerFree = grown;
        _pointerFreeCapacity = capacity;
    }
    _pointerFree[_pointerFreeCount++] = PointerFreeRange(first, end);
}


private size_t findArraySlot(ArraySlot[] slots, in void* start) nothrow @nogc {
    const mask = slots.length - 1;
    // Arena blocks are `arenaAlignment` apart: the low bits say nothing.
    auto index = (cast(size_t) start / arenaAlignment * 0x9E3779B97F4A7C15) & mask;
    while (slots[index].start !is null && slots[index].start !is start)
        index = (index + 1) & mask;
    return index;
}


private void growArraySlots() nothrow @nogc {
    import core.stdc.stdlib: calloc, free;

    const length = _arraySlots.length == 0 ? 1024 : 2 * _arraySlots.length;
    auto slots = cast(ArraySlot*) calloc(length, ArraySlot.sizeof);
    if (slots is null)
        outOfMemory;
    auto grown = slots[0 .. length];
    foreach (slot; _arraySlots)
        if (slot.start !is null)
            grown[findArraySlot(grown, slot.start)] = slot;
    free(_arraySlots.ptr);
    _arraySlots = grown;
}


private void startRegion(in size_t atLeast) nothrow @nogc {
    import core.atomic: atomicLoad, atomicStore, MemoryOrder;
    import core.stdc.stdlib: malloc;
    import core.sys.linux.sys.mman: MAP_NORESERVE;
    import core.sys.posix.sys.mman: MAP_ANON, MAP_FAILED, MAP_PRIVATE,
        PROT_NONE, mmap;

    const reserved = atLeast > regionReservation
        ? (atLeast + commitStep - 1) & ~(commitStep - 1)
        : regionReservation;
    auto base = cast(ubyte*) mmap(null, reserved, PROT_NONE,
        MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
    if (base is MAP_FAILED)
        outOfMemory;

    auto previous = cast(RegionList*) atomicLoad!(MemoryOrder.acq)(_regions);
    const count = previous is null ? 0 : previous.length;
    auto regions = cast(Region*) malloc(Region.sizeof * (count + 1));
    auto list = cast(RegionList*) malloc(RegionList.sizeof);
    if (regions is null || list is null)
        outOfMemory;
    if (previous !is null) {
        regions[0 .. count] = previous.regions[0 .. count];
        regions[count - 1].used = _top - regions[count - 1].base;
    }
    regions[count] = Region(base, reserved, 0);
    *list = RegionList(count + 1, regions);

    atomicStore!(MemoryOrder.rel)(_regions, cast(shared) list);
    _committed = base;
    _end = base + reserved;
    atomicStore!(MemoryOrder.rel)(*cast(shared(ubyte*)*) &_top, cast(shared) base);
}


private void commit(in size_t atLeast) nothrow @nogc {
    import core.sys.posix.sys.mman: PROT_READ, PROT_WRITE, mprotect;

    const wanted = _top + atLeast - _committed;
    const step = (wanted + commitStep - 1) & ~(commitStep - 1);
    const size = step < cast(size_t) (_end - _committed)
        ? step
        : cast(size_t) (_end - _committed);
    if (mprotect(_committed, size, PROT_READ | PROT_WRITE) != 0)
        outOfMemory;
    _committed += size;
}


private void outOfMemory() nothrow @nogc {
    import core.exception: onOutOfMemoryError;

    onOutOfMemoryError;
}
