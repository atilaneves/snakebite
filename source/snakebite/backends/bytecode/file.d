module snakebite.backends.bytecode.file;


// A compiled program in a file: a header, the signatures of the program and
// the list of its modules. The file holds the types of the VM as they are:
// one `transfer` template walks them, and the same body writes a file and
// reads one. A field says where it is declared (`plain`, `relocated`, `hostCode`,
// `setBy`, `unsaved`) how it reaches the file, and a field that says nothing
// stops the build. Only `plain` and `hostCode` fields put bytes in the file.
// Handlers are distances from one handler of `vm.d`, so a file belongs to the
// build that wrote it.
//
// This module imports nothing of the frontend.
private:

import snakebite.backends.bytecode.program: Module, Program;
import snakebite.backends.bytecode.relocation:
    classificationOf, eachRelocated, HostCode, isClassified, Place, Plain,
    Reloc, Relocated, SetBy;
import snakebite.backends.bytecode.runner: Runner, StartFunction;
import snakebite.native.address: DatumRef, Target;
import snakebite.backends.bytecode.vm:
    AssertSite, CallSite, ExceptionHandler,
    Function, hostCodeAt, Instruction, JitSetting,
    Role, Roles, rolesOf, wordAt;
import snakebite.failure.report: internalFailure, SnakebiteException;
import snakebite.image.dependency: DependencyImage;
import snakebite.memory.program: bytesFor, MemoryNeed, pageAlignment,
    ProgramMemory;
import snakebite.ffi.callplan: CallPlan, NativeSignature;
import snakebite.ffi.names: DefinitionHere, Name;
import snakebite.native.staticstore: StaticBlocks, StaticStore;
import snakebite.native.value: TypeFacts;
import snakebite.native.signature: Signature;
import snakebite.start.data:
    dependencyModulesOf, FunctionHandle, GateStorage, MainStart, ModuleStart,
    StartData;
import std.conv: text;
import std.meta: AliasSeq;
import std.traits: FieldNameTuple, Unqual;
import std.typecons: Nullable;


// What precedes the program in a file. The key comes first: a load checks it
// before it uses any other field (ADR-0020).
public struct Header {
    // Names the build that wrote the file (`generatorKey`).
    public string buildKey;
    // The dependency image that the program was compiled with, as an
    // executable names the libraries that it needs. Empty for a program with
    // none, and in a file that a build wrote: the run that puts a program
    // together gives the image.
    public string imagePath;
}


private enum magic = "snakebite-program-v1\n";


// Writes `program`, whole and compiled, to `path`. The file is complete or it
// does not exist: it is written under another name and renamed.
public void saveProgram(
    ref Program program,
    Header header,
    in string path,
) {
    import std.file: remove, rename, write;

    auto body_ = Archive.writing(program);
    transferBody(body_, program, null);

    auto file = Archive.writing(program);
    file.text(magic);
    transferHeader(file, header);
    // The memory that the load of the rest takes, before the rest: the save
    // counts it as it writes the rest (`Archive.need`).
    const needAt = file._written.data.length;
    MemoryNeed need;
    file.scalar(need.data);
    file.scalar(need.scanned);
    // A load reads the header before it has the memory.
    file._need = MemoryNeed.init;
    file.length(body_._signatures.length);
    foreach (signature; body_._signatures) {
        // The walk takes a mutable record; a write changes nothing in it.
        auto record = Signature(signature.parameters.dup, signature.variadic);
        transferSignature(file, record);
    }
    transferTemporary(file, body_._symbols);
    transferNames(file, body_);
    file.append(body_._written.data);
    // Only the body takes scanned memory.
    assert(file._need.scanned == MemoryNeed.init.scanned);
    need.data = file._need.data + body_._need.data;
    need.scanned = body_._need.scanned;
    auto needBytes = file._written.data[needAt .. needAt + 2 * size_t.sizeof];
    needBytes[0 .. size_t.sizeof] =
        (cast(const(ubyte)*) &need.data)[0 .. size_t.sizeof];
    needBytes[size_t.sizeof .. $] =
        (cast(const(ubyte)*) &need.scanned)[0 .. size_t.sizeof];

    const partial = path ~ ".partial";
    scope(failure) {
        import std.file: exists;

        if (partial.exists)
            partial.remove;
    }
    partial.write(file._written.data);
    partial.rename(path);
}


// A program file that is read front to back, one time: first its header,
// then its program (`load`).
public struct ProgramReader {
    @disable this(this);

    private Archive _file;

    // `next` gives the next part of the bytes of the file, and an empty part
    // at the end; `size` is the number of bytes of the file.
    public this(return scope const(ubyte)[] delegate() next, in size_t size) {
        _file = Archive.reading(next, size);
    }

    // The header of the file. Call it once, before `load`.
    public Header header() {
        _file.expectText!magic;
        Header header;
        transferHeader(_file, header);
        return header;
    }
}


// Reads the program files of `readers`, each after its header, into
// `program`: one program, as a linker makes one executable of object files.
// `program` is a new program made with `image` (the dependency image that
// the files were made with, or null) and wired to `runner`. Once the load is
// done, they are as a compile to RAM leaves them: `Program.complete` binds
// every function. An address of a symbol is written only after the last file,
// so that the symbol can be defined by any file.
public void load(
    ProgramReader[] readers,
    ref Program program,
    ref Runner runner,
    in DependencyImage* image,
) {
    import std.algorithm.iteration: map;
    import std.array: array;

    const needs = readers.map!((ref reader) => memoryNeed(reader._file)).array;
    program.memory.reserve(needs);
    program.store.takeFrom(&program.memory);
    foreach (ref reader; readers)
        loadProgram(reader._file, program, runner, image);
    foreach (ref reader; readers)
        reader._file.writeSymbolAddresses;
    // The address of an interface of a class information reads the class
    // information, which can be the program's own copy: it is written once
    // every other address in the data is written.
    foreach (ref reader; readers)
        reader._file.writeAddresses(reader._file._interfaceAddresses);

    program.eachFunction((function_) {
        if (const reason = Program.complete(
                function_,
                program.plans,
                runner.jitSetting,
                runner.jitInstance,
            ))
            throw new SnakebiteException(
                "the program file is not valid: " ~ reason,
            );
    });
    program.memory.checkFull;
}


// The memory that the load of the program of `file` takes, which the file
// gives after its header.
private MemoryNeed memoryNeed(ref Archive file) {
    MemoryNeed need;
    file.scalar(need.data);
    file.scalar(need.scanned);
    // As `Archive.length` checks a count: a size that the rest of the file
    // cannot fill is of a damaged file.
    if (need.data / maxLoadBytesPerFileByte
            + need.scanned / maxLoadBytesPerFileByte > file.unreadLength)
        throw new SnakebiteException(
            "the program file ends before the program does");
    return need;
}


// Reads the program of `file`, after its memory need, into `program`.
private void loadProgram(
    ref Archive file,
    ref Program program,
    ref Runner runner,
    in DependencyImage* image,
) {
    file._image = image;
    file._program = &program;
    file._runner = &runner;
    file._memory = &program.memory;
    program.memory.startFile(&program);
    const signatureCount = file.length(0);
    // The load needs the signatures of the file only while it runs.
    file._signatures = new const(Signature)*[signatureCount];
    foreach (ref interned; file._signatures) {
        Signature signature;
        transferSignature(file, signature);
        interned = program.signatures.intern(
            signature.parameters, signature.variadic);
    }
    transferTemporary(file, file._symbols);
    transferNames(file, file);
    transferBody(file, program, &runner);
}


// The most memory that a load takes for one byte of the file: two pages, for
// a datum that starts a block of static data at a page (`transferBlocks`).
// Each record that a load makes for a byte of the file is smaller.
private enum maxLoadBytesPerFileByte = 2 * pageAlignment;
static assert(Function.sizeof + (Function*).sizeof < maxLoadBytesPerFileByte);
static assert(Module.sizeof + (Module*).sizeof < maxLoadBytesPerFileByte);
static assert(CallSite.sizeof < maxLoadBytesPerFileByte);
static assert(__traits(classInstanceSize, StartFunction)
    < maxLoadBytesPerFileByte);


// A signature of the file. `SignatureTable.intern` copies the parameters, so
// the load needs the record only while it runs.
private void transferSignature(ref Archive archive, ref Signature signature) {
    static assert(FieldNameTuple!Signature
        == AliasSeq!("parameters", "variadic"));

    transferTemporary(archive, signature.parameters);
    archive.transfer(signature.variadic);
}


// The names that the program refers to (`snakebite.ffi.names`), in the order
// of the first reference, so that a name comes after the name of its code. A
// name of a symbol: the index of the symbol, the distance and the end of its
// declaration in one text. A name of an entry that forwards to host code
// with an adjustment: the index of the name of the code, the adjustment and
// the signature of the code. A load makes each name once. `source` is the
// archive that the body was written to; a read archive is its own source.
private void transferNames(ref Archive archive, ref Archive source) {
    // `auto`: `transfer` assigns to the array when the archive reads.
    auto adjusted = source._nameIsAdjusted;
    auto targets = source._nameTargets;
    auto distances = source._nameDistances;
    auto declarationEnds = source._declarationEnds;
    auto declarations = source._declarations;
    auto signatures = source._adjustedSignatures;
    // The load needs the tables only while it runs; the names keep the text
    // of the declarations and the signatures.
    transferTemporary(archive, adjusted);
    transferTemporary(archive, targets);
    transferTemporary(archive, distances);
    transferTemporary(archive, declarationEnds);
    // The text of the declarations as one block of bytes.
    const textLength = archive.length(declarations.length);
    if (archive.isWriting) {
        archive.need!char(textLength);
        archive.bytes(cast(char[]) declarations);
    } else {
        auto text = archive.newArray!char(textLength);
        archive.bytes(text);
        declarations = cast(string) text;
    }
    transferTemporary(archive, signatures);
    if (archive.isWriting)
        return;
    const count = adjusted.length;
    if (targets.length != count || distances.length != count
            || declarationEnds.length != count)
        throw new SnakebiteException(
            "the program file holds names that do not match");
    size_t declarationStart, signature;
    archive._names = archive._program.plans.names.fromFile(count,
        (index, ref made) {
            const end = declarationEnds[index];
            if (end < declarationStart || end > declarations.length)
                throw new SnakebiteException(
                    "the program file holds names that do not match");
            if (!adjusted[index]) {
                made.symbol = archive.symbolNameAt(targets[index]);
                made.distance = cast(ptrdiff_t) distances[index];
                made.declaredBy = declarations[declarationStart .. end];
            } else {
                if (signature >= signatures.length)
                    throw new SnakebiteException(
                        "the program file holds names that do not match");
                made.isAdjusted = true;
                made.code = targets[index];
                made.distance = cast(ptrdiff_t) distances[index];
                made.signature = signatures[signature++];
            }
            declarationStart = end;
        });
}


private void transferHeader(ref Archive archive, ref Header header) {
    foreach (ref field; header.tupleof)
        archive.transfer(field);
}


// A place in the data where a load writes the address of a name
// (`snakebite.ffi.names`) after the last file.
private struct PendingAddress {
    // Where the address is written.
    ubyte* place;
    // The name whose address it is.
    Target target;
}


// A gate that is the data of a name. A load gives it its bytes after the last
// file.
private struct PendingGate {
    // The storage of the gate.
    GateStorage* gate;
    // The name whose data the gate is.
    Target target;
    // The number of bytes of the data.
    size_t length;
}


// Where a function is in a file: the index of its module, then its index in
// the functions of the module.
private alias FunctionPosition = size_t[2];


// The bytes of a file as they are written or read, and the places that the
// file refers to by number: the signatures of the program and the functions
// of its modules.
private struct Archive {
    import std.array: Appender;

    private enum Direction { writing, reading }

    private Direction _direction;
    private Appender!(ubyte[]) _written;
    // Reading: the bytes of the part of the file that are not read yet, what
    // gives the parts that come after it, and the number of bytes of the file
    // in those parts.
    private const(ubyte)[] _unread;
    private const(ubyte)[] delegate() _next;
    private size_t _left;
    // The signatures, in the order of the first reference.
    private const(Signature)*[] _signatures;
    private size_t[const(Signature)*] _signatureIndex;
    // Writing: the place of each function. Reading: the function at a place.
    private FunctionPosition[const(Function)*] _positionOf;
    private size_t[const(ModuleStart)*] _moduleOfStart;
    // Writing: the place of each plan of the store. Reading: the plan at a
    // place.
    private size_t[const(CallPlan)*] _planIndex;
    // The names of the host code that the program refers to, in the order of
    // the first reference.
    private string[] _symbols;
    private size_t[string] _symbolIndex;
    private CallPlan*[] _plans;
    // Reading: the relocations of names, from the read of their function to
    // `Program.complete`.
    private Reloc[][] _namedRelocs;
    // The names that the program refers to (`transferNames`). Writing: the
    // index of each name, and what makes it again. Reading: the names.
    private size_t[const(Name)*] _nameIndex;
    private bool[] _nameIsAdjusted;
    private size_t[] _nameTargets;
    private size_t[] _nameDistances;
    private size_t[] _declarationEnds;
    private string _declarations;
    private NativeSignature[] _adjustedSignatures;
    private Name[] _names;
    // A load writes these after the last file (`load`), because a symbol
    // can be defined by any file and a class information can be the program's
    // own copy. The places in the data that hold the address of a symbol, the
    // gates whose bytes are the data of a symbol, and the places in the data
    // that hold the address of an interface of a class information.
    private PendingAddress[] _symbolAddresses;
    private PendingGate[] _symbolGates;
    private PendingAddress[] _interfaceAddresses;
    // The modules of this file are the `_numModules` modules of the program
    // that start at `_firstModule`. A save writes all modules of the program.
    // A load gives the data that no D module owns to one more module after
    // them (`numBlockSets`).
    private size_t _firstModule;
    private size_t _numModules;
    // The index, in the strings of the store of the program, of the first
    // string of this file. A load sets it.
    private size_t _firstStringIndexInStore;
    private Runner* _runner;
    private Program* _program;
    private const(DependencyImage)* _image;
    // Reading: the memory of the program, once there is a program.
    private ProgramMemory* _memory;
    // Writing: the memory that a load of what this wrote takes.
    private MemoryNeed _need;

    // `count` new elements, in the data of the memory of the program once
    // there is one. A writer counts them with `need`.
    T[] newArray(T)(in size_t count) {
        return _memory is null ? new T[count] : _memory.data.array!T(count);
    }

    // Counts what `newArray!T(count)` takes on a load.
    void need(T)(in size_t count) {
        _need.data += bytesFor(count * T.sizeof);
    }

    static Archive writing(ref Program program) {
        Archive archive;
        archive._direction = Direction.writing;
        archive._program = &program;
        program.plans.eachPlan((plan, signature, name, failure) {
            archive._planIndex[plan] = archive._planIndex.length;
        });
        foreach (m, module_; program._modules) {
            archive._moduleOfStart[&module_.start] = m;
            foreach (f, function_; module_._functions)
                archive._positionOf[function_] = [m, f];
        }
        archive._numModules = program._modules.length;
        return archive;
    }

    // The sets of blocks of this file: one for each module, then one for the
    // data that no D module owns.
    size_t numBlockSets() const {
        return _numModules + 1;
    }

    // Module `index` of this file.
    Module* moduleAt(in size_t index) {
        return _program._modules[_firstModule + index];
    }

    // Each function of the modules of this file.
    void eachFunction(Visit)(scope Visit visit) {
        foreach (m; 0 .. _numModules)
            foreach (function_; moduleAt(m)._functions)
                visit(function_);
    }

    // Writes the addresses of the symbols that the places in the data and the
    // gates name.
    void writeSymbolAddresses() {
        writeAddresses(_symbolAddresses);
        foreach (named; _symbolGates) {
            // `auto`: the bytes of a gate are mutable.
            auto data = cast(ubyte*) _program.plans.wordOfName(named.target);
            named.gate.bytes = data[0 .. named.length];
        }
    }

    // Writes at each of `pending` the address of its name.
    void writeAddresses(PendingAddress[] pending) {
        foreach (address; pending)
            writeWord(address.place, _program.plans.wordOfName(address.target));
    }

    static Archive reading(
        return scope const(ubyte)[] delegate() next, in size_t size,
    ) {
        Archive archive;
        archive._direction = Direction.reading;
        archive._next = next;
        archive._left = size;
        return archive;
    }

    bool isWriting() const @safe pure nothrow @nogc {
        return _direction == Direction.writing;
    }

    void append(in ubyte[] data) {
        _written.put(data);
    }

    void text(in string literal) {
        _written.put(cast(const(ubyte)[]) literal);
    }

    void expectText(string literal)() {
        ubyte[literal.length] read;
        if (unreadLength < read.length)
            throw new SnakebiteException(
                "the file is not a snakebite program of this format");
        bytes(read[]);
        if (read[] != cast(const(ubyte)[]) literal)
            throw new SnakebiteException(
                "the file is not a snakebite program of this format");
    }

    // The bytes of `data` go to the file, or come from it.
    void bytes(void[] data) {
        if (isWriting) {
            _written.put(cast(const(ubyte)[]) data);
            return;
        }
        auto to = cast(ubyte[]) data;
        if (to.length > _unread.length)
            return readAcrossParts(to);
        to[] = _unread[0 .. to.length];
        _unread = _unread[to.length .. $];
    }

    // The number of bytes of the file that are not read.
    size_t unreadLength() const @safe pure nothrow @nogc {
        return _unread.length + _left;
    }

    // Reads `to` from the rest of this part and from the parts after it.
    private void readAcrossParts(ubyte[] to) {
        if (to.length > unreadLength)
            throw new SnakebiteException(
                "the program file ends before the program does");
        while (to.length > _unread.length) {
            to[0 .. _unread.length] = _unread[];
            to = to[_unread.length .. $];
            _unread = _next();
            if (_unread.length == 0)
                throw new SnakebiteException(
                    "the program file ends before the program does");
            // Bytes after the size that the caller gave are not the file.
            if (_unread.length > _left)
                _unread = _unread[0 .. _left];
            _left -= _unread.length;
        }
        to[] = _unread[0 .. to.length];
        _unread = _unread[to.length .. $];
    }

    void scalar(T)(ref T value) {
        if (!isWriting && T.sizeof <= _unread.length) {
            import core.stdc.string: memcpy;

            memcpy(cast(void*) &value, _unread.ptr, T.sizeof);
            _unread = _unread[T.sizeof .. $];
            return;
        }
        bytes((cast(ubyte*) &value)[0 .. T.sizeof]);
    }

    // The length of an array, which a reader checks against what is left.
    size_t length(in size_t length) {
        size_t count = length;
        scalar(count);
        if (!isWriting && count > unreadLength)
            throw new SnakebiteException(
                "the program file ends before the program does");
        return count;
    }

    size_t signatureIndex(const(Signature)* signature) {
        if (auto found = signature in _signatureIndex)
            return *found;
        const index = _signatures.length;
        _signatures ~= signature;
        _signatureIndex[signature] = index;
        return index;
    }

    const(Signature)* signatureAt(in size_t index) {
        if (index >= _signatures.length)
            throw new SnakebiteException(
                "the program file names a signature that it does not hold");
        return _signatures[index];
    }

    FunctionPosition positionOf(const(Function)* function_) {
        if (auto found = function_ in _positionOf)
            return *found;
        internalFailure("a function points at a function that no module holds");
    }

    // The blocks of module `index` of the file, or the blocks of the data
    // that no D module owns for the index that follows the last module; null
    // for any other. A save takes those of the process store; a load gives
    // them to the module after the modules of the file.
    StaticBlocks* blocksAt(in size_t index) {
        if (index < _numModules)
            return &moduleAt(index).blocks;
        if (index == _numModules)
            return isWriting ? _program.store.blocks : &moduleAt(index).blocks;
        return null;
    }

    // The module, block and offset of a place in the blocks `set`, when the
    // program holds them.
    size_t[3] blocksPosition(
        in const(void)* set, in size_t block, in size_t offset,
    ) {
        if (set !is null)
            foreach (m; 0 .. numBlockSets)
                if (blocksAt(m) is set)
                    return [m, block, offset];
        internalFailure("a word points at data that the program does not hold");
    }

    // What a gate (storage of a variable of the program, as `GateStorage`
    // holds) is: its datum in the blocks of the program, or a host symbol.
    Target.Kind gateTarget(in GateStorage gate, out size_t[3] reference) {
        if (gate.where.set !is null) {
            reference = blocksPosition(
                gate.where.set, gate.where.block, gate.where.offset);
            return Target.Kind.staticData;
        }
        // Storage that another object defines: the name of its symbol.
        reference = nameReference(gate.ptr);
        return Target.Kind.hostSymbol;
    }

    void* dataAt(in size_t[3] position) {
        if (auto blocks = blocksAt(position[0]))
            if (auto address = blocks.addressOf(position[1], position[2]))
                return address;
        throw new SnakebiteException(
            "the program file names data that it does not hold");
    }

    // String and offset of an address in a string of the process store.
    size_t[3] stringPosition(const(void)* address) {
        size_t index, offset;
        if (_program.store.locateString(address, index, offset))
            return [index, offset, 0];
        internalFailure("a word points at a string that the program does not hold");
    }

    void* stringAt(in size_t[3] position) {
        if (auto address = _program.store.addressInString(
                _firstStringIndexInStore + position[0], position[1]))
            return address;
        throw new SnakebiteException(
            "the program file names a string that it does not hold");
    }

    // The name that `address` stands for (`snakebite.ffi.names`).
    Name* nameAt(const(void)* address) {
        if (auto name = _program.plans.names.nameAt(address))
            return name;
        internalFailure("a word points at host code or data that has no name");
    }

    // The reference to the name `address`: its index in the table of names.
    size_t[3] nameReference(const(void)* address) {
        return [nameIndexOf(nameAt(address)), 0, 0];
    }

    // The index of `name` in the table of names, which the call plans and
    // the words that name a symbol share. A name of an adjusted entry comes
    // after the name of its code.
    size_t nameIndexOf(const(Name)* name) {
        if (auto found = name in _nameIndex)
            return *found;
        if (auto adjusted = name.adjusted) {
            _nameTargets ~= nameIndexOf(adjusted.code);
            _nameDistances ~= cast(size_t) adjusted.adjustment;
            _adjustedSignatures ~= cast() adjusted.signature;
        } else {
            _nameTargets ~= symbolIndexOfName(name.symbol);
            _nameDistances ~= name.distance;
            _declarations ~= name.declaredBy;
        }
        _nameIsAdjusted ~= name.adjusted !is null;
        _declarationEnds ~= _declarations.length;
        return _nameIndex[name] = _nameIndex.length;
    }

    // The name at `index` in the table of names.
    Name* nameOfIndex(in size_t index) {
        if (index >= _names.length)
            throw new SnakebiteException(
                "the program file names a symbol that it does not hold");
        return &_names[index];
    }

    // The index of `name` in the table of the symbols of the names.
    size_t symbolIndexOfName(in string name) {
        if (auto found = name in _symbolIndex)
            return *found;
        _symbols ~= name;
        return _symbolIndex[name] = _symbols.length - 1;
    }

    string symbolNameAt(in size_t index) {
        if (index >= _symbols.length)
            throw new SnakebiteException(
                "the program file names a symbol that it does not hold");
        return _symbols[index];
    }

    size_t planIndexOf(const(CallPlan)* plan) {
        if (auto found = plan in _planIndex)
            return *found;
        internalFailure("a call site names a call plan that the store does not hold");
    }

    const(CallPlan)* planAt(in size_t index) {
        if (index >= _plans.length)
            throw new SnakebiteException(
                "the program file names a call plan that it does not hold");
        return _plans[index];
    }

    // The entry that host code calls to reach a guest function, as a compile
    // makes it: with the function and the signature it registered.
    const(void)* entryAt(in size_t[3] reference) {
        const word = functionAt(reference[0], reference[1]);
        auto callbacks = _program.plans.callbacks;
        return callbacks.adjustedEntryOf(
            word, *callbacks.signatureOf(word), cast(ptrdiff_t) reference[2]);
    }

    Function* functionAt(in size_t module_, in size_t index) {
        if (module_ >= _numModules
                || index >= moduleAt(module_)._functions.length)
            throw new SnakebiteException(
                "the program file names a function that it does not hold");
        return moduleAt(module_)._functions[index];
    }
}


// Data with no address in it: scalars, and arrays and structs of those. A
// type that is not of the VM has to be this to be written as it is.
private template isPureData(T) {
    static if (is(T == enum))
        enum isPureData = true;
    else static if (is(T : real) || is(T == bool) || is(T : dchar))
        enum isPureData = true;
    else static if (is(T == E[], E))
        enum isPureData = isPureData!(Unqual!E);
    else static if (is(T == E[N], E, size_t N))
        enum isPureData = isPureData!(Unqual!E);
    else static if (is(T == struct))
        enum isPureData = fieldsArePure!(Unqual!T);
    else
        enum isPureData = false;
}

private bool fieldsArePure(T)() {
    import std.traits: Fields;

    static foreach (Field; Fields!T)
        if (!isPureData!(Unqual!Field))
            return false;
    return true;
}

// Whether field `index` shares bytes with an earlier field of the union.
private template overlapsEarlier(T, size_t index) {
    private bool compute() {
        bool overlaps;
        static foreach (earlier; 0 .. index)
            if (T.tupleof[earlier].offsetof < T.tupleof[index].offsetof
                    + T.tupleof[index].sizeof
                && T.tupleof[index].offsetof < T.tupleof[earlier].offsetof
                    + T.tupleof[earlier].sizeof)
                overlaps = true;
        return overlaps;
    }

    enum overlapsEarlier = compute;
}


// The word an address field holds, for a field of a pointer type.
private size_t wordOf(F)(ref const F field) {
    static if (is(F == delegate))
        return cast(size_t) field.funcptr;
    else
        return cast(size_t) cast(const(void)*) field;
}

private enum holdsAddress(F) = is(F == U*, U) || is(F == delegate)
    || is(F == class) || is(F == interface);


// The dependency image has the module information of the dependencies, not
// the file.
private void transfer(
    ref Archive archive, ref const(ModuleInfo*)[] modules,
) {
    if (!archive.isWriting)
        modules = dependencyModulesOf(archive._image);
}


private enum isNullable(T) = is(T == Nullable!U, U);


private void transfer(T)(ref Archive archive, ref T value)
if (isNullable!T) {
    alias U = typeof(value.get());
    bool present = !value.isNull;
    archive.scalar(present);
    if (!present)
        return;
    if (archive.isWriting)
        archive.transfer(value.get);
    else {
        U payload;
        archive.transfer(payload);
        value = payload;
    }
}


// The one walk. It writes `value` to the file, or reads the file into it.
private void transfer(T)(ref Archive archive, ref T value)
if (!isNullable!T) {
    static if (is(T == enum)) {
        archive.scalar(value);
    } else static if (is(T : real) || is(T == bool) || is(T : dchar)) {
        archive.scalar(value);
    } else static if (is(T == E[], E)) {
        // A load needs the relocations only while it runs: it applies them,
        // and `Program.complete` the ones of names (`transferModule`).
        static if (is(Unqual!E == Reloc))
            transferTemporary(archive, value);
        else {
            const count = archive.length(value.length);
            if (archive.isWriting) {
                archive.need!(Unqual!E)(count);
                foreach (ref element; value)
                    archive.transfer(element);
            } else {
                auto fresh = archive.newArray!(Unqual!E)(count);
                foreach (ref element; fresh)
                    archive.transfer(element);
                value = cast(T) fresh;
            }
        }
    } else static if (is(T == E[N], E, size_t N)) {
        foreach (ref element; value)
            archive.transfer(element);
    } else static if (is(Unqual!T == Reloc)) {
        transferReloc(archive, value);
    } else static if (is(Unqual!T == Instruction)
            || is(Unqual!T == CallSite) || isClassified!(Unqual!T)) {
        transferClassified(archive, value);
    } else static if (is(T == struct)) {
        // The start data have addresses; each field goes through the branch
        // of its type.
        static assert(is(Unqual!T == StartData) || is(Unqual!T == ModuleStart)
            || is(Unqual!T == MainStart) || isPureData!(Unqual!T),
            T.stringof ~ " is neither a type of the VM, start data nor data "
            ~ "without an address");
        static foreach (index, name; FieldNameTuple!T)
            archive.transfer(value.tupleof[index]);
    } else
        static assert(false, "the file holds no " ~ T.stringof);
}

// As `transfer` for an array that a load needs only while it runs: the array
// is a GC array that nothing references after the load, outside the memory
// of the program. What its elements point to is in the memory of the program.
private void transferTemporary(T : E[], E)(ref Archive archive, ref T value) {
    const count = archive.length(value.length);
    if (archive.isWriting) {
        foreach (ref element; value)
            archive.transfer(element);
    } else {
        auto fresh = new Unqual!E[count];
        foreach (ref element; fresh)
            archive.transfer(element);
        value = cast(T) fresh;
    }
}

// A struct of the VM: each field as it says. A field whose classification
// writes nothing keeps the initial value of a new record on a load.
private void transferClassified(T)(ref Archive archive, ref T value) {
    static foreach (index, name; FieldNameTuple!T) {{
        enum classification = classificationOf!(T, index);
        static if (!overlapsEarlier!(T, index)) {
            alias Field = typeof(T.tupleof[index]);
            static if (is(typeof(classification) == Plain)) {
                static if (holdsAddress!Field) {
                    if (archive.isWriting) {
                        if (wordOf(value.tupleof[index]) != 0)
                            internalFailure(text("the field ", T.stringof,
                                ".", name, " holds an address"));
                    } else
                        value.tupleof[index] = Field.init;
                } else
                    archive.transfer(value.tupleof[index]);
            } else static if (is(typeof(classification) == HostCode)) {
                // Code of the host executable, as a distance that
                // `Program.complete` binds. Only the handler of an
                // instruction and the counting handler of a counting site are
                // never null.
                bool present = true;
                static if (!is(Field == Instruction.Handler)) {
                    if (archive.isWriting)
                        present = wordOf(value.tupleof[index]) != 0;
                    archive.scalar(present);
                }
                size_t distance;
                if (archive.isWriting)
                    distance = wordOf(value.tupleof[index]);
                if (present)
                    archive.scalar(distance);
                if (!archive.isWriting)
                    value.tupleof[index] = cast(Field) distance;
            }
        }
    }}
}


// A `Reloc` in a file names its target by number.
private void transferReloc(ref Archive archive, ref Reloc reloc) {
    archive.transfer(reloc.place);
    archive.transfer(reloc.target.kind);
    size_t[3] reference;
    if (archive.isWriting)
        reference = referenceOf(archive, reloc.target);
    archive.scalar(reference);
    if (!archive.isWriting)
        reloc.target = targetOf(archive, reloc.target.kind, reference);
}

private size_t[3] referenceOf(ref Archive archive, in Target target) {
    final switch (target.kind) with (Target.Kind) {
        case signature:
            return [archive.signatureIndex(
                cast(const(Signature)*) target.address), 0, 0];
        case functionWord:
            const position =
                archive.positionOf(cast(const(Function)*) target.address);
            return [position[0], position[1], 0];
        case callbackEntry:
            // The entry of a guest function, with the receiver adjustment of
            // an interface method.
            const guest = archive._program.plans.callbacks.guestTarget(
                cast(const(void)*) target.address);
            if (guest.word is null)
                internalFailure(
                    "a word points at a callback entry of no guest function");
            const position =
                archive.positionOf(cast(const(Function)*) guest.word);
            return [position[0], position[1], cast(size_t) guest.adjustment];
        case nativePlan:
            return [archive.planIndexOf(
                cast(const(CallPlan)*) target.address), 0, 0];
        case staticData:
        case constantPool:
            return archive.blocksPosition(
                target.datum.set, target.datum.block, target.datum.offset);
        case adoptedString:
            return archive.stringPosition(cast(const(void)*) target.address);
        case hostSymbol:
            return archive.nameReference(cast(const(void)*) target.address);
        case interfaceTable:
        case interfaceRecord:
            const name = archive.nameAt(cast(const(void)*) target.address);
            if (name.adjusted !is null || name.distance != 0)
                internalFailure("a word names an interface of an address that is not a class information");
            return [archive.nameIndexOf(name), target.index, 0];
    }
}

// The address of the target that `reference` names. A name stays a name
// (`snakebite.ffi.names`): the program finds the address of its symbol when
// it is made ready to run (`targetOf`).
private size_t addressOf(
    ref Archive archive, in Target.Kind kind, in size_t[3] reference,
) {
    final switch (kind) with (Target.Kind) {
        case signature:
            return cast(size_t) archive.signatureAt(reference[0]);
        case functionWord:
            return cast(size_t) archive.functionAt(reference[0], reference[1]);
        case callbackEntry:
            return cast(size_t) archive.entryAt(reference);
        case hostSymbol:
            return cast(size_t) archive.nameOfIndex(reference[0]);
        case nativePlan:
            return cast(size_t) archive.planAt(reference[0]);
        case staticData:
        case constantPool:
            return cast(size_t) archive.dataAt(reference);
        case adoptedString:
            return cast(size_t) archive.stringAt(reference);
        case interfaceTable:
        case interfaceRecord:
            return cast(size_t) archive.nameOfIndex(reference[0]);
    }
}

// Whether a word of a file that refers to a target of `kind` names a symbol
// (`referenceOf`).
private bool isName(in Target.Kind kind) {
    return kind == Target.Kind.hostSymbol || kind == Target.Kind.interfaceTable
        || kind == Target.Kind.interfaceRecord;
}

// The target that `reference` names, as `referenceOf` took it.
private Target targetOf(
    ref Archive archive, in Target.Kind kind, in size_t[3] reference,
) {
    const isInterface = kind == Target.Kind.interfaceTable
        || kind == Target.Kind.interfaceRecord;
    return Target(kind, addressOf(archive, kind, reference), DatumRef.init,
        isInterface ? cast(uint) reference[1] : 0);
}


// `function_`, as the compiler built it, as a file holds it: a copy with each
// address left to its relocation, and the relocations that the file holds. A
// word that holds an address and no relocation names it cannot be written.
private Function prepareToWrite(ref Archive archive, ref Function function_) {
    Function copy = function_;
    bool[size_t[3]] listed;
    Reloc[] kept;
    foreach (reloc; function_.relocs) {
        // Names the target now, so that the file holds it.
        referenceOf(archive, reloc.target);
        listed[[cast(size_t) reloc.place.section,
            cast(size_t) reloc.place.field, reloc.place.index]] = true;
        kept ~= reloc;
    }
    copy.relocs = kept;
    // The word of a constant that holds an address is left to its relocation.
    copy.constants = function_.constants.dup;
    foreach (reloc; kept)
        if (reloc.place.section == Place.Section.constant
                && reloc.place.field == Place.Field.word
                && reloc.place.index < copy.constants.length)
            copy.constants[reloc.place.index] = 0;

    void require(
        in Relocated relocated, in size_t index, in size_t word,
    ) {
        if (word != 0 && !([cast(size_t) relocated.section,
                cast(size_t) relocated.field, index] in listed))
            internalFailure(text("a word of `", function_.hostCall.name,
                "` holds an address that no relocation names"));
    }

    eachRelocated(function_, (in Relocated relocated, size_t word) {
        require(relocated, 0, word);
    });
    foreach (index, ref site; function_.callSites)
        eachRelocated(site, (in Relocated relocated, size_t word) {
            require(relocated, index, word);
        });
    foreach (index, ref site; function_.assertSites)
        eachRelocated(site, (in Relocated relocated, size_t word) {
            require(relocated, index, word);
        });
    foreach (index, ref handler; function_.exceptionHandlers)
        eachRelocated(handler, (in Relocated relocated, size_t word) {
            require(relocated, index, word);
        });

    auto instructions = function_.instructions.dup;
    foreach (index, ref instruction; instructions) {
        Roles roles;
        if (!rolesOf(cast(Instruction.Handler) hostCodeAt(
                cast(ptrdiff_t) instruction.handler), roles))
            continue;
        static foreach (name; ["destination", "source", "sourceWidth"]) {{
            const role = mixin("roles." ~ name);
            auto field = &mixin("instruction." ~ name);
            if (role == Role.address) {
                require(Relocated(Place.Section.instruction,
                    mixin("Place.Field." ~ name)), index, *field);
                *field = 0;
            }
        }}
    }
    copy.instructions = instructions;
    return copy;
}


// Puts the address of a relocation at its place in `function_`.
private void applyReloc(ref Function target, in Reloc reloc) {
    auto word = wordAt(target, reloc.place);
    if (word is null)
        throw new SnakebiteException(
            "the program file holds a relocation with no place");
    *word = reloc.target.address;
}




private void transferBody(
    ref Archive archive, ref Program program, Runner* runner,
) {
    // The shape first, so that a function can refer to any other.
    const numModules = archive.length(archive._numModules);
    if (!archive.isWriting) {
        archive._firstModule = program._modules.length;
        archive._numModules = numModules;
        archive._firstStringIndexInStore = program.store.strings.length;
    }
    // One module for each module of the file, and the one that takes the data
    // that no D module owns.
    const numBlockSets = archive.numBlockSets;
    if (archive.isWriting)
        // As `Program.newModules` and `Module.newFunctions` take them.
        archive._need.data += numBlockSets * bytesFor(Module.sizeof);
    else
        program.newModules(numBlockSets);
    foreach (m; 0 .. numModules) {
        const numWritten = archive.isWriting
            ? archive.moduleAt(m)._functions.length
            : 0;
        size_t functionCount = archive.length(numWritten);
        if (archive.isWriting) {
            archive.need!Function(functionCount);
            archive.need!(Function*)(functionCount);
        } else
            archive.moduleAt(m).newFunctions(program.memory, functionCount);
    }
    transferStartData(archive, program);
    transferPlans(archive, program);
    transferSignatures(archive, program);
    // All data before any function: a function can point into any module.
    // The bytes of all data come before the addresses in them: a datum can
    // point into any block or string.
    if (archive.isWriting)
        foreach (m; 0 .. numBlockSets)
            archive.blocksAt(m).addLoadNeed(archive._need);
    foreach (m; 0 .. numBlockSets)
        transferBlocks(archive, *archive.blocksAt(m));
    transferStrings(archive, program.store);
    transferOwnCopies(archive, program);
    transferDefinitionsHere(archive, program);
    foreach (m; 0 .. numBlockSets)
        transferAddresses(archive, *archive.blocksAt(m));
    foreach (m; 0 .. numModules)
        transferModule(archive, program, *archive.moduleAt(m));
}


// The start data of the program. A load appends the modules of the start
// data of each file.
private void transferStartData(ref Archive archive, ref Program program) {
    if (archive.isWriting)
        return archive.transfer(program.startData);
    StartData read;
    archive.transfer(read);
    // `auto`: the modules of the start data are mutable.
    auto before = program.startData.modules;
    program.startData = read;
    program.startData.modules = before ~ read.modules;
}


// The call plans of the store, in the order a compile made them: the index
// of the name of the code, or the length of the table of names for a plan
// with no code, and the failure text. A load makes each one again, with the
// function that makes it after a compile.
private void transferPlans(ref Archive archive, ref Program program) {
    NativeSignature[] signatures;
    size_t[] names;
    string[] failures;
    if (archive.isWriting)
        program.plans.eachPlan((plan, signature, name, failure) {
            signatures ~= cast() signature;
            names ~= name is null ? size_t.max : archive.nameIndexOf(name);
            failures ~= failure;
        });
    // The load needs the lists only while it runs; the plans keep the
    // signatures and the failure texts.
    transferTemporary(archive, signatures);
    transferTemporary(archive, names);
    transferTemporary(archive, failures);
    if (archive.isWriting)
        return;
    if (names.length != signatures.length
            || failures.length != signatures.length)
        throw new SnakebiteException(
            "the program file holds call plans that do not match");
    archive._plans = new CallPlan*[signatures.length];
    foreach (index, signature; signatures)
        archive._plans[index] = program.plans.plan(signature,
            names[index] == size_t.max ? null
                : archive.nameOfIndex(names[index]),
            failures[index]);
}


// The signature that each function of the program is registered with in the
// callback bridge, before any function is read: a word that refers to the entry
// of a function needs the signature.
private void transferSignatures(ref Archive archive, ref Program program) {
    archive.eachFunction((Function* function_) {
        NativeSignature signature;
        if (archive.isWriting) {
            const registered =
                program.plans.callbacks.signatureOf(function_);
            if (registered is null)
                internalFailure("a function has no registered signature");
            signature = cast(NativeSignature) *registered;
        }
        archive.transfer(signature);
        if (!archive.isWriting)
            program.plans.callbacks.register(function_, signature);
    });
}


// The data of a module, or of the process store, as bytes, with each word that
// holds an address set to zero: `transferAddresses` has them. A load reserves
// each datum through the same code as a compile, so the blocks come out the
// same, and checks that.
private void transferBlocks(ref Archive archive, ref StaticBlocks blocks) {
    const count = archive.length(blocks.data.length);
    foreach (index; 0 .. count) {
        StaticBlocks.Datum datum;
        ubyte[] contents;
        if (archive.isWriting) {
            const source = blocks.data[index];
            datum.block = source.block;
            datum.offset = source.offset;
            datum.size = source.size;
            datum.alignment = source.alignment;
            datum.canHoldAddress = source.canHoldAddress;
            contents = cast(ubyte[]) blocks.bytesOf(source).dup;
            foreach (link; source.links)
                contents[link.wordOffset
                    .. link.wordOffset + size_t.sizeof] = 0;
        }
        archive.scalar(datum.block);
        archive.scalar(datum.offset);
        archive.scalar(datum.size);
        archive.scalar(datum.alignment);
        archive.scalar(datum.canHoldAddress);
        if (archive.isWriting) {
            archive.bytes(contents);
            continue;
        }
        TypeFacts facts;
        facts.size = datum.size;
        facts.alignment = datum.alignment;
        facts.canHoldAddress = datum.canHoldAddress;
        auto bytes = blocks.reserve(facts).bytes;
        const placed = blocks.data[$ - 1];
        if (placed.block != datum.block || placed.offset != datum.offset)
            throw new SnakebiteException(
                "the program file does not fit the memory of this process");
        archive.bytes(bytes);
    }
}


// The copies of string literals of the process store, in the order that a
// compile made them.
private void transferStrings(ref Archive archive, ref StaticStore store) {
    const count = archive.length(store.strings.length);
    foreach (index; 0 .. count) {
        const size = archive.length(
            archive.isWriting ? store.strings[index].length : 0);
        if (archive.isWriting)
            archive.bytes(cast(void[]) store.strings[index]);
        else
            archive.bytes(store.newString(size));
    }
}


// The names that have the program's own copy of their symbol
// (`Names.defineOwn`): the index of each and the place of its copy. A load
// gives each name its copy before any word is made ready to run, so the
// decision of a load (`CallPlanStore.chosenCopy`) is that of a compile to
// RAM.
private void transferOwnCopies(ref Archive archive, ref Program program) {
    size_t[] names;
    size_t[3][] places;
    if (archive.isWriting)
        program.plans.names.eachOwn((name) {
            const datum = name.ownDatum;
            names ~= archive.nameIndexOf(name);
            places ~= archive.blocksPosition(
                datum.set, datum.block, datum.offset);
        });
    archive.transfer(names);
    archive.transfer(places);
    if (archive.isWriting)
        return;
    if (places.length != names.length)
        throw new SnakebiteException(
            "the program file holds own copies that do not match");
    foreach (index, place; places)
        program.plans.names.defineOwn(archive.nameOfIndex(names[index]),
            archive.dataAt(place), DatumRef(archive.blocksAt(place[0]),
                place[1], place[2]));
}


// The symbols that only the compile of the file defines (`Names.defineHere`):
// for each function, the index of the symbol in the table of symbols and the
// place of the function, then for each datum, the index of the symbol and the
// place of the datum.
private void transferDefinitionsHere(ref Archive archive, ref Program program) {
    size_t[] functionSymbols;
    FunctionPosition[] functionPlaces;
    size_t[] datumSymbols;
    size_t[3][] datumPlaces;
    if (archive.isWriting)
        program.plans.names.eachDefinitionHere(
            (string symbol, ref const DefinitionHere definition) {
                const symbolIndex = archive.symbolIndexOfName(symbol);
                if (const guestFunction = definition.guestFunction) {
                    functionSymbols ~= symbolIndex;
                    const function_ = cast(const(Function)*) guestFunction;
                    functionPlaces ~= archive.positionOf(function_);
                    return;
                }
                const datum = definition.datum;
                datumSymbols ~= symbolIndex;
                datumPlaces ~= archive.blocksPosition(
                    datum.set,
                    datum.block,
                    datum.offset,
                );
            },
        );
    // The load needs the lists only while it runs.
    transferTemporary(archive, functionSymbols);
    transferTemporary(archive, functionPlaces);
    transferTemporary(archive, datumSymbols);
    transferTemporary(archive, datumPlaces);
    if (archive.isWriting)
        return;
    if (functionPlaces.length != functionSymbols.length
            || datumPlaces.length != datumSymbols.length)
        throw new SnakebiteException(
            "the program file holds definitions that do not match",
        );
    foreach (index, place; functionPlaces) {
        const guestFunction = archive.functionAt(place[0], place[1]);
        program.plans.names.defineHere(
            archive.symbolNameAt(functionSymbols[index]),
            DefinitionHere(guestFunction),
        );
    }
    foreach (index, place; datumPlaces) {
        const datum = DatumRef(archive.blocksAt(place[0]), place[1], place[2]);
        program.plans.names.defineHere(
            archive.symbolNameAt(datumSymbols[index]),
            DefinitionHere(null, archive.dataAt(place), datum),
        );
    }
}


// The words of the data of `blocks` that hold an address, as links.
private void transferAddresses(ref Archive archive, ref StaticBlocks blocks) {
    foreach (index; 0 .. blocks.data.length) {
        auto links = archive.isWriting ? blocks.data[index].links.dup : null;
        const count = archive.length(links.length);
        foreach (linkIndex; 0 .. count) {
            StaticBlocks.Link link;
            if (archive.isWriting)
                link = links[linkIndex];
            archive.scalar(link.wordOffset);
            archive.transfer(link.kind);
            size_t[3] reference;
            if (archive.isWriting)
                reference = linkReference(archive, link);
            archive.scalar(reference);
            if (archive.isWriting)
                continue;
            auto bytes = cast(ubyte[]) blocks.bytesOf(blocks.data[index]);
            if (link.wordOffset > bytes.length
                    || bytes.length - link.wordOffset < size_t.sizeof)
                throw new SnakebiteException(
                    "the program file holds a relocation with no place");
            // A datum is ready to run once it is written, as after a compile
            // to RAM. The address of a symbol is written after the last file
            // (`load`).
            const target = targetOf(archive, link.kind, reference);
            auto place = &bytes[link.wordOffset];
            if (link.kind == Target.Kind.interfaceTable
                    || link.kind == Target.Kind.interfaceRecord)
                archive._interfaceAddresses ~= PendingAddress(place, target);
            else if (isName(link.kind))
                archive._symbolAddresses ~= PendingAddress(place, target);
            else
                writeWord(place, target.address);
        }
    }
}


// Writes the word `address` at `place`, which a datum can hold at any
// offset.
private void writeWord(ubyte* place, in size_t address) {
    place[0 .. size_t.sizeof] =
        (cast(const(ubyte)*) &address)[0 .. size_t.sizeof];
}

private size_t[3] linkReference(ref Archive archive, in StaticBlocks.Link link) {
    if (link.kind != Target.Kind.staticData)
        return referenceOf(archive,
            Target(link.kind, link.address, DatumRef.init, link.index));
    return archive.blocksPosition(link.set, link.block, link.offset);
}


private void transferModule(
    ref Archive archive, ref Program program, ref Module module_,
) {
    // The fields of `Module`: the `ModuleStart`, the blocks and the functions.
    static assert(FieldNameTuple!Module == AliasSeq!("start", "blocks", "_functions"));
    // `blocks` is set by `transferBlocks`, before the functions.
    archive.transfer(module_.start);
    foreach (function_; module_._functions) {
        if (archive.isWriting) {
            auto prepared = prepareToWrite(archive, *function_);
            archive.transfer(prepared);
        } else {
            archive.transfer(*function_);
            // A name stays for `Program.complete`, which makes it ready to
            // run as after a compile to RAM. Each word of a file that names
            // a symbol is a name. The names stay at the front of the array,
            // and a function with no name keeps no array, as a compile to
            // RAM leaves it.
            size_t named;
            foreach (ref reloc; function_.relocs)
                if (isName(reloc.target.kind))
                    function_.relocs[named++] = reloc;
                else
                    applyReloc(*function_, reloc);
            function_.relocs = named == 0 ? null
                : function_.relocs[0 .. named];
            // The GC does not scan the function: the archive holds the
            // relocations until `Program.complete` drops them.
            if (named != 0)
                archive._namedRelocs ~= function_.relocs;
        }
    }
}


// The `ModuleStart` of a module is in the module: the file holds its
// position in the program.
private void transfer(
    ref Archive archive, ref ModuleStart* start,
) {
    size_t position;
    if (archive.isWriting) {
        const found = start in archive._moduleOfStart;
        if (found is null)
            internalFailure("a module start belongs to no module");
        position = *found;
    }
    archive.scalar(position);
    if (!archive.isWriting) {
        if (position >= archive._numModules)
            throw new SnakebiteException(
                "the program file names a module that it does not hold");
        start = &archive.moduleAt(position).start;
    }
}

// A gate is the storage of a variable: a target and a length.
private void transfer(ref Archive archive, ref GateStorage gate) {
    Target.Kind kind;
    size_t[3] reference;
    size_t length;
    if (archive.isWriting) {
        length = gate.length;
        kind = archive.gateTarget(gate, reference);
    }
    archive.transfer(kind);
    archive.scalar(reference);
    archive.scalar(length);
    if (!archive.isWriting) {
        // The gate is ready to run once it is read, as after a compile
        // to RAM, or, for a gate that names a symbol, after the last file
        // (`load`).
        const target = targetOf(archive, kind, reference);
        if (isName(kind))
            archive._symbolGates ~= PendingGate(&gate, target, length);
        else
            gate.bytes = (cast(ubyte*) target.address)[0 .. length];
        if (kind == Target.Kind.staticData)
            gate.where = DatumRef(archive.blocksAt(reference[0]),
                reference[1], reference[2]);
    }
}


// A handle is a compiled function of the program, named by its place.
private void transfer(ref Archive archive, ref FunctionHandle handle) {
    FunctionPosition position;
    if (archive.isWriting) {
        const compiled = cast(const(Function)*) handle.compiledCode;
        if (compiled is null)
            internalFailure("a start function is not one of the bytecode backend");
        position = archive.positionOf(compiled);
        // The GC scans the object: it holds the runner.
        archive._need.scanned +=
            bytesFor(__traits(classInstanceSize, StartFunction));
    }
    archive.scalar(position);
    if (!archive.isWriting)
        handle = archive._memory.scanned.make!StartFunction(
            archive._runner, archive.functionAt(position[0], position[1]));
}
