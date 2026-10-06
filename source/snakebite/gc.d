// The process GC: druntime's own conservative GC behind a thin proxy.
//
// dmd allocates its AST from a bump allocator that is never freed and
// never scanned (`dmd.root.rmem`); the AST lives until the compiler
// exits. snakebite runs the frontend in the same process as the guest,
// and the guest must collect like compiled D, so dmd's own switch (turn
// the GC off for the whole process) is not available. Instead, a thread
// inside the frontend - running dmd code that `snakebite.frontend.
// compiler` entered on its behalf - gets every allocation from the arena
// (`snakebite.arena`). Every other thread, and the same thread outside
// the frontend, goes to the conservative GC unchanged, host code that
// holds the frontend lock included. The GC never sees the arena: no
// collection marks the AST.
//
// The one invariant this needs: nothing in the arena may be the only
// reference to GC memory, because no collection looks there. Only dmd
// code runs inside the frontend, what the host hands dmd is copied in,
// and host code reaches dmd for anything that makes or changes AST only
// through the frontend (`snakebite.frontend.compiler.frontend`).
// `arenaPointersIntoGC` checks the invariant; a debug build also stops
// at the first dmd object made outside the frontend.
module snakebite.gc;


private:

import core.gc.gcinterface: GC;


// The name rt_options selects this GC by (`snakebite.process`).
public enum gcName = "snakebite";


// Where the frontend allocates. `arena` is dmd's default; `gc` is dmd's
// `-lowmem`, selected with `--lowmem` (`lowmemHelp`).
private enum FrontendMemory {
    arena,
    gc,
}


public enum lowmemHelp =
    "Allocate frontend memory through the GC (like dmd -lowmem).";


private __gshared FrontendMemory _frontendMemory;


// Every executable calls this once, from its argument parsing, before any
// thread enters the frontend: a change while a thread is inside would mix
// arena and GC memory in one AST.
public void selectFrontendMemory(in bool lowmem) nothrow @nogc {
    import snakebite.arena: arenaUsed;

    const memory = lowmem ? FrontendMemory.gc : FrontendMemory.arena;
    assert(
        memory == _frontendMemory || arenaUsed == 0,
        "the frontend memory is chosen before the frontend first runs",
    );
    _frontendMemory = memory;
}


// Whether the frontend allocates from the GC (`--lowmem`).
// @trusted: reads one plain word that does not change once the frontend
// first runs (`selectFrontendMemory`).
public bool lowmem() @trusted nothrow @nogc {
    return _frontendMemory == FrontendMemory.gc;
}


// How deep this thread is inside the frontend: running dmd code that
// `snakebite.frontend.compiler` entered on its behalf. Only that module
// changes it. Holding the frontend lock is not enough: host code that
// holds the lock allocates from the GC like any other code.
private uint _frontendDepth;


public void enterFrontend() nothrow @nogc {
    ++_frontendDepth;
    debug _frontendStarted = true;
}


// dmd's module constructors make dmd objects before any thread enters
// the frontend (`snakebite.frontend.compiler` makes them again inside).
debug private __gshared bool _frontendStarted;


public void leaveFrontend() nothrow @nogc {
    assert(_frontendDepth != 0);
    --_frontendDepth;
    debug if (_frontendDepth == 0)
        recordStackWords;
}


// dmd's closure frames (`_d_allocmemory`) hold the addresses of the
// stack objects they capture, such as a visitor's `this`, and the arena
// never frees a frame. The stack of a thread that has exited can later
// be GC heap, and the report would take those addresses for pointers.
// The word held an address of the stack of the writing thread when the
// frontend left. The report assumes that such a word is not a GC pointer,
// for as long as it keeps that value. This covers only pthread stacks
// (not fiber or interpreter stacks) and only words in blocks handed out
// since the last record.
debug private struct StackWord {
    const(void*)* word;
    const(void)* value;
}

debug private __gshared StackWord[] _stackWords;
debug private __gshared size_t _stackWordCount;
debug private __gshared const(ubyte)* _recordedUpTo;
debug private size_t _stackLow, _stackHigh;


// Call with the frontend lock held: walks what the frontend allocated
// since the last call.
debug private void recordStackWords() nothrow @nogc {
    import snakebite.arena: walkArenaWordsSince;

    if (_stackHigh == 0)
        findStack;
    walkArenaWordsSince(_recordedUpTo, (const(void*)* word) nothrow @nogc {
        const address = cast(size_t) *word;
        if (address >= _stackLow && address < _stackHigh)
            addStackWord(StackWord(word, *word));
    });
}


debug private void findStack() nothrow @nogc {
    import core.sys.posix.pthread: pthread_attr_destroy, pthread_attr_getstack,
        pthread_attr_t, pthread_self;

    pthread_attr_t attributes;
    void* low;
    size_t size;
    if (pthread_getattr_np(pthread_self, &attributes) != 0)
        assert(0, "no stack bounds");
    pthread_attr_getstack(&attributes, &low, &size);
    pthread_attr_destroy(&attributes);
    _stackLow = cast(size_t) low;
    _stackHigh = _stackLow + size;
}


debug private extern(C) int pthread_getattr_np(size_t thread, void* attributes)
    nothrow @nogc;


debug private void addStackWord(in StackWord entry) nothrow @nogc {
    import core.stdc.stdlib: realloc;

    if (_stackWordCount == _stackWords.length) {
        const length = _stackWords.length == 0 ? 1024 : 2 * _stackWords.length;
        auto grown = cast(StackWord*) realloc(_stackWords.ptr, length * StackWord.sizeof);
        if (grown is null)
            assert(0, "out of memory");
        _stackWords = grown[0 .. length];
    }
    _stackWords[_stackWordCount++] = entry;
}


debug private bool isRecordedStackWord(in void** word) nothrow @nogc {
    foreach (entry; _stackWords[0 .. _stackWordCount])
        if (entry.word is word && entry.value is *word)
            return true;
    return false;
}


// Host code that runs while dmd is on this thread's stack (the frontend
// lock taken again from inside the frontend) is outside the frontend
// until the matching `resumeFrontend`.
public uint suspendFrontend() nothrow @nogc {
    const depth = _frontendDepth;
    _frontendDepth = 0;
    return depth;
}


public void resumeFrontend(in uint depth) nothrow @nogc {
    assert(_frontendDepth == 0);
    _frontendDepth = depth;
}


// @trusted: reads two plain words; `_frontendMemory` does not change
// while any thread is inside the frontend (`selectFrontendMemory`).
private bool allocatesInArena() @trusted nothrow @nogc {
    return _frontendDepth != 0 && _frontendMemory == FrontendMemory.arena;
}


// A dmd object made outside the frontend is GC memory that the AST, in
// the arena, can end up as the only reference to: dmd caches what it
// makes (`Type.pointerTo`, semantic results) in the nodes it was asked
// about. Every dmd object is made inside the frontend, so a debug build
// stops at the first one that is not, with the stack that made it.
// An array of dmd references is host data and is not checked: druntime
// allocates every array APPENDABLE, and no single object.
debug private void requireInsideFrontend(in uint bits, const TypeInfo ti) nothrow @nogc {
    import core.memory: CoreGC = GC;

    if (ti is null || bits & CoreGC.BlkAttr.APPENDABLE || allocatesInArena
            || !_frontendStarted || _frontendMemory == FrontendMemory.gc)
        return;
    const name = dmdTypeName(ti);
    if (name.length == 0)
        return;
    reportOutsideFrontend(name);
}


// The name of `ti` when it is a class or struct that dmd declares, or
// "". Reads only fields the type info already holds: a demangled
// struct name would allocate.
debug private const(char)[] dmdTypeName(const TypeInfo ti) nothrow @nogc {
    if (typeid(ti) is typeid(TypeInfo_Class)) {
        const name = (cast(const TypeInfo_Class) ti).name;
        return name.hasPrefix("dmd.") ? name : null;
    }
    if (typeid(ti) is typeid(TypeInfo_Struct)) {
        const name = (cast(const TypeInfo_Struct) ti).mangledName;
        return name.hasPrefix("S3dmd") ? name : null;
    }
    return null;
}


debug private bool hasPrefix(in char[] name, in string prefix) nothrow @nogc {
    return name.length >= prefix.length && name[0 .. prefix.length] == prefix;
}


debug private void reportOutsideFrontend(in char[] name) nothrow @nogc {
    import core.stdc.stdio: fprintf, stderr;
    import core.stdc.stdlib: abort;

    fprintf(stderr, "dmd object %.*s made outside the frontend\n",
        cast(int) name.length, name.ptr);
    printStack;
    abort;
}


debug private void printStack() nothrow @nogc {
    import core.stdc.stdio: fflush, stderr;

    void*[64] frames;
    const count = backtrace(frames.ptr, cast(int) frames.length);
    fflush(stderr);
    backtrace_symbols_fd(frames.ptr, count, 2);
}


debug private extern(C) int backtrace(void** buffer, int size) nothrow @nogc;
debug private extern(C) void backtrace_symbols_fd(void** buffer, int size, int fd)
    nothrow @nogc;


// Every arena word that points into a GC block breaks the invariant in
// this module's header. The report names each one ("" when there are
// none) with the start of the GC block it points to, which is usually
// enough to tell what kind of data leaked in. Only a thread inside the
// frontend grows the arena, and only while it holds the frontend lock:
// call this with the lock held, so the arena does not grow during the
// walk. The report is plain text, so it adds no pointers to the arena it
// is about.
debug public string arenaPointersIntoGC() {
    import snakebite.arena: isArenaMemory, walkArenaWords;
    import std.format: format;

    static struct Found {
        const(void*)* word;
        const(void)* block;
        size_t size;
    }

    Found[16] shown;
    size_t count;
    walkArenaWords((const(void*)* word) nothrow @nogc {
        const value = *word;
        if (!plausiblePointer(value) || isArenaMemory(value))
            return;
        auto block = _instance._gc.addrOf(cast(void*) value);
        if (block is null || isRecordedStackWord(word))
            return;
        if (count < shown.length)
            shown[count] = Found(word, block, _instance._gc.sizeOf(block));
        ++count;
    });

    if (count == 0)
        return "";

    // The GC block's first bytes say what the leaked data is; the arena
    // words around the pointer say what kept it.
    string report = format!"%s arena words point into the GC heap\n"(count);
    foreach (found; shown[0 .. count < shown.length ? count : shown.length]) {
        const bytes = (cast(const(ubyte)*) found.block)[
            0 .. found.size < 48 ? found.size : 48];
        const offset = cast(const(ubyte)*) *found.word - cast(const(ubyte)*) found.block;
        report ~= format!"  word %s -> GC block %s + %s (%s bytes): %(%02x %) \"%s\"\n"(
            found.word, found.block, offset, found.size, bytes, printable(bytes));
        const from = isArenaMemory(found.word - 4) ? found.word - 4 : found.word;
        report ~= format!"    arena from %s: %(%s %)\n"(from, from[0 .. found.word + 4 - from]);
    }
    return report;
}


debug private string printable(in ubyte[] bytes) {
    import std.algorithm.iteration: map;
    import std.array: array;

    return bytes.map!(b => b >= 0x20 && b < 0x7f ? cast(char) b : '.').array.idup;
}


// Below the first page nothing is mapped, and x86-64 user space ends
// below 2^47: a word outside both is not an address.
private bool plausiblePointer(in void* value) nothrow @nogc {
    const address = cast(size_t) value;
    return address >= 4096 && address < (size_t(1) << 47);
}


private final class SnakebiteGC : GC {
    import core.gc.gcinterface: BlkInfo, RangeIterator, RootIterator;
    import core.memory: GCStats = GC;
    import core.thread.threadbase: ThreadBase;
    import snakebite.arena: ArenaArray, arenaAllocate, arenaBytesAfter, isArenaMemory;

    private GC _gc;

    ~this() {
        destroy(_gc);
    }

    void enable() {
        _gc.enable;
    }

    void disable() {
        _gc.disable;
    }

    void collect() nothrow {
        _gc.collect;
    }

    void minimize() nothrow {
        _gc.minimize;
    }

    uint getAttr(void* p) nothrow {
        return isArenaMemory(p) ? 0 : _gc.getAttr(p);
    }

    uint setAttr(void* p, uint mask) nothrow {
        return isArenaMemory(p) ? 0 : _gc.setAttr(p, mask);
    }

    uint clrAttr(void* p, uint mask) nothrow {
        return isArenaMemory(p) ? 0 : _gc.clrAttr(p, mask);
    }

    void* malloc(size_t size, uint bits, const TypeInfo ti) nothrow {
        debug requireInsideFrontend(bits, ti);
        return allocatesInArena ? arenaBlock(size, bits).base : _gc.malloc(size, bits, ti);
    }

    BlkInfo qalloc(size_t size, uint bits, const scope TypeInfo ti) nothrow {
        debug requireInsideFrontend(bits, ti);
        return allocatesInArena ? arenaBlock(size, bits) : _gc.qalloc(size, bits, ti);
    }

    // Arena memory is zero when it is handed out: it is never reused.
    void* calloc(size_t size, uint bits, const TypeInfo ti) nothrow {
        debug requireInsideFrontend(bits, ti);
        return allocatesInArena ? arenaBlock(size, bits).base : _gc.calloc(size, bits, ti);
    }

    // A D array's block (APPENDABLE) starts out using all `size` bytes,
    // as a GC block does; druntime shrinks that to the array's length.
    // It always keeps one zero byte past its capacity, as a small GC
    // block keeps its length byte there: dmd reads the D strings the host
    // hands it (file names made with `text`, for one) as C strings, and
    // without that byte `strlen` would run on into the next arena block.
    private BlkInfo arenaBlock(in size_t size, in uint bits) nothrow {
        import core.memory: CoreGC = GC;
        import snakebite.arena: ArenaArray, arenaAlignment, recordArenaArray;

        const appendable = bits & CoreGC.BlkAttr.APPENDABLE;
        const reserved = appendable ? size + 1 : size;
        auto base = arenaAllocate(reserved);
        if (base is null)
            return BlkInfo.init;
        const rounded = (reserved + arenaAlignment - 1) & ~(arenaAlignment - 1);
        const capacity = appendable ? rounded - 1 : rounded;
        if (appendable)
            recordArenaArray(base, ArenaArray(capacity, size));
        return BlkInfo(base, capacity, appendable);
    }

    // A block moves into the arena on a thread inside the frontend, and
    // out of it on any other thread. A GC block that moves is freed, as
    // the GC's own realloc does; arena memory is never freed.
    void* realloc(void* p, size_t size, uint bits, const TypeInfo ti) nothrow {
        import core.stdc.string: memcpy;

        if (p is null)
            return malloc(size, bits, ti);

        size_t oldSize;
        if (isArenaMemory(p))
            oldSize = arenaBytesAfter(p);
        else if (allocatesInArena && _gc.addrOf(p) is p)
            oldSize = _gc.sizeOf(p);
        else
            return _gc.realloc(p, size, bits, ti);

        if (size == 0) {
            free(p);
            return null;
        }
        auto moved = malloc(size, bits, ti);
        memcpy(moved, p, oldSize < size ? oldSize : size);
        free(p);
        return moved;
    }

    // Arena blocks do not grow in place, and a thread inside the
    // frontend does not grow a GC block: it gets a new arena block.
    size_t extend(void* p, size_t minsize, size_t maxsize, const TypeInfo ti) nothrow {
        if (isArenaMemory(p) || allocatesInArena)
            return 0;
        return _gc.extend(p, minsize, maxsize, ti);
    }

    size_t reserve(size_t size) nothrow {
        return _gc.reserve(size);
    }

    void free(void* p) nothrow @nogc {
        if (!isArenaMemory(p))
            _gc.free(p);
    }

    void* addrOf(void* p) nothrow @nogc {
        return isArenaMemory(p) ? null : _gc.addrOf(p);
    }

    size_t sizeOf(void* p) nothrow @nogc {
        return isArenaMemory(p) ? 0 : _gc.sizeOf(p);
    }

    BlkInfo query(void* p) nothrow {
        return isArenaMemory(p) ? BlkInfo.init : _gc.query(p);
    }

    GCStats.Stats stats() @safe nothrow @nogc {
        return _gc.stats;
    }

    GCStats.ProfileStats profileStats() @safe nothrow @nogc {
        return _gc.profileStats;
    }

    void addRoot(void* p) nothrow @nogc {
        _gc.addRoot(p);
    }

    void removeRoot(void* p) nothrow @nogc {
        _gc.removeRoot(p);
    }

    @property RootIterator rootIter() @nogc {
        return _gc.rootIter;
    }

    void addRange(void* p, size_t sz, const TypeInfo ti) nothrow @nogc {
        _gc.addRange(p, sz, ti);
    }

    void removeRange(void* p) nothrow @nogc {
        _gc.removeRange(p);
    }

    @property RangeIterator rangeIter() @nogc {
        return _gc.rangeIter;
    }

    // The search reads blocks that another thread may not have initialised
    // yet, and an empty segment holds no finalizer.
    void runFinalizers(const scope void[] segment) nothrow {
        if (segment.length == 0)
            return;
        version(unittest)
            ++_finalizerSearches;
        _gc.runFinalizers(segment);
    }

    bool inFinalizer() nothrow @nogc @safe {
        return _gc.inFinalizer;
    }

    ulong allocatedInCurrentThread() nothrow {
        return _gc.allocatedInCurrentThread;
    }

    // An arena array grows in place only inside the frontend: an element
    // written in place by any other thread could be the only reference
    // to GC memory. Outside it, an arena array is not appendable, so an
    // append copies it into the GC heap. Inside it, a GC array is not
    // appendable either: an append copies it into the arena.
    void[] getArrayUsed(void* ptr, bool atomic = false) nothrow {
        if (!isArenaMemory(ptr))
            return _gc.getArrayUsed(ptr, atomic);
        auto array = arenaArrayAt(ptr);
        return array is null ? null : ptr[0 .. array.used];
    }

    bool expandArrayUsed(void[] slice, size_t newUsed, bool atomic = false) nothrow @trusted {
        if (!isArenaSlice(slice))
            return !allocatesInArena && _gc.expandArrayUsed(slice, newUsed, atomic);
        auto array = arenaArrayEndingWith(slice);
        if (array is null || newUsed > array.capacity)
            return false;
        array.used = newUsed;
        return true;
    }

    // A request that fits the slice as it is grows nothing, so a thread
    // inside the frontend still asks the GC about a GC block.
    size_t reserveArrayCapacity(void[] slice, size_t request, bool atomic = false)
        nothrow @trusted
    {
        if (!isArenaSlice(slice))
            return allocatesInArena && request > slice.length
                ? 0
                : _gc.reserveArrayCapacity(slice, request, atomic);
        auto array = arenaArrayEndingWith(slice);
        return array is null || request > array.capacity ? 0 : array.capacity;
    }

    bool shrinkArrayUsed(void[] slice, size_t existingUsed, bool atomic = false) nothrow {
        if (!isArenaSlice(slice))
            return _gc.shrinkArrayUsed(slice, existingUsed, atomic);
        auto array = arenaArrayAt(slice.ptr);
        if (array is null || existingUsed != array.used || slice.length > existingUsed)
            return false;
        array.used = slice.length;
        return true;
    }

    // The arena array whose block starts at `start`, for a thread inside
    // the frontend; null otherwise. A slice that starts inside a block
    // is not found: druntime then copies, which is always correct.
    private static ArenaArray* arenaArrayAt(in void* start) nothrow @nogc {
        import snakebite.arena: arenaArray;

        return allocatesInArena ? arenaArray(start) : null;
    }

    private static ArenaArray* arenaArrayEndingWith(in void[] slice) nothrow @nogc @trusted {
        auto array = arenaArrayAt(slice.ptr);
        return array is null || array.used != slice.length ? null : array;
    }

    void initThread(ThreadBase thread) nothrow @nogc {
        _gc.initThread(thread);
    }

    void cleanupThread(ThreadBase thread) nothrow @nogc {
        _gc.cleanupThread(thread);
    }
}


// @trusted: reads `slice.ptr` only to compare it with the arena bounds.
private bool isArenaSlice(const void[] slice) @trusted nothrow @nogc {
    import snakebite.arena: isArenaMemory;

    return isArenaMemory(slice.ptr);
}


// The searches for finalizers that the calling thread passed on to druntime.
version(unittest) {
    private size_t _finalizerSearches;

    public size_t finalizerSearches() @safe nothrow @nogc {
        return _finalizerSearches;
    }
}


// Made at compile time: the GC cannot allocate itself.
private __gshared SnakebiteGC _instance = new SnakebiteGC;


private GC createSnakebiteGC() {
    import core.gc.registry: createGCInstance;

    auto conservative = createGCInstance("conservative");
    assert(conservative !is null, "druntime registers the conservative GC");
    _instance._gc = conservative;
    return _instance;
}


// druntime's own GCs register from the shared druntime's C constructors,
// which run before the executable's.
pragma(crt_constructor)
private extern(C) void registerSnakebiteGC() {
    import core.gc.registry: registerGCFactory;

    registerGCFactory(gcName, &createSnakebiteGC);
}
