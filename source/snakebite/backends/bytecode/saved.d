module snakebite.backends.bytecode.saved;


private:


import std.meta: AliasSeq, staticIndexOf;


// A compiled program as plain records and the file that holds them. This
// module imports nothing of the frontend: the bytecode VM compiles without
// it. A record names a process address by what it points at, so that the
// process that loads the file can put its own address in the same place.


// What a file that cannot be used says: another build, a damaged file, or a
// path that cannot be read.
public class SavedFileException: Exception {
    public this(string message) {
        super(message);
    }
}


// What a program cannot save. The message says why.
public class SaveRefusal: Exception {
    public this(string message) {
        super("cannot save: " ~ message);
    }
}


import snakebite.backends.bytecode.relocation: Place, Reloc, Target;
import snakebite.backends.bytecode.vm: Arg, CallSite, Function, Instruction,
    opReturnVoid, Role, Roles, rolesOf, uncounted;
import snakebite.native.signature: Shape, Signature, SignatureTable;
import snakebite.stack.frames: ReturnPlace;
import snakebite.stack.hostcall: HostCallLayout;


// What an address in a stored program points at: a datum, or the text of a
// string, and where in it.
public struct SavedTarget {
    public enum Kind : ubyte { datum, text }

    public Kind kind;
    public size_t index;
    public size_t offset;
}


public struct SavedReloc {
    public Place place;
    public SavedTarget target;
}


// A word of a datum that holds the address of a text.
public struct SavedPointer {
    public size_t offset;
    public SavedTarget target;
}


// Constant bytes of the program, with the words that hold the address of a
// text.
public struct SavedDatum {
    public ubyte[] bytes;
    public uint alignment;
    public SavedPointer[] pointers;
}


// A foreign call: the symbol, and the `NativeSignature` encoded by the
// backend (this module cannot name the type).
public struct SavedPlan {
    public string symbol;
    public ubyte[] signature;
}


public struct SavedInstruction {
    // The distance from `opReturnVoid`: the code of the handler is in the
    // same executable in every process.
    public long handler;
    public size_t destination;
    public size_t source;
    public size_t width;
    public size_t sourceWidth;
}


public struct SavedCall {
    public Arg[] args;
    public size_t returnWidth;
    public size_t plan;
}


public struct SavedFunction {
    public SavedInstruction[] instructions;
    public long[] constants;
    public SavedCall[] calls;
    public SavedReloc[] relocs;
    public size_t frameSize;
    public uint frameAlignment;
    public size_t contextOffset;
    public size_t[] parameterOffsets;
    public size_t cursorOffset;
    public size_t declaredParameters;
    public Shape[] parameters;
    public Signature.Variadic variadic;
    public ReturnPlace returnPlace;
    public HostCallLayout hostCall;
    public size_t windowSlot;
    public size_t windowBytes;
    public bool windowCallable;
    // The symbol of the function in a JIT perf map.
    public string jitName;
}


public struct SavedModule {
    public string name;
    public bool standalone;
    public size_t[] imports;
}


public struct SavedProgram {
    public string programName;
    // The directory that the program runs in.
    public string workingDirectory;
    public SavedModule[] modules;
    public bool hasMain;
    public bool returnsVoid;
    public size_t parameterCount;
    // The position of `main` in `functions`.
    public size_t main;
    public SavedFunction[] functions;
    public SavedDatum[] data;
    public ubyte[][] texts;
    public SavedPlan[] plans;
}


// The file starts with the magic, the version of the format and the build ID
// of the `sb` that wrote it. A reader compares them before it decodes
// anything else, because the records name addresses of that very build.
public void writeSaved(
    in string path, in SavedProgram program, in immutable(ubyte)[] buildId,
) {
    import std.file: rename, write, remove, exists;
    import std.conv: text;

    ubyte[] bytes = cast(ubyte[]) magic.dup;
    bytes ~= encode(formatVersion);
    bytes ~= encode(buildId);
    bytes ~= encode(program);
    const temporary = text(path, ".part");
    scope(failure) if (temporary.exists) remove(temporary);
    write(temporary, bytes);
    rename(temporary, path);
}


public SavedProgram readSaved(
    in string path, in immutable(ubyte)[] buildId,
) {
    import std.file: exists, read;

    if (!path.exists)
        throw new SavedFileException(path ~ " does not exist");
    const(ubyte)[] bytes = cast(const(ubyte)[]) read(path);
    if (bytes.length < magic.length || bytes[0 .. magic.length] != magic)
        throw new SavedFileException(path ~ " is not a saved sb program");
    bytes = bytes[magic.length .. $];
    const damaged = path ~ " is truncated or damaged";
    ulong version_;
    ubyte[] savedBuildId;
    try {
        version_ = decode!ulong(bytes);
        savedBuildId = decode!(ubyte[])(bytes);
    } catch (SavedFileException) {
        throw new SavedFileException(damaged);
    }
    if (version_ != formatVersion || savedBuildId != buildId)
        throw new SavedFileException(path ~ " was saved by another build of sb");
    try
        return decode!SavedProgram(bytes);
    catch (SavedFileException)
        throw new SavedFileException(damaged);
}


private enum ubyte[8] magic = cast(ubyte[8]) "SBCFILE\0";
private enum ulong formatVersion = 2;


// Integers, bools, enums, arrays and structs of those. An array starts with
// its length as a `ulong`.
public ubyte[] encode(T)(in T value) {
    ubyte[] bytes;
    append(bytes, value);
    return bytes;
}


public T decode(T)(ref const(ubyte)[] bytes) {
    import std.traits: isArray, isIntegral, isFloatingPoint, isStaticArray,
        OriginalType, Unqual;
    import core.stdc.string: memcpy;

    static if (is(T == enum))
        return cast(T) decode!(OriginalType!T)(bytes);
    else static if (isStaticArray!T) {
        Unqual!T result;
        foreach (ref element; result)
            element = decode!(typeof(element))(bytes);
        return result;
    }
    else static if (is(T == bool) || isIntegral!T || isFloatingPoint!T) {
        if (bytes.length < T.sizeof)
            throw new SavedFileException("short read");
        Unqual!T result;
        memcpy(&result, bytes.ptr, T.sizeof);
        bytes = bytes[T.sizeof .. $];
        return result;
    } else static if (isArray!T) {
        alias Element = Unqual!(typeof(T.init[0]));
        const length = decode!ulong(bytes);
        // Every element takes at least a byte, so a length above what is left
        // is damage, and must not become an allocation.
        if (length > bytes.length)
            throw new SavedFileException("short read");
        auto result = new Element[cast(size_t) length];
        static if (is(Element == ubyte) || is(Element == char)) {
            if (length)
                memcpy(result.ptr, bytes.ptr, cast(size_t) length);
            bytes = bytes[cast(size_t) length .. $];
        } else
            foreach (ref element; result)
                element = decode!Element(bytes);
        return cast(T) result;
    } else static if (is(T == struct)) {
        Unqual!T result;
        static foreach (i, Field; typeof(result.tupleof))
            result.tupleof[i] = decode!Field(bytes);
        return result;
    } else
        static assert(false, "cannot decode " ~ T.stringof);
}


private void append(T)(ref ubyte[] bytes, in T value) {
    import std.traits: isArray, isIntegral, isFloatingPoint, isStaticArray,
        OriginalType, Unqual;

    static if (is(T == enum))
        append(bytes, cast(OriginalType!T) value);
    else static if (isStaticArray!T) {
        foreach (element; value)
            append(bytes, element);
    }
    else static if (is(T == bool) || isIntegral!T || isFloatingPoint!T)
        bytes ~= (cast(const(ubyte)*) &value)[0 .. T.sizeof];
    else static if (isArray!T) {
        append(bytes, cast(ulong) value.length);
        static if (is(Unqual!(typeof(value[0])) == ubyte)
                || is(Unqual!(typeof(value[0])) == char))
            bytes ~= cast(const(ubyte)[]) value;
        else
            foreach (element; value)
                append(bytes, element);
    } else static if (is(T == struct)) {
        static foreach (i, Field; typeof(value.tupleof))
            append(bytes, value.tupleof[i]);
    } else
        static assert(false, "cannot encode " ~ T.stringof);
}


// The record of `function_` with plain handlers, so that it does not depend
// on the JIT setting of the process that made it, or a refusal that says what
// it holds that a stored program cannot hold yet. `targetOf` names what a
// static address points at, and `planIndexOf` the position of a foreign
// call's plan.
// `jitName` is the symbol of the function for a JIT perf map.
package SavedFunction describe(
    const(Function)* function_,
    string jitName,
    scope SavedTarget delegate(in Target) targetOf,
    scope size_t delegate(const(void)*) planIndexOf,
) {
    import std.conv: text;
    import std.traits: FieldNameTuple;

    // Every field of a function says here whether it is stored. A new field
    // stops the build until it does.
    enum storedFields = AliasSeq!(
        "instructions", "constants", "callSites", "relocs", "frameSize",
        "frameAlignment", "contextOffset", "parameterOffsets", "cursorOffset",
        "declaredParameters", "signature", "returnPlace", "hostCall",
        "windowSlot", "windowBytes", "windowCallable",
    );
    // Stored as nothing because the function holds none, or because the
    // loader sets it: the checks below refuse a function that holds one. The
    // JIT fields come from the JIT setting of the process that runs the
    // function, never from the file.
    enum absentFields = AliasSeq!(
        "assertSites", "exceptionHandlers", "closureOffset", "closureSize",
        "closureAlignment", "closureSlots", "inlineBody", "activationAlignment",
        "windowFacts", "jitHeat", "jitState", "jitCounts", "jitName", "jit",
    );
    static foreach (name; FieldNameTuple!Function)
        static assert(staticIndexOf!(name, storedFields) >= 0
            || staticIndexOf!(name, absentFields) >= 0,
            "Function." ~ name ~ " has to say whether it is stored");

    if (function_.assertSites.length)
        throw new SaveRefusal("a function has an assert or a range check");
    if (function_.exceptionHandlers.length)
        throw new SaveRefusal("a function has an exception handler");
    if (function_.closureOffset != size_t.max)
        throw new SaveRefusal("a function has a closure");

    SavedFunction result;
    result.constants = function_.constants.dup;
    foreach (instruction; function_.instructions) {
        const handler = uncounted(instruction.handler);
        Roles roles;
        if (rolesOf(handler, roles)
                && (roles.destination == Role.instruction
                    || roles.source == Role.instruction
                    || roles.sourceWidth == Role.instruction))
            throw new SaveRefusal("a function has a branch");
        result.instructions ~= SavedInstruction(
            cast(long) handler - cast(long) &opReturnVoid,
            instruction.destination, instruction.source, instruction.width,
            instruction.sourceWidth,
        );
    }

    foreach (reloc; function_.relocs) {
        // The plan of a call site is stored with the call.
        if (reloc.place.section == Place.Section.callSite
                && reloc.place.field == Place.Field.nativePlan)
            continue;
        if (reloc.target.kind != Target.Kind.staticData)
            throw new SaveRefusal(text(
                "a function holds an address of kind ", reloc.target.kind));
        result.relocs ~= SavedReloc(reloc.place, targetOf(reloc.target));
        // The word is rebuilt at load; the address of this process stays out
        // of the file.
        final switch (reloc.place.section) with (Place.Section) {
        case instruction:
            auto stored = &result.instructions[reloc.place.index];
            final switch (reloc.place.field) with (Place.Field) {
            case destination: stored.destination = 0; break;
            case source: stored.source = 0; break;
            case sourceWidth: stored.sourceWidth = 0; break;
            case word, callee, prepareGuest, nativePlan, prepareNativePlan,
                    builtinEntry, valueSignature, message, file, halt, type:
                throw new SaveRefusal(text(
                    "an instruction holds an address in ", reloc.place.field));
            }
            break;
        case constant:
            result.constants[reloc.place.index] = 0;
            break;
        case callSite, assertSite, exceptionHandler:
            throw new SaveRefusal(text(
                "a function holds an address in a ", reloc.place.section));
        }
    }

    foreach (site; function_.callSites) {
        if (site.kind != CallSite.Kind.native || site.nativePlan is null)
            throw new SaveRefusal(
                "a function has a call that is not a foreign call"
                ~ " of a known symbol");
        if (site.nativeArgs.length || site.callee !is null
                || site.prepareGuest !is null
                || site.prepareNativePlan !is null
                || site.value.signature !is null
                || site.windowSlot != size_t.max || site.hasContext
                || site.cleanupStartIndex != size_t.max)
            throw new SaveRefusal("a function has a call of a kind"
                ~ " that is not saved");
        result.calls ~= SavedCall(
            site.args.dup, site.returnWidth, planIndexOf(site.nativePlan));
    }

    result.frameSize = function_.frameSize;
    result.frameAlignment = function_.frameAlignment;
    result.contextOffset = function_.contextOffset;
    result.parameterOffsets = function_.parameterOffsets.dup;
    result.cursorOffset = function_.cursorOffset;
    result.declaredParameters = function_.declaredParameters;
    result.parameters = function_.signature.parameters.dup;
    result.variadic = function_.signature.variadic;
    result.returnPlace = function_.returnPlace;
    result.hostCall = cast() function_.hostCall;
    result.windowSlot = function_.windowSlot;
    result.windowBytes = function_.windowBytes;
    result.windowCallable = function_.windowCallable;
    result.jitName = jitName;
    return result;
}


// The function that `saved` describes in this process, with plain handlers;
// the caller arms it for the JIT. `addressOf` gives the
// address of a datum or a text, and `plans` the foreign calls in the order
// of `SavedProgram.plans`.
package Function* instantiate(
    in SavedFunction saved,
    scope void* delegate(in SavedTarget) addressOf,
    const(void)*[] plans,
    ref SignatureTable signatures,
) {
    auto result = new Function;
    const base = cast(long) &opReturnVoid;
    result.instructions.length = saved.instructions.length;
    foreach (i, instruction; saved.instructions)
        result.instructions[i] = Instruction(
            cast(Instruction.Handler) (base + instruction.handler),
            instruction.destination, instruction.source, instruction.width,
            instruction.sourceWidth,
        );
    result.constants = saved.constants.dup;
    foreach (reloc; saved.relocs) {
        const address = cast(size_t) addressOf(reloc.target);
        final switch (reloc.place.section) with (Place.Section) {
        case instruction:
            auto instruction = &result.instructions[reloc.place.index];
            switch (reloc.place.field) with (Place.Field) {
            case destination: instruction.destination = address; break;
            case source: instruction.source = address; break;
            case sourceWidth: instruction.sourceWidth = address; break;
            default: assert(false, "a stored reloc names an operand");
            }
            break;
        case constant:
            result.constants[reloc.place.index] = cast(long) address;
            break;
        case callSite, assertSite, exceptionHandler:
            assert(false, "a stored reloc names an operand or a constant");
        }
    }
    foreach (call; saved.calls)
        result.callSites ~= CallSite.native(
            plans[call.plan], call.args.dup, call.returnWidth);
    result.frameSize = saved.frameSize;
    result.frameAlignment = saved.frameAlignment;
    result.contextOffset = saved.contextOffset;
    result.parameterOffsets = saved.parameterOffsets.dup;
    result.cursorOffset = saved.cursorOffset;
    result.declaredParameters = saved.declaredParameters;
    result.signature = signatures.intern(saved.parameters, saved.variadic);
    result.returnPlace = saved.returnPlace;
    result.hostCall = cast() saved.hostCall;
    result.windowSlot = saved.windowSlot;
    result.windowBytes = saved.windowBytes;
    result.windowCallable = saved.windowCallable;
    result.fixWindowFacts;
    return result;
}
