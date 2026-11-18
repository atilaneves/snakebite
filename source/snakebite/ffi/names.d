module snakebite.ffi.names;


// The names of the symbols that a compiled program refers to. A compile
// puts the address of a `Name` where the program refers to a symbol that
// another object defines, or that the process holds (the host executable,
// druntime and the dependency image): the compile needs no address of such
// a symbol. The address of the symbol is found when a word of the program is
// made ready to run, by `CallPlanStore.addressOf`, after a compile to RAM and
// after a load alike.
private:

import snakebite.ffi.callplan: NativeSignature;
import snakebite.host.sharedtable: SharedTable;


// A symbol, as the program refers to it.
public struct Name {
    // The symbol, as the linker names it. Empty for an adjusted entry.
    public string symbol;
    // How far the address is from the start of the symbol.
    public size_t distance;
    // For the entry that host code calls to reach the code `code` with the
    // receiver adjustment `adjustment`: those, and the signature of the code.
    // Null for any other name.
    public const(Adjusted)* adjusted;
    // The address, once `CallPlanStore.addressOf` found it.
    package shared(void*) address;
}

// The entry that host code calls to reach host code with a receiver
// adjustment (`CallbackBridge.adjustedEntryOf`).
public struct Adjusted {
    public const(Name)* code;
    public ptrdiff_t adjustment;
    public NativeSignature signature;
}


// The names of one program. A `Name` never moves, so that its address can
// stand for the symbol in the program. Names are made under a lock and read
// without one (ADR-0006).
public struct Names {
    @disable this(this);

    private static struct Key {
        string symbol;
        size_t distance;
    }

    private static struct AdjustedKey {
        const(Name)* code;
        ptrdiff_t adjustment;
    }

    // The names live in chunks, each twice as long as the one before, so
    // that `nameAt` compares an address with a few ranges only.
    private enum firstChunkLength = 64;
    private enum maxChunks = 40;
    private Name[][maxChunks] _chunks;
    private shared size_t _chunkCount;
    // How many names of the last chunk are in use. Under `namesLock` only.
    private size_t _used;
    private SharedTable!(Key, const(Name)*) _plain;
    private SharedTable!(AdjustedKey, const(Name)*) _adjusted;

    // The name of the symbol `symbol`, `distance` bytes after its start.
    public const(Name)* named(string symbol, in size_t distance = 0) {
        const key = Key(symbol, distance);
        if (auto found = key in _plain)
            return *found;

        namesLock.lock;
        scope(exit) namesLock.unlock;
        if (auto found = key in _plain)
            return *found;
        auto name = reserve;
        name.symbol = symbol;
        name.distance = distance;
        return *_plain.insert(key, name);
    }

    // The name of the entry that reaches `code` with `adjustment`. `signature`
    // is the signature of `code`, read only for a new name.
    public const(Name)* adjusted(
        const(Name)* code, in ptrdiff_t adjustment,
        scope NativeSignature delegate() signature,
    ) {
        const key = AdjustedKey(code, adjustment);
        if (auto found = key in _adjusted)
            return *found;

        const made = signature();
        namesLock.lock;
        scope(exit) namesLock.unlock;
        if (auto found = key in _adjusted)
            return *found;
        auto name = reserve;
        name.adjusted = new Adjusted(code, adjustment, cast() made);
        return *_adjusted.insert(key, name);
    }

    // The name that `address` is, or null when it is no name of this.
    public const(Name)* nameAt(in void* address) const @trusted nothrow @nogc {
        import core.atomic: atomicLoad, MemoryOrder;

        const count = atomicLoad!(MemoryOrder.acq)(_chunkCount);
        foreach (chunk; _chunks[0 .. count]) {
            const start = cast(const(void)*) chunk.ptr;
            const end = start + chunk.length * Name.sizeof;
            if (address < start || address >= end)
                continue;
            if ((address - start) % Name.sizeof != 0)
                return null;
            return cast(const(Name)*) address;
        }
        return null;
    }

    // A new name. Under `namesLock`.
    private Name* reserve() {
        import core.atomic: atomicLoad, atomicStore, MemoryOrder;
        import snakebite.failure.report: internalFailure;

        const count = atomicLoad!(MemoryOrder.raw)(_chunkCount);
        if (count == 0 || _used == _chunks[count - 1].length) {
            if (count == maxChunks)
                internalFailure(
                    "a program names more symbols than its names can hold");
            _chunks[count] = new Name[firstChunkLength << count];
            _used = 0;
            atomicStore!(MemoryOrder.rel)(_chunkCount, count + 1);
            return &_chunks[count][_used++];
        }
        return &_chunks[count - 1][_used++];
    }
}


// Names are made rarely and never on a path whose time matters, so all the
// tables of names share one lock.
private __gshared imported!"core.sync.mutex".Mutex namesLock;

shared static this() {
    import core.sync.mutex: Mutex;

    namesLock = new Mutex;
}
