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
import snakebite.ffi.names: FileName, Name;
import snakebite.native.staticstore: StaticBlocks, StaticStore;
import snakebite.native.value: TypeFacts;
import snakebite.native.signature: Signature;
import snakebite.start.data:
    dependencyModulesOf, FunctionHandle, GateStorage, MainStart, ModuleStart,
    StartData;
import std.conv: text;
import std.meta: AliasSeq;
import std.traits: FieldNameTuple, Unqual;


// What precedes the program in a file.
public struct Header {
    // Names the build that wrote the file (`generatorKey`).
    public string buildKey;
    // The dependency image that the program runs on, or empty.
    public string imagePath;
    // The directory that the program runs in.
    public string workingDirectory;
}


private enum magic = "snakebite-program-v1\n";


// Writes `program`, whole and compiled, to `path`. The file is complete or it
// does not exist: it is written under another name and renamed.
public void saveProgram(
    ref Program program, in Header header, in string path,
) {
    import std.file: remove, rename, write;

    auto body_ = Archive.writing(program);
    body_._marked = reachableData(program);
    transferBody(body_, program, null);

    auto file = Archive.writing(program);
    file.text(magic);
    Header written = Header(
        header.buildKey, header.imagePath, header.workingDirectory);
    transferHeader(file, written);
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
// then its program. `next` gives the next part of the bytes of the file, and
// an empty part at the end; `size` is the number of bytes of the file.
public struct ProgramReader {
    @disable this(this);

    private Archive _file;

    public this(
        return scope const(ubyte)[] delegate() next, in size_t size,
    ) {
        _file = Archive.reading(next, size);
    }

    // The header of the file. Call it once, before `load`.
    public Header header() {
        _file.expectText!magic;
        Header header;
        transferHeader(_file, header);
        return header;
    }

    // Reads the program of the file into `program`, a new program made with
    // `image` (the dependency image that the file was made with, or null)
    // and wired to `runner`. Once the load is done, they are as a compile to
    // RAM leaves them: `Program.complete` binds every function.
    public void load(
        ref Program program, ref Runner runner, in DependencyImage* image,
    ) {
        loadProgram(_file, program, runner, image);
    }
}


// Joins the files `inputs` of the units of one program, which saves of the
// compiles of the units wrote, into one program, and saves it to `output`
// as `saveProgram` does. Returns the header of the files. As an object file
// does, the file of a unit holds a function of another unit by its name,
// with no body, and a datum of another unit by its name
// (`snakebite.ffi.names`). The link reads the files as a load does, but
// leaves the program in the form that a compile for a save leaves it: it
// puts the modules of the same name together, keeps one function of each
// name (one with a body) and one own copy of each name, and joins the
// imports of the modules by name. A function that no unit defines is an
// error, and so is a file that a build with another key than `buildKey`
// wrote (`Header.buildKey`).
public LinkedProgram linkPrograms(
    in string[] inputs, in string output, in string buildKey,
) {
    import core.memory: GC;
    import snakebite.backends.bytecode.runner: wire;
    import std.file: read;

    auto program = new Program(null, true);
    auto runner = cast(Runner*) GC.calloc(Runner.sizeof);
    wire(*program, *runner, JitSetting.init);
    scope(exit) runner.end;
    Linker linker = Linker(program);
    Header header;
    foreach (index, input; inputs) {
        auto bytes = cast(const(ubyte)[]) read(input);
        bool given;
        const(ubyte)[] next() {
            if (given)
                return null;
            given = true;
            return bytes;
        }

        auto file = Archive.reading(&next, bytes.length);
        file.expectText!magic;
        Header read_;
        transferHeader(file, read_);
        if (read_.buildKey != buildKey)
            throw new SnakebiteException(input
                ~ " was written by another build of snakebite");
        if (index == 0)
            header = read_;
        else if (read_ != header)
            throw new SnakebiteException(input
                ~ " is of another program than " ~ inputs[0]);
        file._linker = &linker;
        loadProgram(file, *program, *runner, null);
    }
    linker.finish;
    saveProgram(*program, header, output);
    return LinkedProgram(header, program.startData.hasCEntryPoint,
        program.startData.betterC);
}


// What a link (`linkPrograms`) tells of the program that it wrote.
public struct LinkedProgram {
    public Header header;
    // As `StartData` has them.
    public bool hasCEntryPoint;
    public bool betterC;
}


private void loadProgram(
    ref Archive file, ref Program program, ref Runner runner,
    in DependencyImage* image,
) {
    file._image = image;
    file._program = &program;
    file._runner = &runner;
    MemoryNeed need;
    file.scalar(need.data);
    file.scalar(need.scanned);
    // As `Archive.length` checks a count: a size that the rest of the file
    // cannot fill is of a damaged file.
    if (need.data / maxLoadBytesPerFileByte
            + need.scanned / maxLoadBytesPerFileByte > file.unreadLength)
        throw new SnakebiteException(
            "the program file ends before the program does");
    // A link adds the file to a program that grows as a compile does.
    if (!file.isLinking) {
        file._memory = &program.memory;
        program.memory.reserve(need, &program);
        program.store.takeFrom(&program.memory);
    }
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
    if (file.isLinking)
        return;

    program.eachFunction((function_) {
        if (const reason = Program.complete(function_, program.plans,
                runner.jitSetting, runner.jitInstance))
            throw new SnakebiteException(
                "the program file is not valid: " ~ reason);
    });
    program.memory.checkFull;
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
    void make(in size_t index, ref FileName made) {
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
    }

    auto names = &archive._program.plans.names;
    archive._names = new Name*[count];
    if (!archive.isLinking) {
        foreach (index, ref name; names.fromFile(count, &make))
            archive._names[index] = &name;
        return;
    }
    // A link joins the names of all the files: the same symbol is one name.
    foreach (index, ref name; archive._names) {
        FileName made;
        make(index, made);
        if (!made.isAdjusted) {
            name = names.named(made.symbol, cast(size_t) made.distance,
                made.declaredBy);
            continue;
        }
        if (made.code >= index)
            throw new SnakebiteException("the program file names the code "
                ~ "of an entry before the code itself");
        const entrySignature = made.signature;
        name = names.adjusted(archive._names[made.code], made.distance,
            () => cast() entrySignature);
    }
}


private void transferHeader(ref Archive archive, ref Header header) {
    archive.transfer(header.buildKey);
    archive.transfer(header.imagePath);
    archive.transfer(header.workingDirectory);
}


// A word of the data at `place` that refers to `target`, an interface of a
// class information.
private struct InterfaceWord {
    ubyte* place;
    Target target;
}


// What a link (`linkPrograms`) keeps from file to file: the program that it
// makes, its modules by name and its functions by mangled name.
private struct Linker {
    Program* program;
    Module*[string] modules;
    Function*[string] functions;

    // The module of the program of the name `name`. An empty name names no
    // module: each is a new one.
    Module* moduleNamed(string name) {
        if (name.length)
            if (auto found = name in modules)
                return *found;
        auto made = program.newModule;
        made.start.name = name;
        if (name.length)
            modules[name] = made;
        return made;
    }

    // The function of the program of the mangled name `symbol`, which a new
    // one in `module_` is when the program has none. An empty name names no
    // function: each is a new one.
    Function* functionNamed(Module* module_, const(char)[] symbol) {
        if (symbol.length)
            if (auto found = symbol in functions)
                return *found;
        auto made = module_.newFunction;
        made.mangledName = symbol;
        if (symbol.length)
            functions[cast(string) symbol] = made;
        return made;
    }

    // What makes the program of the link complete once it has read the
    // files: each function that a file refers to has a body, the imports of
    // each module are positions in the start data, and no function keeps a
    // name that a compile to RAM gives only for the perf map.
    void finish() {
        import std.algorithm.searching: canFind;

        foreach (symbol, function_; functions)
            if (!isDefined(function_))
                throw new SnakebiteException(
                    "the link finds no unit that defines `" ~ symbol ~ "`");
        auto start = &program.startData;
        size_t[string] position;
        foreach (index, record; start.modules)
            position[record.name] = index;
        foreach (index, record; start.modules) {
            record.imports = null;
            foreach (name; record.importNames)
                if (auto found = name in position)
                    if (*found != index && !start.modules[*found].standalone
                            && !record.imports.canFind(*found))
                        record.imports ~= *found;
        }
        program.eachFunction((function_) {
            function_.mangledName = null;
        });
    }
}


// Whether `function_` has a body: a file of a unit holds a function that
// another unit defines with none (`linkPrograms`).
private bool isDefined(const(Function)* function_) {
    return function_.instructions.length != 0;
}


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
    private size_t[2][const(Function)*] _positionOf;
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
    private Name*[] _names;
    // Reading: the words of the data that refer to an interface of a class
    // information, which `transferBody` makes ready last.
    private InterfaceWord[] _interfaceWords;
    private Runner* _runner;
    private Program* _program;
    private const(DependencyImage)* _image;
    // Reading: the memory of the program, once there is a program, or null
    // for a link.
    private ProgramMemory* _memory;
    // Writing: the memory that a load of what this wrote takes.
    private MemoryNeed _need;
    // Reading for a link (`linkPrograms`), which adds the file to the
    // program that the files before it made; null for a load.
    private Linker* _linker;
    // The module of the program for each module of the file, and the
    // functions of the program for its functions. Each is the same module or
    // function, except in a link.
    private Module*[] _fileModules;
    private Function*[][] _fileFunctions;
    // For each module of the file, and for the process store after them: the
    // number of blocks and of data of the program before the blocks of the
    // file. Zero except in a link.
    private size_t[] _blockBases;
    private size_t[] _dataBases;
    // Reading: whether each module of the file has a start record, which a
    // link keeps.
    private bool[] _recorded;
    // Reading: the number of strings of the program before those of the
    // file.
    private size_t _stringBase;
    // Writing: for each module of the program, and for the process store
    // after them, whether each of its data is one that the program refers to.
    // A datum that nothing refers to has no bytes in the file
    // (`reachableData`). Null when the archive holds every datum.
    private bool[][] _marked;
    // Writing: whether the archive only finds the data that the program
    // refers to. `_pending` holds the data that it found and has not yet
    // followed.
    private bool _marking;
    private size_t[2][] _pending;
    // The data that nothing refers to, as their numbers among all the data
    // of the file, in order, and the count of the data and of the dropped
    // data that the archive has gone past. Reading and writing alike go
    // through the data in the order of the file.
    private uint[] _dropped;
    private size_t _datumsPast;
    private size_t _droppedPast;

    bool isLinking() const @safe pure nothrow @nogc {
        return _linker !is null;
    }

    // Reading: the `count` modules of the file. A load makes them in the
    // memory of the program.
    void newFileModules(in size_t count) {
        if (!isLinking) {
            _program.newModules(count);
            _fileModules = _program._modules;
        } else
            _fileModules = new Module*[count];
        _fileFunctions = new Function*[][count];
        _blockBases = new size_t[count + 1];
        _dataBases = new size_t[count + 1];
        _recorded = new bool[count];
    }

    // Reading: module `index` of the file, of the name `name`, with
    // `functionCount` functions. A link puts it in the module of the program
    // of the same name.
    void newFileModule(
        in size_t index, string name, in size_t functionCount,
    ) {
        if (!isLinking) {
            auto module_ = _fileModules[index];
            module_.start.name = name;
            module_.newFunctions(*_memory, functionCount);
            _fileFunctions[index] = module_._functions;
            return;
        }
        _fileModules[index] = _linker.moduleNamed(name);
        _fileFunctions[index] = new Function*[functionCount];
    }

    // Reading: the mangled name `symbol` of function `index` of module
    // `module_` of the file. A link gives the function of the program of that
    // name, and the files after it give their function of that name to it.
    void nameFileFunction(
        in size_t module_, in size_t index, const(char)[] symbol,
    ) {
        if (!isLinking) {
            _fileFunctions[module_][index].mangledName = symbol;
            return;
        }
        _fileFunctions[module_][index] =
            _linker.functionNamed(_fileModules[module_], symbol);
    }

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
            archive._fileFunctions ~= module_._functions;
        }
        archive._fileModules = program._modules;
        archive._blockBases = new size_t[program._modules.length + 1];
        archive._dataBases = new size_t[program._modules.length + 1];
        return archive;
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

    size_t[2] positionOf(const(Function)* function_) {
        if (auto found = function_ in _positionOf)
            return *found;
        internalFailure("a function points at a function that no module holds");
    }

    // The blocks of module `index` of the file, or the blocks of the process
    // store for the index that follows the last module; null for any other.
    StaticBlocks* blocksAt(in size_t index) {
        if (index < _fileModules.length)
            return &_fileModules[index].blocks;
        if (index == _fileModules.length)
            return _program.store.blocks;
        return null;
    }

    // The datum of the program at the place `position` of the file: its
    // module, block and offset.
    DatumRef datumAt(in size_t[3] position) {
        auto blocks = blocksAt(position[0]);
        if (blocks is null)
            throw new SnakebiteException(
                "the program file names data that it does not hold");
        return DatumRef(blocks, position[1] + _blockBases[position[0]],
            position[2]);
    }

    // The module, block and offset of a place in the blocks `set`, when the
    // program holds them.
    size_t[3] blocksPosition(
        in const(void)* set, in size_t block, in size_t offset,
    ) {
        if (set !is null)
            foreach (m; 0 .. _program._modules.length + 1)
                if (blocksAt(m) is set) {
                    if (_marking)
                        markDatum(m, block, offset);
                    return [m, block, offset];
                }
        internalFailure("a word points at data that the program does not hold");
    }

    // Whether the next datum of the file is one with no bytes in the file.
    // Called once for each datum, in the order of the file.
    bool takeDropped() {
        const dropped = _droppedPast < _dropped.length
            && _dropped[_droppedPast] == _datumsPast;
        _droppedPast += dropped;
        ++_datumsPast;
        return dropped;
    }

    // Whether the datum `index` of module `module_`, or of the process store,
    // is in the file with its bytes.
    bool isKept(in size_t module_, in size_t index) const {
        return _marked is null || _marked[module_][index];
    }

    // The data at `offset` in block `block` of the blocks of `module_` are
    // referred to. A place at the end of a datum is the end of that datum
    // and the start of the next one: both are referred to.
    private void markDatum(
        in size_t module_, in size_t block, in size_t offset,
    ) {
        const data = blocksAt(module_).data;
        size_t low, high = data.length;
        while (low < high) {
            const middle = (low + high) / 2;
            if (data[middle].block < block
                    || (data[middle].block == block
                        && data[middle].offset <= offset))
                low = middle + 1;
            else
                high = middle;
        }
        // `low - 1` is the last datum that starts at or before the place.
        foreach (index; (low >= 2 ? low - 2 : 0) .. low) {
            const datum = data[index];
            if (datum.block == block && offset >= datum.offset
                    && offset <= datum.offset + datum.size
                    && !_marked[module_][index]) {
                _marked[module_][index] = true;
                _pending ~= [module_, index];
            }
        }
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
            if (auto address = blocks.addressOf(
                    position[1] + _blockBases[position[0]], position[2]))
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
                position[0] + _stringBase, position[1]))
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
        return _names[index];
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
        if (module_ >= _fileFunctions.length
                || index >= _fileFunctions[module_].length)
            throw new SnakebiteException(
                "the program file names a function that it does not hold");
        return _fileFunctions[module_][index];
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


// The one walk. It writes `value` to the file, or reads the file into it.
private void transfer(T)(ref Archive archive, ref T value) {
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
        static assert(isPureData!(Unqual!T), T.stringof ~ " is neither a type of the "
            ~ "VM nor data without an address");
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
    // A link keeps the datum of the target, as a compile for a save does.
    const isData = kind == Target.Kind.staticData
        || kind == Target.Kind.constantPool;
    return Target(kind, addressOf(archive, kind, reference),
        archive.isLinking && isData ? archive.datumAt(reference) : DatumRef.init,
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
    // The shape first, so that a function can refer to any other: the name
    // of each module and the names of its functions.
    size_t moduleCount = archive.length(program._modules.length);
    if (archive.isWriting) {
        // As `Program.newModules` and `Module.newFunctions` take them.
        archive.need!(Module*)(moduleCount);
        archive._need.data += moduleCount * bytesFor(Module.sizeof);
    } else
        archive.newFileModules(moduleCount);
    foreach (m; 0 .. moduleCount) {
        string name = archive.isWriting ? program._modules[m].start.name : null;
        archive.transfer(name);
        size_t functionCount =
            archive.length(archive.isWriting
                ? program._modules[m]._functions.length : 0);
        if (archive.isWriting) {
            archive.need!Function(functionCount);
            archive.need!(Function*)(functionCount);
        } else
            archive.newFileModule(m, name, functionCount);
        foreach (f; 0 .. functionCount) {
            auto symbol = archive.isWriting
                ? archive._fileFunctions[m][f].mangledName : null;
            archive.transfer(symbol);
            if (!archive.isWriting)
                archive.nameFileFunction(m, f, symbol);
        }
    }
    transferStartData(archive, program);
    transferPlans(archive, program);
    transferSignatures(archive, program);
    // All data before any function: a function can point into any module.
    // The bytes of all data come before the addresses in them: a datum can
    // point into any block or string.
    if (archive.isWriting) {
        foreach (m; 0 .. moduleCount)
            program._modules[m].blocks.addLoadNeed(archive._need);
        program.store.addLoadNeed(archive._need);
    }
    // A pass that only finds the data that the program refers to has no use
    // for the data themselves.
    if (!archive._marking) {
        if (archive.isWriting) {
            size_t number;
            foreach (m; 0 .. moduleCount + 1)
                foreach (d; 0 .. archive.blocksAt(m).data.length) {
                    if (!archive.isKept(m, d))
                        archive._dropped ~= cast(uint) number;
                    ++number;
                }
        }
        transferTemporary(archive, archive._dropped);
        foreach (m; 0 .. moduleCount + 1)
            transferBlocks(archive, m);
        transferStrings(archive, program.store);
    }
    transferOwnCopies(archive, program);
    if (!archive._marking)
        foreach (m; 0 .. moduleCount + 1)
            transferAddresses(archive, m);
    // A word of an interface of a class information reads the class
    // information, which can be the program's own copy: it is read once
    // every other word of the data is ready.
    foreach (word; archive._interfaceWords)
        writeWord(word.place,
            archive._program.plans.wordOfName(word.target));
    foreach (m; 0 .. moduleCount)
        transferModule(archive, m);
}


// For each module of `program`, and for the process store after them,
// whether each of its data is one that the program refers to: from a
// function, from the start data, from the own copy of a name, or from a datum
// that the program refers to. The data that a unit defines for a symbol that
// other units define too are not: a link keeps one own copy of a name, and
// the others hold bytes that nothing uses. A datum that nothing refers to is
// in the file with no bytes, so that a load puts each datum where the
// program has it.
private bool[][] reachableData(ref Program program) {
    auto marker = Archive.writing(program);
    marker._marking = true;
    foreach (m; 0 .. program._modules.length + 1)
        marker._marked ~= new bool[marker.blocksAt(m).data.length];
    transferBody(marker, program, null);
    while (marker._pending.length) {
        const place = marker._pending[$ - 1];
        marker._pending = marker._pending[0 .. $ - 1];
        foreach (link; marker.blocksAt(place[0]).data[place[1]].links)
            linkReference(marker, link);
    }
    return marker._marked;
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
    foreach (functions; archive._fileFunctions)
    foreach (function_; functions) {
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
    }
}


// The data of module `index` of the file, or of the process store after the
// modules, as bytes, with each word that holds an address set to zero:
// `transferAddresses` has them. A load reserves each datum through the same
// code as a compile, so the blocks come out the same, and checks that. A link
// puts the blocks of the file after those that the program has.
private void transferBlocks(ref Archive archive, in size_t index) {
    auto blocks = archive.blocksAt(index);
    if (archive.isLinking) {
        archive._blockBases[index] = blocks.blockCount;
        archive._dataBases[index] = blocks.data.length;
    }
    const base = archive._blockBases[index];
    const count = archive.length(blocks.data.length);
    foreach (d; 0 .. count) {
        StaticBlocks.Datum datum;
        ubyte[] contents;
        const dropped = archive.takeDropped;
        if (archive.isWriting) {
            const source = blocks.data[d];
            datum.block = source.block;
            datum.offset = source.offset;
            datum.size = source.size;
            datum.alignment = source.alignment;
            datum.canHoldAddress = source.canHoldAddress;
            if (!dropped) {
                contents = cast(ubyte[]) blocks.bytesOf(source).dup;
                foreach (link; source.links)
                    contents[link.wordOffset
                        .. link.wordOffset + size_t.sizeof] = 0;
            }
        }
        archive.scalar(datum.block);
        archive.scalar(datum.offset);
        archive.scalar(datum.size);
        archive.scalar(datum.alignment);
        archive.scalar(datum.canHoldAddress);
        if (archive.isWriting) {
            if (!dropped)
                archive.bytes(contents);
            continue;
        }
        TypeFacts facts;
        facts.size = datum.size;
        facts.alignment = datum.alignment;
        facts.canHoldAddress = datum.canHoldAddress;
        // A datum of a new block starts one, also where a link put the data
        // of another file before it.
        if (datum.block + base == blocks.blockCount)
            blocks.startBlock;
        auto bytes = blocks.reserve(facts).bytes;
        const placed = blocks.data[$ - 1];
        if (placed.block != datum.block + base || placed.offset != datum.offset)
            throw new SnakebiteException(
                "the program file does not fit the memory of this process");
        if (!dropped)
            archive.bytes(bytes);
    }
}


// The copies of string literals of the process store, in the order that a
// compile made them.
private void transferStrings(ref Archive archive, ref StaticStore store) {
    if (!archive.isWriting)
        archive._stringBase = store.strings.length;
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
    // A name keeps the first own copy that it gets.
    foreach (index, place; places)
        program.plans.names.defineOwn(archive.nameOfIndex(names[index]),
            archive.dataAt(place), archive.datumAt(place));
}


// The words of the data of module `index` of the file, or of the process
// store after the modules, that hold an address, as links. A link keeps them
// as links, as a compile for a save does.
private void transferAddresses(ref Archive archive, in size_t module_) {
    auto blocks = archive.blocksAt(module_);
    foreach (index; archive._dataBases[module_] .. blocks.data.length) {
        auto links = archive.isWriting && archive.isKept(module_, index)
            ? blocks.data[index].links.dup : null;
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
            const target = targetOf(archive, link.kind, reference);
            if (archive.isLinking) {
                blocks.addLink(index, linkTo(archive, link, target, reference));
                continue;
            }
            // A datum is ready to run once it is written, as after a compile
            // to RAM.
            auto place = &bytes[link.wordOffset];
            if (link.kind == Target.Kind.interfaceTable
                    || link.kind == Target.Kind.interfaceRecord) {
                archive._interfaceWords ~= InterfaceWord(place, target);
                continue;
            }
            writeWord(place, isName(link.kind)
                ? archive._program.plans.wordOfName(target) : target.address);
        }
    }
}


// Writes the word `address` at `place`, which a datum can hold at any
// offset.
private void writeWord(ubyte* place, in size_t address) {
    place[0 .. size_t.sizeof] =
        (cast(const(ubyte)*) &address)[0 .. size_t.sizeof];
}

// The link of a word of the data of a link (`transferAddresses`): `read` with
// its target in the program.
private StaticBlocks.Link linkTo(
    ref Archive archive, in StaticBlocks.Link read, in Target target,
    in size_t[3] reference,
) {
    StaticBlocks.Link link;
    link.wordOffset = read.wordOffset;
    link.kind = read.kind;
    link.index = target.index;
    if (read.kind == Target.Kind.staticData) {
        const datum = archive.datumAt(reference);
        link.set = cast(const(StaticBlocks)*) datum.set;
        link.block = datum.block;
        link.offset = datum.offset;
    } else
        link.address = target.address;
    return link;
}

private size_t[3] linkReference(ref Archive archive, in StaticBlocks.Link link) {
    if (link.kind != Target.Kind.staticData)
        return referenceOf(archive,
            Target(link.kind, link.address, DatumRef.init, link.index));
    return archive.blocksPosition(link.set, link.block, link.offset);
}


// Module `index` of the file. A link keeps the start record of a module from
// the file that has the record, and the first function of a name with a body
// (`Linker.functionNamed`): it reads the others, and drops them.
private void transferModule(ref Archive archive, in size_t index) {
    // The fields of `Module`: the start record, the blocks and the functions.
    static assert(FieldNameTuple!Module == AliasSeq!("start", "blocks", "_functions"));
    // `blocks` is set by `transferBlocks`, before the functions.
    ModuleStart dropped;
    transferStart(archive, archive.isLinking && !archive._recorded[index]
        ? dropped : archive._fileModules[index].start);
    foreach (function_; archive._fileFunctions[index]) {
        if (archive.isWriting) {
            auto prepared = prepareToWrite(archive, *function_);
            if (!archive._marking)
                archive.transfer(prepared);
        } else if (archive.isLinking) {
            // The link keeps each relocation, as a compile for a save does.
            Function copy;
            archive.transfer(isDefined(function_) ? copy : *function_);
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


private void transferStartData(ref Archive archive, ref Program program) {
    static assert(FieldNameTuple!StartData == AliasSeq!("programName",
        "hasCEntryPoint", "betterC", "modules", "crtConstructors",
        "crtDestructors", "dependencyModules", "main"));
    static assert(FieldNameTuple!MainStart == AliasSeq!("present",
        "returnsVoid", "parameterCount", "function_"));

    // A link reads the start data of each file apart, and adds it to the
    // start data of the program.
    StartData fileStart;
    auto start = archive.isLinking ? &fileStart : &program.startData;
    archive.transfer(start.programName);
    archive.transfer(start.hasCEntryPoint);
    archive.transfer(start.betterC);
    const count = archive.length(start.modules.length);
    if (archive.isWriting)
        archive.need!(ModuleStart*)(count);
    else
        start.modules = archive.newArray!(ModuleStart*)(count);
    foreach (i, ref record; start.modules) {
        size_t position;
        if (archive.isWriting) {
            const found = record in archive._moduleOfStart;
            if (found is null)
                internalFailure("a module record belongs to no module");
            position = *found;
        }
        archive.scalar(position);
        if (!archive.isWriting) {
            if (position >= archive._fileModules.length)
                throw new SnakebiteException(
                    "the program file names a module that it does not hold");
            record = &archive._fileModules[position].start;
            archive._recorded[position] = true;
        }
    }
    transferHandles(archive, start.crtConstructors);
    transferHandles(archive, start.crtDestructors);
    if (!archive.isWriting)
        start.dependencyModules = dependencyModulesOf(archive._image);
    archive.transfer(start.main.present);
    archive.transfer(start.main.returnsVoid);
    archive.transfer(start.main.parameterCount);
    if (start.main.present)
        transferHandle(archive, start.main.function_);
    if (!archive.isLinking)
        return;

    auto linked = &program.startData;
    linked.programName = fileStart.programName;
    linked.hasCEntryPoint |= fileStart.hasCEntryPoint;
    linked.betterC = fileStart.betterC;
    linked.modules ~= fileStart.modules;
    linked.crtConstructors ~= fileStart.crtConstructors;
    linked.crtDestructors ~= fileStart.crtDestructors;
    if (fileStart.main.present)
        linked.main = fileStart.main;
}


private void transferStart(ref Archive archive, ref ModuleStart record) {
    static assert(FieldNameTuple!ModuleStart == AliasSeq!("name", "standalone",
        "imports", "importNames", "independentConstructors",
        "sharedConstructors", "threadConstructors", "sharedDestructors",
        "threadDestructors", "unitTests", "sharedGates", "threadGates"));

    // The name is in the shape of the file (`transferBody`).
    archive.transfer(record.standalone);
    archive.transfer(record.imports);
    archive.transfer(record.importNames);
    transferHandles(archive, record.independentConstructors);
    transferHandles(archive, record.sharedConstructors);
    transferHandles(archive, record.threadConstructors);
    transferHandles(archive, record.sharedDestructors);
    transferHandles(archive, record.threadDestructors);
    transferHandles(archive, record.unitTests);
    transferGates(archive, record.sharedGates);
    transferGates(archive, record.threadGates);
}

// A gate is the storage of a variable: a target and a length.
private void transferGates(ref Archive archive, ref GateStorage[] gates) {
    const count = archive.length(gates.length);
    if (archive.isWriting)
        archive.need!GateStorage(count);
    else
        gates = archive.newArray!GateStorage(count);
    foreach (ref gate; gates) {
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
            // to RAM.
            // A link keeps a name, as a compile for a save does.
            const target = targetOf(archive, kind, reference);
            gate.bytes = (cast(ubyte*) (isName(kind) && !archive.isLinking
                ? archive._program.plans.wordOfName(target)
                : target.address))[0 .. length];
            if (kind == Target.Kind.staticData)
                gate.where = archive.datumAt(reference);
        }
    }
}


private void transferHandles(ref Archive archive, ref FunctionHandle[] handles) {
    const count = archive.length(handles.length);
    if (archive.isWriting)
        archive.need!FunctionHandle(count);
    else
        handles = archive.newArray!FunctionHandle(count);
    foreach (ref handle; handles)
        transferHandle(archive, handle);
}

// A handle is a compiled function of the program, named by its place.
private void transferHandle(ref Archive archive, ref FunctionHandle handle) {
    size_t[2] position;
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
    if (archive.isWriting)
        return;
    auto function_ = archive.functionAt(position[0], position[1]);
    handle = archive._memory is null
        ? new StartFunction(archive._runner, function_)
        : archive._memory.scanned.make!StartFunction(archive._runner, function_);
}
