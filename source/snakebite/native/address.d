module snakebite.native.address;


private:


// The types that say what an address of this process points at, so that a
// record of an address can name the thing instead of holding the value.

// What an address points at.
public struct Target {
    public enum Kind : ubyte {
        // Data of the program: literals, `.init` images, statics.
        staticData,
        // Code of the host process.
        hostSymbol,
        // A compiled function, as a function pointer or a delegate holds it.
        functionWord,
        // A copy of a string literal that the process store owns.
        adoptedString,
        // A value in the native constant pool.
        constantPool,
        // A prepared foreign call.
        nativePlan,
        // The signature of a function type.
        signature,
        // The entry that host code calls to reach a guest function.
        callbackEntry,
    }

    public Kind kind;
    // The address in this process.
    public size_t address;
    // For `staticData` and `constantPool`: the datum that the address is the
    // start of. The compiler knows it where it makes the address, so a save
    // never searches for it by the value of the address.
    public DatumRef datum;
}

// A datum of static data: the blocks that hold it (a `StaticBlocks`, opaque
// here) and where it starts in them. `set` is null when no blocks hold the
// datum, as for the image of a class, which the GC heap holds.
public struct DatumRef {
    public const(void)* set;
    public size_t block;
    public size_t offset;
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

    public this(
        in Target.Kind kind, in void* address, in DatumRef datum,
    ) @safe pure nothrow @nogc {
        _target = Target(kind, cast(size_t) address, datum);
    }

    public Target target() const @safe pure nothrow @nogc {
        return _target;
    }

    // The word that goes into the instruction or constant.
    package(snakebite) size_t word() const @safe pure nothrow @nogc {
        return _target.address;
    }

    public bool isNull() const @safe pure nothrow @nogc {
        return _target.address == 0;
    }
}
