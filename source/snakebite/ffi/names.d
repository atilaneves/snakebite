module snakebite.ffi.names;


// The names of the symbols that a compiled program refers to. A compile
// puts the address of a `Name` where the program refers to a symbol that
// another object defines, or that the process holds (the host executable,
// druntime and the dependency image): the compile needs no address of such
// a symbol. The address of the symbol is found when a word of the program is
// made ready to run, by `CallPlanStore.wordOfName`, after a compile to RAM
// and after a load alike. A symbol that no object defines is no error then:
// the word is an address where a use of the symbol fails
// (`absentAddressOf`).
//
// A datum that the program and another object can both define (a static
// variable of a template instance, the type information that dmd emits in
// each object that needs it) is a name with the program's own copy
// (`Names.defineOwn`). `CallPlanStore.chosenCopy` decides which copy is used
// when the program is made ready to run.
//
// A program of several files (a build of each module, issue #1015) holds
// functions only: a function that only one compile defines
// (`Definition.rootOwned`) has its symbol in the program file of that
// compile (`Names.defineHere`), as an object file has the symbol of each of
// its definitions. A reference to the symbol from any file reaches it. Two
// definitions of one symbol are an error. A symbol that a file defines goes
// before the process, as a linker takes object files before libraries
// (`CallPlanStore.addressIfPresent`). A datum or a template instance that
// more than one file defines is not covered yet.
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

    // What `CallPlanStore.addressIfPresent` found: the address, `absent`, or
    // null before the first question. A word of a program that refers to a
    // symbol that no object defines holds an address in the span of the
    // symbol (`absentAddressOf`), which this does not keep: the spans are of
    // the process.
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
    // Whether program files made the names (`fromFile`).
    private bool _fromFile;
    // The names of each program file, when program files made the names.
    private Name[][] _fileChunks;
    // The word of the guest function of each symbol that only one compile
    // defines (`defineHere`). Written by a compile to a file, which does not
    // run the program, and by a load, before the program runs: a read takes
    // no lock.
    private const(void)*[string] _definedHere;

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
        return make(symbol, distance, declaredBy, null, DatumRef.init);
    }

    // As `named`, with `start`, the datum `datum` of the static data of the
    // program, as the program's own copy of the symbol (`defineOwn`). A new
    // name has its copy before any thread can find it.
    public Name* namedWithOwn(
        Symbol: const(char)[], Declaration: const(char)[] = string,
    )(
        Symbol symbol, in size_t distance, Declaration declaredBy,
        const(void)* start, in DatumRef datum,
    ) {
        refuseAfterFile;
        auto lock = this.lock;
        lock.lock;
        scope(exit) lock.unlock;
        return make(symbol, distance, declaredBy, start, datum);
    }

    // The name of `symbol` and `distance`, found or made, with the own copy
    // `start` unless that is null. Under `_lock`.
    private Name* make(Symbol, Declaration)(
        Symbol symbol, in size_t distance, Declaration declaredBy,
        const(void)* start, in DatumRef datum,
    ) {
        if (auto found = Key(cast(string) symbol, distance) in _plain) {
            if (start !is null)
                defineOwnLocked(*found, start, datum);
            return *found;
        }
        auto name = reserve;
        name._symbol = owned(symbol);
        name._distance = distance;
        name._declaredBy = owned(declaredBy);
        if (start !is null)
            defineOwnLocked(name, start, datum);
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
    // one chunk of the length of the file's table, one chunk for each file
    // of the program. Two files can each have a name of one symbol. Nothing
    // names a symbol after a load, because the load has no frontend
    // (ADR-0017), and `named` and `adjusted` refuse it. A load runs before
    // the program runs, on one thread.
    public Name[] fromFile(
        in size_t count,
        scope void delegate(in size_t index, ref FileName made) make,
    ) {
        import core.atomic: atomicLoad, MemoryOrder;
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
        _fileChunks ~= chunk;
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
        if (name.own is null)
            return named(name.symbol, name.distance + distance,
                name.declaredBy);
        return namedWithOwn(name.symbol, name.distance + distance,
            name.declaredBy, name.own, name.ownDatum);
    }

    // `start`, the datum `datum` of the static data of the program, becomes
    // the program's own copy of the symbol of `name`, unless it has one: the
    // copy that the program uses when the process does not have the symbol
    // (`CallPlanStore.chosenCopy`). For a load, which gives each name its
    // copy before it makes the program ready to run; a compile names a
    // symbol with its copy in one step (`namedWithOwn`).
    public void defineOwn(Name* name, const(void)* start, in DatumRef datum) {
        auto lock = this.lock;
        lock.lock;
        scope(exit) lock.unlock;
        defineOwnLocked(name, start, datum);
    }

    // Under `_lock`. A copy that comes after the copy that the program uses
    // was chosen (`keep`) would not be used: that is a failure of snakebite.
    private void defineOwnLocked(
        Name* name, const(void)* start, in DatumRef datum,
    ) {
        import core.atomic: atomicLoad, MemoryOrder;
        import snakebite.failure.report: internalFailure;

        if (name._adjusted !is null)
            internalFailure("an entry of host code has an own copy");
        // As a linker keeps the first of two definitions of one symbol.
        if (name._own !is null)
            return;
        if (atomicLoad!(MemoryOrder.raw)(name.address) !is null)
            internalFailure("an own copy of `" ~ name._symbol
                ~ "` comes after the copy that the program uses was chosen");
        name._own = start;
        name._ownDatum = datum;
    }

    // The address that `name` keeps: the one it has, or the one that
    // `choose` gives from the own copy of `name`, which is `Name.absent` for
    // a symbol that no object defines. The own copy is read and the answer
    // kept in one step, under the lock of `defineOwn`.
    package void* keep(
        Name* name, scope void* delegate(const(void)* own) choose,
    ) {
        import core.atomic: atomicLoad, atomicStore, MemoryOrder;

        auto lock = this.lock;
        lock.lock;
        scope(exit) lock.unlock;
        if (auto kept = cast(void*) atomicLoad!(MemoryOrder.raw)(name.address))
            return kept;
        auto made = choose(name._own);
        atomicStore!(MemoryOrder.rel)(name.address, cast(shared(void*)) made);
        return made;
    }

    // `word`, a guest function, is the definition of `symbol`, which only
    // one compile defines: a compile to a file gives each such function of
    // its root modules, and a load each that a file holds. A second
    // definition of one symbol is an error that names the symbol, as a
    // linker reports it.
    public void defineHere(in string symbol, const(void)* word) {
        import snakebite.failure.report: SnakebiteException;

        // `auto`: `Mutex.lock` is not `const`.
        auto lock = this.lock;
        lock.lock;
        scope(exit) lock.unlock;
        if (symbol in _definedHere)
            throw new SnakebiteException(
                "multiple definition of the symbol `" ~ symbol ~ "`");
        _definedHere[symbol] = word;
    }

    // The guest function that defines `symbol` (`defineHere`), or null.
    public const(void)* definitionHere(in char[] symbol) const
            @safe pure nothrow @nogc {
        if (auto found = symbol in _definedHere)
            return *found;
        return null;
    }

    // Each symbol that only one compile defines, with its definition.
    public void eachDefinitionHere(Visit)(scope Visit visit) const {
        foreach (symbol, word; _definedHere)
            visit(symbol, word);
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
        import std.array: staticArray;

        const count = atomicLoad!(MemoryOrder.acq)(_chunkCount);
        foreach (chunks; [_chunks[0 .. count], _fileChunks].staticArray)
            foreach (chunk; chunks) {
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
        return madeLock(_lock);
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

// `lock`, made at the first call.
private imported!"core.sync.mutex".Mutex madeLock(
    ref shared imported!"core.sync.mutex".Mutex lock,
) {
    import core.atomic: atomicLoad, cas, MemoryOrder;
    import core.sync.mutex: Mutex;

    if (auto made = atomicLoad!(MemoryOrder.acq)(lock))
        return cast(Mutex) made;
    cas(&lock, cast(shared(Mutex)) null, cast(shared) new Mutex);
    return cast(Mutex) atomicLoad!(MemoryOrder.acq)(lock);
}


// A symbol that no object defines is an error only when code uses it, not
// when a program that refers to it is made ready to run. A reference to such
// a symbol holds an address in the span of the symbol: address space that
// the process maps with no access. A read, a write or a call through the
// reference faults there, and the fault line is the failure of the symbol
// (`absentFailureAt`).
//
// The spans are of the process, as the addresses of symbols are: one symbol
// has one span, whichever program refers to it. A span is 2 GiB, more than
// the largest variable that dmd accepts (static data is at most `int.max`
// bytes), so that an access to any part of a variable is in its span.
// Address space with no access takes no memory.
private enum absentSpanSize = size_t(1) << 31;
// 2 TiB of the 128 TiB of address space of a process. The last span is
// shared by the symbols that come after the others have their spans.
private enum absentSpanCount = 1024;
// The failure of a use of an address in the shared span.
private enum sharedSpanFailure =
    "a symbol that no object defines was used";

private struct AbsentSymbol {
    string symbol;
    string failure;
}

// A fault handler reads these with no lock: a symbol's entry is written
// before `_absentCount` makes it visible, and the spans are mapped before
// `_absentStart` is set. They change under `_absentLock` only.
private shared(void*) _absentStart;
// The spans that are mapped: `absentSpanCount`, or one shared span when the
// process had no address space for more.
private shared size_t _absentSpans;
// The symbols with a span of their own: the first spans, in order.
private shared size_t _absentCount;
private shared AbsentSymbol[absentSpanCount - 1] _absentSymbols;
private shared imported!"core.sync.mutex".Mutex _absentLock;

// The start of the span of `symbol`, which no object defines. `failure` gives
// the failure of a use of the symbol, for a symbol with no span yet.
public void* absentAddressOf(
    string symbol, scope string delegate() failure,
) {
    import core.atomic: atomicLoad, atomicStore, MemoryOrder;

    auto lock = madeLock(_absentLock);
    lock.lock;
    scope(exit) lock.unlock;
    auto start = cast(void*) atomicLoad!(MemoryOrder.raw)(_absentStart);
    if (start is null)
        start = mapAbsentSpans;
    const count = atomicLoad!(MemoryOrder.raw)(_absentCount);
    foreach (index, ref absent; _absentSymbols[0 .. count])
        if (absent.symbol == symbol)
            return start + index * absentSpanSize;
    const sharedSpan = atomicLoad!(MemoryOrder.raw)(_absentSpans) - 1;
    if (count == sharedSpan)
        return start + sharedSpan * absentSpanSize;
    _absentSymbols[count] = AbsentSymbol(symbol, failure());
    atomicStore!(MemoryOrder.rel)(_absentCount, count + 1);
    return start + count * absentSpanSize;
}

// Maps the spans, or one shared span when the process has no address space
// for all of them: a failure to map is no error of the program, which only
// refers to the symbol. Under `_absentLock`.
private void* mapAbsentSpans() nothrow @nogc {
    import core.atomic: atomicStore, MemoryOrder;
    import core.sys.linux.sys.mman: MAP_NORESERVE;
    import core.sys.posix.sys.mman:
        MAP_ANON, MAP_FAILED, MAP_PRIVATE, mmap, PROT_NONE;
    import snakebite.failure.report: internalFailure;
    import std.range: only;

    enum flags = MAP_PRIVATE | MAP_ANON | MAP_NORESERVE;
    enum noFile = -1;
    enum offset = 0;
    enum oneSpan = 1;

    foreach (spans; only(absentSpanCount, oneSpan)) {
        auto start = mmap(
            null,
            spans * absentSpanSize,
            PROT_NONE,
            flags,
            noFile,
            offset,
        );
        if (start is MAP_FAILED)
            continue;
        atomicStore!(MemoryOrder.raw)(_absentSpans, spans);
        atomicStore!(MemoryOrder.rel)(_absentStart, cast(shared(void*)) start);
        return start;
    }
    internalFailure("no address space for a symbol that no object defines");
}

// The failure of a use of `address`, when it is in the span of a symbol that
// no object defines, else null. A fault handler calls this: it takes no lock
// and makes no allocation.
public string absentFailureAt(in void* address) @trusted nothrow @nogc {
    import core.atomic: atomicLoad, MemoryOrder;

    const start = cast(const(void)*) atomicLoad!(MemoryOrder.acq)(
        _absentStart);
    if (start is null || address < start)
        return null;
    const index = cast(size_t) (address - start) / absentSpanSize;
    if (index >= atomicLoad!(MemoryOrder.raw)(_absentSpans))
        return null;
    return index < atomicLoad!(MemoryOrder.acq)(_absentCount)
        ? cast(string) _absentSymbols[index].failure
        : sharedSpanFailure;
}
