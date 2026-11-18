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
    @disable this(this);

    private string _symbol;
    private size_t _distance;
    private string _declaredBy;
    private Adjusted* _adjusted;

    // The symbol, as the linker names it. Empty for an adjusted entry.
    public string symbol() const @safe pure nothrow @nogc {
        return _symbol;
    }

    // How far the address is from the start of the symbol.
    public size_t distance() const @safe pure nothrow @nogc {
        return _distance;
    }

    // The declaration of the symbol, for the failure of a symbol that no
    // object defines, or empty.
    public string declaredBy() const @safe pure nothrow @nogc {
        return _declaredBy;
    }

    // For the entry that host code calls to reach the code `code` with the
    // receiver adjustment `adjustment`: those, and the signature of the code.
    // Null for any other name.
    public inout(Adjusted)* adjusted() inout @safe pure nothrow @nogc {
        return _adjusted;
    }

    // What `CallPlanStore.addressOf` found: the address, `absent`, or null
    // before the first question.
    package shared(void*) address;
    package enum absent = cast(void*) size_t.max;
}

// The entry that host code calls to reach host code with a receiver
// adjustment (`CallbackBridge.adjustedEntryOf`).
public struct Adjusted {
    public Name* code;
    public ptrdiff_t adjustment;
    public NativeSignature signature;
}


// A `T` of this process, or the name of the symbol that stands for it until
// the program is made ready to run. Only `CallPlanStore.ready` gives the `T`
// of a name, so a use of a name as an address does not compile.
public struct Linked(T) {
    // The bits of the value: the `T`, or the address of the `Name`.
    private T _value;
    private Name* _name;

    // A `T` that the program holds.
    public static Linked held(T value) {
        Linked linked;
        linked._value = value;
        return linked;
    }

    // The symbol `name`. For an array, `length` is its length.
    public static Linked named(Name* name, in size_t length = 0) {
        Linked linked;
        linked._name = name;
        static if (is(T == E[], E))
            linked._value = (cast(E*) name)[0 .. length];
        else
            linked._value = cast(T) cast(void*) name;
        return linked;
    }

    // `linked` as a base class `T` of its class `U`.
    public static Linked from(U)(const Linked!U linked) if (is(U : T)) {
        Linked result;
        result._value = cast(T) cast(void*) linked.word;
        result._name = linked.name;
        return result;
    }

    // The name, or null for a `T` that the program holds.
    public Name* name() const @trusted pure nothrow @nogc {
        return cast(Name*) _name;
    }

    static if (is(T == E[], E))
    public size_t length() const @safe pure nothrow @nogc {
        return _value.length;
    }

    public bool isNull() const @safe pure nothrow @nogc {
        static if (is(T == E[], E))
            return _value.ptr is null;
        else
            return _value is null;
    }

    // The `T` that the program holds: never a name.
    public T held() const @trusted {
        import snakebite.failure.report: internalFailure;

        if (_name !is null)
            internalFailure("a name is read as an address");
        return cast(T) _value;
    }

    // The word that a compile writes where the program refers to this: the
    // address of the `T`, or of the name, which the compile records so that
    // the program is made ready to run (`snakebite.native.address.Target`).
    public size_t word() const @trusted pure nothrow @nogc {
        static if (is(T == E[], E))
            return cast(size_t) _value.ptr;
        else
            return cast(size_t) cast(const(void)*) _value;
    }
}


// `text`, or a copy of it when it is not immutable.
private string owned(Text)(Text text) {
    static if (is(Text == string))
        return text;
    else
        return text.idup;
}


// The names of one program. A `Name` never moves, so that its address can
// stand for the symbol in the program. Names are made under a lock and read
// without one (ADR-0006).
public struct Names {
    import core.sync.mutex: Mutex;

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
    // that `nameAt` compares an address with a few ranges only. Chunk
    // `maxChunks - 1` would hold `firstChunkLength << 39` names, more than
    // the address space can: the chunks never run out.
    private enum firstChunkLength = 64;
    private enum maxChunks = 40;
    private Name[][maxChunks] _chunks;
    private shared size_t _chunkCount;
    // How many names of the last chunk are in use. Under `_lock` only.
    private size_t _used;
    private SharedTable!(Key, Name*) _plain;
    private SharedTable!(AdjustedKey, Name*) _adjusted;
    // Names are made rarely and never on a path whose time matters, so the
    // tables of names share one lock. Made at the first new name.
    private shared Mutex _lock;

    // The name of the symbol `symbol`, `distance` bytes after its start.
    // `declaredBy` is the declaration of the symbol, kept with a new name. A
    // new name keeps a `string` as it is, and a copy of any other text: it
    // owns what it holds.
    public Name* named(
        Symbol: const(char)[], Declaration: const(char)[] = string,
    )(Symbol symbol, in size_t distance = 0, Declaration declaredBy = null) {
        if (auto found = Key(cast(string) symbol, distance) in _plain)
            return *found;

        auto lock = this.lock;
        lock.lock;
        scope(exit) lock.unlock;
        if (auto found = Key(cast(string) symbol, distance) in _plain)
            return *found;
        auto name = reserve;
        name._symbol = owned(symbol);
        name._distance = distance;
        name._declaredBy = owned(declaredBy);
        return *_plain.insert(Key(name._symbol, distance), name);
    }

    // The name of the entry that reaches `code` with `adjustment`. `signature`
    // is the signature of `code`, read only for a new name.
    public Name* adjusted(
        Name* code, in ptrdiff_t adjustment,
        scope NativeSignature delegate() signature,
    ) {
        const key = AdjustedKey(code, adjustment);
        if (auto found = key in _adjusted)
            return *found;

        const made = signature();
        auto lock = this.lock;
        lock.lock;
        scope(exit) lock.unlock;
        if (auto found = key in _adjusted)
            return *found;
        auto name = reserve;
        name._adjusted = new Adjusted(code, adjustment, cast() made);
        return *_adjusted.insert(key, name);
    }

    // The name that `address` is, or null when it is no name of this.
    public Name* nameAt(in void* address) const @trusted nothrow @nogc {
        import core.atomic: atomicLoad, MemoryOrder;

        const count = atomicLoad!(MemoryOrder.acq)(_chunkCount);
        foreach (chunk; _chunks[0 .. count]) {
            const start = cast(const(void)*) chunk.ptr;
            const end = start + chunk.length * Name.sizeof;
            if (address < start || address >= end)
                continue;
            if ((address - start) % Name.sizeof != 0)
                return null;
            return cast(Name*) address;
        }
        return null;
    }

    private Mutex lock() {
        import core.atomic: atomicLoad, cas, MemoryOrder;

        if (auto made = atomicLoad!(MemoryOrder.acq)(_lock))
            return cast(Mutex) made;
        cas(&_lock, cast(shared(Mutex)) null, cast(shared) new Mutex);
        return cast(Mutex) atomicLoad!(MemoryOrder.acq)(_lock);
    }

    // A new name. Under `_lock`.
    private Name* reserve() {
        import core.atomic: atomicLoad, atomicStore, MemoryOrder;

        const count = atomicLoad!(MemoryOrder.raw)(_chunkCount);
        if (count == 0 || _used == _chunks[count - 1].length) {
            _chunks[count] = new Name[firstChunkLength << count];
            _used = 0;
            atomicStore!(MemoryOrder.rel)(_chunkCount, count + 1);
            return &_chunks[count][_used++];
        }
        return &_chunks[count - 1][_used++];
    }
}
