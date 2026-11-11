module snakebite.backends.bytecode.file;


// A compiled program in a file: a header, the signatures of the program and
// the list of its modules. The file holds the types of the VM as they are:
// one `transfer` template walks them, and the same body writes a file and
// reads one. A field says where it is declared (`plain`, `relocated`, `setBy`)
// how it reaches the file, and a field that says nothing stops the build.
// Handlers are distances from one handler of `vm.d`, so a file belongs to the
// build that wrote it.
//
// This module imports nothing of the frontend.
private:

import snakebite.backends.bytecode.program: Module, Program;
import snakebite.backends.bytecode.relocation:
    Place, Plain, Reloc, Relocated, SetBy, Target;
import snakebite.backends.bytecode.runner: Runner, StartFunction;
import snakebite.backends.bytecode.vm:
    AssertSite, bindInstructionReferences, CallSite, ExceptionHandler,
    Function, handlerAt, handlerOffset, Instruction, JitSetting,
    prepareForExecution, Role, Roles, rolesOf, withoutCount;
import snakebite.failure.report: SnakebiteException;
import snakebite.image.dependency: DependencyImage;
import snakebite.ffi.callplan: NativeSignature;
import snakebite.native.staticstore: StaticBlocks;
import snakebite.native.value: TypeFacts;
import snakebite.native.signature: Signature;
import snakebite.start.data:
    dependencyModulesOf, FunctionHandle, MainStart, ModuleStart, StartData;
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

    refuseWhatIsNotSupported(program);
    auto body_ = Archive.writing(program);
    transferBody(body_, program, null);

    auto file = Archive.writing(program);
    file.text(magic);
    Header written = Header(
        header.buildKey, header.imagePath, header.workingDirectory);
    transferHeader(file, written);
    size_t signatureCount = body_._signatures.length;
    file.scalar(signatureCount);
    foreach (signature; body_._signatures) {
        // The walk takes a mutable record; a write changes nothing in it.
        auto record = Signature(signature.parameters.dup, signature.variadic);
        file.transfer(record);
    }
    file.append(body_._written.data);

    const partial = path ~ ".partial";
    scope(failure) {
        import std.file: exists;

        if (partial.exists)
            partial.remove;
    }
    partial.write(file._written.data);
    partial.rename(path);
}


// The header of the file whose bytes are `contents`.
public Header readHeader(const(ubyte)[] contents) {
    auto file = Archive.reading(contents);
    file.expectText(magic);
    Header header;
    transferHeader(file, header);
    return header;
}


// Reads the program of the file whose bytes are `contents` into `program` and
// wires `runner` to it; `image` is the dependency image that `program` was
// made with, or null. Both are as a compile leaves them, once the compile is
// done: the load calls the functions that a compile calls, in the same order.
public void loadProgram(
    const(ubyte)[] contents, ref Program program, ref Runner runner,
    in DependencyImage* image,
) {
    auto file = Archive.reading(contents);
    file._image = image;
    file.expectText(magic);
    Header header;
    transferHeader(file, header);
    size_t signatureCount;
    file.scalar(signatureCount);
    foreach (index; 0 .. signatureCount) {
        Signature signature;
        file.transfer(signature);
        file._signatures ~= program.signatures.intern(
            signature.parameters, signature.variadic);
    }
    file._program = &program;
    file._runner = &runner;
    transferBody(file, program, &runner);

    foreach (module_; program._modules)
        foreach (function_; module_._functions) {
            function_.fixWindowFacts;
            if (const reason = bindInstructionReferences(*function_))
                throw new SnakebiteException(
                    "the program file is not valid: " ~ reason);
            prepareForExecution(function_, runner.jitSetting,
                runner.jitInstance, function_.mangledName);
        }
}


private void transferHeader(ref Archive archive, ref Header header) {
    archive.transfer(header.buildKey);
    archive.transfer(header.imagePath);
    archive.transfer(header.workingDirectory);
}


// What a program that a save writes must not have yet: these need relocations
// that the file cannot hold.
private void refuseWhatIsNotSupported(ref const Program program) {
    if (!program.store.isEmpty)
        throw refusal(program.store.holdsAddressData
            ? "the program has static data that can hold an address"
            : "the program has static data of the process store");
    if (!program.plans.isEmpty)
        throw refusal("the program calls a function with a foreign call plan");
}


private SnakebiteException refusal(in string reason) {
    return new SnakebiteException(
        "cannot save the program: " ~ reason ~ ", which a program file "
        ~ "cannot hold yet");
}


// The bytes of a file as they are written or read, and the places that the
// file refers to by number: the signatures of the program and the functions
// of its modules.
private struct Archive {
    import std.array: Appender;

    private enum Direction { writing, reading }

    private Direction _direction;
    private Appender!(ubyte[]) _written;
    private const(ubyte)[] _unread;
    // The signatures, in the order of the first reference.
    private const(Signature)*[] _signatures;
    private size_t[const(Signature)*] _signatureIndex;
    // Writing: the place of each function. Reading: the function at a place.
    private size_t[2][const(Function)*] _positionOf;
    private size_t[const(ModuleStart)*] _moduleOfStart;
    private Runner* _runner;
    private Program* _program;
    private const(DependencyImage)* _image;

    static Archive writing(ref Program program) {
        Archive archive;
        archive._direction = Direction.writing;
        archive._program = &program;
        foreach (m, module_; program._modules) {
            archive._moduleOfStart[&module_.start] = m;
            foreach (f, function_; module_._functions)
                archive._positionOf[function_] = [m, f];
        }
        return archive;
    }

    static Archive reading(const(ubyte)[] contents) {
        Archive archive;
        archive._direction = Direction.reading;
        archive._unread = contents;
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

    void expectText(in string literal) {
        if (_unread.length < literal.length
                || _unread[0 .. literal.length] != cast(const(ubyte)[]) literal)
            throw new SnakebiteException(
                "the file is not a snakebite program of this format");
        _unread = _unread[literal.length .. $];
    }

    // The bytes of `data` go to the file, or come from it.
    void bytes(void[] data) {
        if (isWriting) {
            _written.put(cast(const(ubyte)[]) data);
            return;
        }
        if (_unread.length < data.length)
            throw new SnakebiteException(
                "the program file ends before the program does");
        (cast(ubyte[]) data)[] = _unread[0 .. data.length];
        _unread = _unread[data.length .. $];
    }

    void scalar(T)(ref T value) {
        bytes((cast(ubyte*) &value)[0 .. T.sizeof]);
    }

    // The length of an array, which a reader checks against what is left.
    size_t length(in size_t length) {
        size_t count = length;
        scalar(count);
        if (!isWriting && count > _unread.length)
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
        throw refusal("a function points at a function that no module holds");
    }

    // Module, block and offset of an address in the blocks of a module.
    size_t[3] dataPosition(const(void)* address) {
        foreach (m, module_; _program._modules) {
            size_t block, offset;
            if (module_.blocks.locate(address, block, offset))
                return [m, block, offset];
        }
        throw refusal("an instruction points at data that no module holds");
    }

    void* dataAt(in size_t[3] position) {
        if (position[0] < _program._modules.length)
            if (auto address = _program._modules[position[0]].blocks.addressOf(
                    position[1], position[2]))
                return address;
        throw new SnakebiteException(
            "the program file names data that it does not hold");
    }

    Function* functionAt(in size_t module_, in size_t index) {
        if (module_ >= _program._modules.length
                || index >= _program._modules[module_]._functions.length)
            throw new SnakebiteException(
                "the program file names a function that it does not hold");
        return _program._modules[module_]._functions[index];
    }
}


// Whether `T` is a type of the VM whose fields have to say how they reach the
// file.
private enum isClassified(T) = is(T == struct)
    && (moduleName!T == "snakebite.backends.bytecode.vm"
        || moduleName!T == "snakebite.backends.bytecode.program");

private template moduleName(T) {
    import std.traits: moduleName_ = moduleName;

    enum moduleName = moduleName_!T;
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

// The classification of field `index` of `T`: `Plain`, `Relocated` or `SetBy`.
// A field with none, or with two, stops the build.
private template classificationOf(T, size_t index) {
    import std.meta: Filter;

    alias attributes = __traits(getAttributes, T.tupleof[index]);
    enum isKind(alias attribute) = is(typeof(attribute) == Plain)
        || is(typeof(attribute) == Relocated) || is(typeof(attribute) == SetBy);
    alias kinds = Filter!(isKind, attributes);
    static assert(kinds.length == 1, T.stringof ~ "." ~ FieldNameTuple!T[index]
        ~ " has to say how it reaches the file: @plain, @relocated or @setBy");
    enum classificationOf = kinds[0];
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

// A struct of the VM: each field as it says.
private void transferClassified(T)(ref Archive archive, ref T value) {
    static foreach (index, name; FieldNameTuple!T) {{
        enum classification = classificationOf!(T, index);
        static if (!overlapsEarlier!(T, index)) {
            alias Field = typeof(T.tupleof[index]);
            static if (is(typeof(classification) == Plain)) {
                static if (holdsAddress!Field) {
                    if (archive.isWriting) {
                        if (wordOf(value.tupleof[index]) != 0)
                            throw refusal(text("the field ", T.stringof, ".",
                                name, " holds an address"));
                    } else
                        value.tupleof[index] = Field.init;
                } else
                    archive.transfer(value.tupleof[index]);
            } else static if (is(typeof(classification) == Relocated)) {
                static if (classification.kind == Target.Kind.handler) {
                    ptrdiff_t distance;
                    if (archive.isWriting)
                        distance = handlerOffset(value.tupleof[index]);
                    archive.scalar(distance);
                    if (!archive.isWriting)
                        value.tupleof[index] = handlerAt(distance);
                }
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
        reloc.target.address = addressOf(archive, reloc.target.kind, reference);
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
        case staticData:
            return archive.dataPosition(cast(const(void)*) target.address);
        case handler:
        case tlsDescriptor:
        case typeInfo:
        case hostSymbol:
        case frontendString:
        case constantPool:
        case nativePlan:
        case callbackEntry:
        case callback:
            throw refusal(text("a function needs a relocation of kind ",
                target.kind));
    }
}

private size_t addressOf(
    ref Archive archive, in Target.Kind kind, in size_t[3] reference,
) {
    final switch (kind) with (Target.Kind) {
        case signature:
            return cast(size_t) archive.signatureAt(reference[0]);
        case functionWord:
            return cast(size_t) archive.functionAt(reference[0], reference[1]);
        case staticData:
            return cast(size_t) archive.dataAt(reference);
        case handler:
        case tlsDescriptor:
        case typeInfo:
        case hostSymbol:
        case frontendString:
        case constantPool:
        case nativePlan:
        case callbackEntry:
        case callback:
            throw new SnakebiteException(
                "the program file holds a relocation that it cannot hold");
    }
}


// Calls `visit` with each field of `record` that holds an address, and its
// word.
private void eachRelocated(T)(
    ref const T record, scope void delegate(in Relocated, size_t) visit,
) {
    static foreach (index, name; FieldNameTuple!T) {{
        enum classification = classificationOf!(T, index);
        alias Field = typeof(T.tupleof[index]);
        static if (is(typeof(classification) == Relocated))
            visit(classification, wordOf(record.tupleof[index]));
        else static if (is(typeof(classification) == Plain)
                && isClassified!(Unqual!Field))
            eachRelocated(record.tupleof[index], visit);
    }}
}


// `function_` as a file holds it: a copy with the instructions the way the
// file means them (the handler of the instruction without a count, an
// instruction address as an index, an address left to its relocation), and
// the relocations that the file holds. A word that holds an address and no
// relocation names it cannot be written.
private Function prepareToWrite(ref Archive archive, ref Function function_) {
    Function copy = function_;
    bool[size_t[3]] listed;
    Reloc[] kept;
    foreach (reloc; function_.relocs) {
        // The strings of an assertion are in the file as bytes.
        if (reloc.place.section == Place.Section.assertSite
                && reloc.target.kind == Target.Kind.frontendString)
            continue;
        // Refuses any other kind that the file cannot hold.
        referenceOf(archive, reloc.target);
        listed[[cast(size_t) reloc.place.section,
            cast(size_t) reloc.place.field, reloc.place.index]] = true;
        kept ~= reloc;
    }
    copy.relocs = kept;

    void require(
        in Relocated relocated, in size_t index, in size_t word,
    ) {
        if (word != 0 && !([cast(size_t) relocated.section,
                cast(size_t) relocated.field, index] in listed))
            throw refusal(text("a word of `", function_.hostCall.name,
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
        instruction.handler = withoutCount(instruction.handler);
        Roles roles;
        if (!rolesOf(instruction.handler, roles))
            continue;
        static foreach (name; ["destination", "source", "sourceWidth"]) {{
            const role = mixin("roles." ~ name);
            auto field = &mixin("instruction." ~ name);
            if (role == Role.instruction)
                *field = (*field - cast(size_t) function_.instructions.ptr)
                    / Instruction.sizeof;
            else if (role == Role.address) {
                require(Relocated(Target.Kind.handler,
                    Place.Section.instruction,
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
    const place = reloc.place;
    const address = reloc.target.address;
    bool done;
    final switch (place.section) with (Place.Section) {
        case function_:
            done = assignRelocated(target, place.field, address);
            break;
        case instruction:
            if (place.index < target.instructions.length)
                done = assignOperand(
                    target.instructions[place.index], place.field, address);
            break;
        case constant:
            if (place.index < target.constants.length
                    && place.field == Place.Field.word) {
                target.constants[place.index] = cast(long) address;
                done = true;
            }
            break;
        case callSite:
            if (place.index < target.callSites.length)
                done = assignRelocated(target.callSites[place.index],
                    place.field, address);
            break;
        case assertSite:
        case exceptionHandler:
            break;
    }
    if (!done)
        throw new SnakebiteException(
            "the program file holds a relocation with no place");
}

// Sets the operand of `instruction` at `field`, if an operand sits there.
private bool assignOperand(
    ref Instruction instruction, in Place.Field field, in size_t address,
) {
    final switch (field) with (Place.Field) {
        case destination:
            instruction.destination = address;
            return true;
        case source:
            instruction.source = address;
            return true;
        case sourceWidth:
            instruction.sourceWidth = address;
            return true;
        case word:
        case callee:
        case prepareGuest:
        case nativePlan:
        case prepareNativePlan:
        case builtinEntry:
        case valueSignature:
        case message:
        case file:
        case halt:
        case type:
        case signature:
            return false;
    }
}

// Sets the field of `record` that is relocated at `field`, to `word`.
private bool assignRelocated(T)(ref T record, in Place.Field field, in size_t word) {
    static foreach (index, name; FieldNameTuple!T) {{
        enum classification = classificationOf!(T, index);
        alias Field = typeof(T.tupleof[index]);
        static if (is(typeof(classification) == Relocated)) {
            static if (is(Field == U*, U)) {
                if (classification.field == field) {
                    record.tupleof[index] = cast(Field) word;
                    return true;
                }
            }
        } else static if (is(typeof(classification) == Plain)
                && isClassified!(Unqual!Field)) {
            if (assignRelocated(record.tupleof[index], field, word))
                return true;
        }
    }}
    return false;
}


private void transferBody(
    ref Archive archive, ref Program program, Runner* runner,
) {
    // The shape first, so that a function can refer to any other.
    size_t moduleCount = archive.length(program._modules.length);
    if (!archive.isWriting)
        foreach (m; 0 .. moduleCount)
            program.newModule;
    foreach (m; 0 .. moduleCount) {
        size_t functionCount =
            archive.length(archive.isWriting
                ? program._modules[m]._functions.length : 0);
        if (!archive.isWriting)
            foreach (f; 0 .. functionCount)
                program._modules[m].newFunction;
    }
    transferStartData(archive, program);
    // All data before any function: a function can point into any module.
    foreach (m; 0 .. moduleCount)
        transferBlocks(archive, program._modules[m].blocks);
    foreach (m; 0 .. moduleCount)
        transferModule(archive, program, *program._modules[m]);
}


// The data of a module as bytes. A load reserves each datum through the same
// code as a compile, so the blocks come out the same, and checks that. A
// datum whose type can hold an address has no relocation records yet, and a
// save refuses it.
private void transferBlocks(ref Archive archive, ref StaticBlocks blocks) {
    const count = archive.length(blocks.data.length);
    foreach (index; 0 .. count) {
        StaticBlocks.Datum datum;
        if (archive.isWriting) {
            datum = blocks.data[index];
            if (datum.canHoldAddress)
                throw refusal("a module has static data that can hold an "
                    ~ "address");
        }
        archive.scalar(datum.block);
        archive.scalar(datum.offset);
        archive.scalar(datum.size);
        archive.scalar(datum.alignment);
        if (archive.isWriting) {
            archive.bytes(cast(void[]) blocks.bytesOf(datum));
            continue;
        }
        TypeFacts facts;
        facts.size = datum.size;
        facts.alignment = datum.alignment;
        facts.canHoldAddress = false;
        auto bytes = blocks.reserve(facts);
        const placed = blocks.data[$ - 1];
        if (placed.block != datum.block || placed.offset != datum.offset)
            throw new SnakebiteException(
                "the program file does not fit the memory of this process");
        archive.bytes(bytes);
    }
}


private void transferModule(
    ref Archive archive, ref Program program, ref Module module_,
) {
    // The fields of `Module`: the start record, the blocks (empty: a save
    // refuses a module with data), and the functions.
    static assert(FieldNameTuple!Module == AliasSeq!("start", "blocks", "_functions"));
    // `blocks` is set by `transferBlocks`, before the functions.
    transferStart(archive, module_.start);
    foreach (function_; module_._functions) {
        if (archive.isWriting) {
            auto prepared = prepareToWrite(archive, *function_);
            archive.transfer(prepared);
        } else {
            archive.transfer(*function_);
            foreach (reloc; function_.relocs)
                applyReloc(*function_, reloc);
            function_.relocs = null;
        }
        NativeSignature signature;
        if (archive.isWriting) {
            const registered = program.plans.callbacks.signatureOf(function_);
            if (registered is null)
                throw refusal("a function has no registered signature");
            signature = cast(NativeSignature) *registered;
        }
        archive.transfer(signature);
        if (!archive.isWriting)
            program.plans.callbacks.register(function_, signature);
    }
}


private void transferStartData(ref Archive archive, ref Program program) {
    static assert(FieldNameTuple!StartData == AliasSeq!("programName",
        "hasCEntryPoint", "betterC", "modules", "crtConstructors",
        "crtDestructors", "dependencyModules", "main"));
    static assert(FieldNameTuple!MainStart == AliasSeq!("present",
        "returnsVoid", "parameterCount", "function_"));

    ref start = program.startData;
    archive.transfer(start.programName);
    archive.transfer(start.hasCEntryPoint);
    archive.transfer(start.betterC);
    const count = archive.length(start.modules.length);
    if (!archive.isWriting)
        start.modules = new ModuleStart*[count];
    foreach (i, ref record; start.modules) {
        size_t position;
        if (archive.isWriting) {
            const found = record in archive._moduleOfStart;
            if (found is null)
                throw refusal("a module record belongs to no module");
            position = *found;
        }
        archive.scalar(position);
        if (!archive.isWriting) {
            if (position >= program._modules.length)
                throw new SnakebiteException(
                    "the program file names a module that it does not hold");
            record = &program._modules[position].start;
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
}


private void transferStart(ref Archive archive, ref ModuleStart record) {
    static assert(FieldNameTuple!ModuleStart == AliasSeq!("name", "standalone",
        "imports", "importNames", "independentConstructors",
        "sharedConstructors", "threadConstructors", "sharedDestructors",
        "threadDestructors", "unitTests", "sharedGates", "threadGates"));

    archive.transfer(record.name);
    archive.transfer(record.standalone);
    archive.transfer(record.imports);
    archive.transfer(record.importNames);
    transferHandles(archive, record.independentConstructors);
    transferHandles(archive, record.sharedConstructors);
    transferHandles(archive, record.threadConstructors);
    transferHandles(archive, record.sharedDestructors);
    transferHandles(archive, record.threadDestructors);
    transferHandles(archive, record.unitTests);
    if (archive.isWriting && (record.sharedGates.length != 0
            || record.threadGates.length != 0))
        throw refusal("a module has the gate of a destructor");
}


private void transferHandles(ref Archive archive, ref FunctionHandle[] handles) {
    const count = archive.length(handles.length);
    if (!archive.isWriting)
        handles = new FunctionHandle[count];
    foreach (ref handle; handles)
        transferHandle(archive, handle);
}

// A handle is a compiled function of the program, named by its place.
private void transferHandle(ref Archive archive, ref FunctionHandle handle) {
    size_t[2] position;
    if (archive.isWriting) {
        const compiled = cast(const(Function)*) handle.compiledCode;
        if (compiled is null)
            throw refusal("a start function is not one of the bytecode backend");
        position = archive.positionOf(compiled);
    }
    archive.scalar(position);
    if (!archive.isWriting)
        handle = new StartFunction(
            archive._runner, archive.functionAt(position[0], position[1]));
}
