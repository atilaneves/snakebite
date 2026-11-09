module snakebite.backends.bytecode.relocation;


private:


// Thread-local policy: recording must not change other compiler users.
public bool recordRelocs;

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
        // The entry that host code calls to reach a guest function.
        callbackEntry,
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

    public this(in Target.Kind kind, in void* address) @safe pure nothrow @nogc {
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


// Function storage can move during compilation, so its places use indices.
// Native allocations have stable addresses and use absolute data places.
public struct Place {
    public enum Section : ubyte {
        instruction,
        constant,
        callSite,
        assertSite,
        exceptionHandler,
        data,
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

    // The two enums come first so that a `Place` is 16 bytes.
    public Section section;
    public Field field;
    // A function section index, or the absolute address of a data word.
    public size_t index;
}


public struct Reloc {
    public Place place;
    public Target target;
}

static assert(Reloc.sizeof == 32, "a function keeps one Reloc for each address");


// Callers own recording policy. Null words need no fixup in another process.
public void recordRelocation(ref Reloc[] relocs, in Place place, in Target target) {
    if (target.address != 0)
        relocs ~= Reloc(place, target);
}

// Compiler-known allocation bounds and typed pointer stores, not a memory scan.
public struct DataRelocations {
    public struct Block {
        public const(void)[] bytes;
        public size_t alignment;
    }

    public bool enabled;
    public Block[] blocks;
    public Reloc[] relocs;
    public size_t[size_t] targetBases;
    public struct Binding {
        public const(void)* address;
        public string symbol;
        public ptrdiff_t offset;
    }
    public Binding[] bindings;

    public void binding(in const(void)* address, in string symbol, in ptrdiff_t offset = 0) {
        if (enabled && address !is null)
            bindings ~= Binding(address, symbol, offset);
    }

    public void block(in void[] bytes, in size_t alignment) {
        if (enabled)
            blocks ~= Block(bytes, alignment);
    }

    public void pointer(in void* place, in const(void)* target,
        in const(void)* base = null) {
        if (enabled) {
            recordRelocation(relocs,
                Place(Place.Section.data, Place.Field.word, cast(size_t) place),
                Target(Target.Kind.staticData, cast(size_t) target));
            if (base !is null)
                targetBases[cast(size_t) place] = cast(size_t) base;
        }
    }

    // A copied pointer keeps its target, including aliases and interior offsets.
    // Only a complete allocation copy inherits allocation bounds and alignment.
    public void copied(in void[] source, void[] destination) {
        if (!enabled)
            return;
        foreach (allocation; blocks)
            if (allocation.bytes.ptr == source.ptr
                    && allocation.bytes.length == source.length) {
                block(destination, allocation.alignment);
                break;
            }
        foreach (reloc; relocs) {
            const offset = reloc.place.index - cast(size_t) source.ptr;
            if (offset < source.length) {
                recordRelocation(relocs,
                    Place(Place.Section.data, Place.Field.word,
                        cast(size_t) destination.ptr + offset), reloc.target);
                if (auto base = reloc.place.index in targetBases)
                    targetBases[cast(size_t) destination.ptr + offset] = *base;
            }
        }
    }
}
