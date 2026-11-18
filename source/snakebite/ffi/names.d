module snakebite.ffi.names;


// The names of the symbols that a compiled program refers to. A compile
// puts the address of a `Name` where the program refers to a symbol that
// another object defines, or that the process holds (the host executable,
// druntime and the dependency image): the compile needs no address of such
// a symbol. The address of the symbol is found when a word of the program is
// made ready to run, by `CallPlanStore.addressOf`, after a compile to RAM and
// after a load alike.
//
// A datum that the program and another object can both define (a static
// variable of a template instance, the type information that dmd emits in
// each object that needs it) is a name with the program's own copy
// (`Names.defineOwn`). `CallPlanStore.chosenCopy` decides which copy is used
// when the program is made ready to run.
private:

import snakebite.ffi.callplan: NativeSignature;
import snakebite.host.sharedtable: SharedTable;
import snakebite.native.address: DatumRef;


// A symbol, as the program refers to it.
public struct Name {
    @disable this(this);

    private string _symbol;
    private size_t _distance;
    private string _declaredBy;
    private Adjusted* _adjusted;
    private const(void)* _own;
    private DatumRef _ownDatum;

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

    // The start of the program's own copy of the symbol, for a datum that
    // the program and another object can both define, or null.
    public const(void)* own() const @safe pure nothrow @nogc {
        return _own;
    }

    // The datum of the static data of the program that `own` is the start
    // of.
    public DatumRef ownDatum() const @safe pure nothrow @nogc {
        return _ownDatum;
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


// What a program file says of one name (`Names.fromFile`): `symbol`,
// `distance` and `declaredBy`, or, for an entry that forwards to host code
// with an adjustment (`isAdjusted`), the index `code` of the name of that
// code, the adjustment in `distance` and `signature`.
public struct FileName {
    public string symbol;
    public ptrdiff_t distance;
    public string declaredBy;
    public bool isAdjusted;
    public size_t code;
    public NativeSignature signature;
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
    // Whether a program file made the names (`fromFile`).
    private bool _fromFile;

    // The name of the symbol `symbol`, `distance` bytes after its start.
    // `declaredBy` is the declaration of the symbol, kept with a new name. A
    // new name keeps a `string` as it is, and a copy of any other text: it
    // owns what it holds.
    public Name* named(
        Symbol: const(char)[], Declaration: const(char)[] = string,
    )(Symbol symbol, in size_t distance = 0, Declaration declaredBy = null) {
        refuseAfterFile;
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
        refuseAfterFile;
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

    // The names of a program file, for a load, which `make` fills: the
    // symbol, the distance and the declaration of name `index`, or, for the
    // entry that reaches the code of an earlier name with an adjustment, that
    // name, the adjustment and the signature. A file holds each name once, so
    // a name is made with no lookup and no entry in a table: the names are
    // one chunk of the length of the file's table. Nothing names a symbol
    // after a load, because the load has no frontend (ADR-0017), and `named`
    // and `adjusted` refuse it.
    public Name[] fromFile(
        in size_t count,
        scope void delegate(in size_t index, ref FileName made) make,
    ) {
        import core.atomic: atomicLoad, atomicStore, MemoryOrder;
        import snakebite.failure.report: internalFailure, SnakebiteException;

        if (atomicLoad!(MemoryOrder.raw)(_chunkCount) != 0)
            internalFailure("a program file names symbols of a program that "
                ~ "has names");
        _fromFile = true;
        auto chunk = new Name[count];
        foreach (index, ref name; chunk) {
            FileName made;
            make(index, made);
            if (made.isAdjusted) {
                if (made.code >= index)
                    throw new SnakebiteException("the program file names "
                        ~ "the code of an entry before the code itself");
                name._adjusted = new Adjusted(&chunk[made.code],
                    made.distance, made.signature);
            }
            else {
                name._symbol = made.symbol;
                name._distance = cast(size_t) made.distance;
                name._declaredBy = made.declaredBy;
            }
        }
        _chunks[0] = chunk;
        _used = count;
        atomicStore!(MemoryOrder.rel)(_chunkCount, 1);
        return chunk;
    }

    // The name of the symbol of `name`, `distance` bytes further, with the
    // own copy of `name`.
    public Name* further(Name* name, in size_t distance) {
        import snakebite.failure.report: internalFailure;

        if (distance == 0)
            return name;
        if (name.adjusted !is null)
            internalFailure("a word points into an entry of host code");
        auto result = named(name.symbol, name.distance + distance,
            name.declaredBy);
        if (name.own !is null)
            defineOwn(result, name.own, name.ownDatum);
        return result;
    }

    // `start`, the datum `datum` of the static data of the program, becomes
    // the program's own copy of the symbol of `name`, unless it has one: the
    // copy that the program uses when the process does not have the symbol
    // (`CallPlanStore.chosenCopy`). A compile defines it before the name is
    // used, and a load before it makes the program ready to run.
    public void defineOwn(Name* name, const(void)* start, in DatumRef datum) {
        import snakebite.failure.report: internalFailure;

        auto lock = this.lock;
        lock.lock;
        scope(exit) lock.unlock;
        // As a linker keeps the first of two definitions of one symbol.
        if (name._own !is null)
            return;
        if (name._adjusted !is null)
            internalFailure("an entry of host code has an own copy");
        name._own = start;
        name._ownDatum = datum;
    }

    // Each name that has an own copy (`defineOwn`).
    public void eachOwn(scope void delegate(Name*) visit) {
        import core.atomic: atomicLoad, MemoryOrder;

        const count = atomicLoad!(MemoryOrder.acq)(_chunkCount);
        foreach (index, chunk; _chunks[0 .. count])
            foreach (ref name; index + 1 == count ? chunk[0 .. _used] : chunk)
                if (name._own !is null)
                    visit(&name);
    }

    private void refuseAfterFile() const {
        import snakebite.failure.report: internalFailure;

        if (_fromFile)
            internalFailure("a loaded program names a symbol");
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
