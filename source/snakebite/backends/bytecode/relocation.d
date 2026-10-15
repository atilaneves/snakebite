module snakebite.backends.bytecode.relocation;


private:


// What a compiled function needs to know about every word that holds an
// address of this process. A stored image has to load into a process whose
// addresses differ, so each such word names the thing it points at. This
// module imports nothing of the frontend: the VM compiles without it.

// What an address points at. `handler` words are not listed one by one: every
// instruction starts with one, so the loader finds them without a list.
public struct Target {
    public enum Kind : ubyte {
        // The handler of an instruction.
        handler,
        // Data of the program: literals, `.init` images, statics.
        staticData,
        // The `TlsDescriptor` of a thread-local variable.
        tlsDescriptor,
        // A `TypeInfo` object.
        typeInfo,
        // Code of the host process.
        hostSymbol,
        // A compiled function, as a function pointer or a delegate holds it.
        functionWord,
        // A string that the frontend owns, such as a file name.
        frontendString,
        // A value in the native constant pool.
        constantPool,
        // A prepared foreign call.
        nativePlan,
        // The signature of a function type.
        signature,
        // A delegate that prepares a call site when it first runs.
        callback,
    }

    public Kind kind;
    // The address in this process. It is the only thing a target keeps
    // besides its kind: what the address points at is described by later
    // steps.
    public size_t address;
}


// A process address together with what it points at. It does not convert to
// `size_t`, so that no address reaches an instruction or a constant without
// being recorded.
public struct Address {
    private Target _target;

    public this(in Target.Kind kind, in size_t address) @safe pure nothrow @nogc {
        _target = Target(kind, address);
    }

    public this(in Target.Kind kind, in void* address) @trusted pure nothrow @nogc {
        _target = Target(kind, cast(size_t) address);
    }

    public Target target() const @safe pure nothrow @nogc {
        return _target;
    }

    // The word that goes into the instruction or constant.
    package size_t word() const @safe pure nothrow @nogc {
        return _target.address;
    }

    public bool isNull() const @safe pure nothrow @nogc {
        return _target.address == 0;
    }
}


// Where a word that holds an address sits in a `Function`.
public struct Place {
    public enum Section : ubyte {
        instruction,
        constant,
        callSite,
        assertSite,
        exceptionHandler,
    }

    public enum Field : ubyte {
        // The operands of an instruction. A `width` never holds an address.
        destination,
        source,
        sourceWidth,
        // A constant is one word.
        word,
        // `CallSite`.
        callee,
        prepareGuest,
        nativePlan,
        prepareNativePlan,
        builtinEntry,
        valueSignature,
        // `AssertSite`.
        message,
        file,
        halt,
        // `ExceptionHandler`.
        type,
    }

    public Section section;
    // The instruction, constant, call site, assert site or exception handler.
    public size_t index;
    public Field field;
}


public struct Reloc {
    public Place place;
    public Target target;
}
