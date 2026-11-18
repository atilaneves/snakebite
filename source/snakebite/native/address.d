module snakebite.native.address;


private:


import object: Interface, TypeInfo_Class;


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
        // The table of `interfaces[index]` of a class information of the
        // host, at `address`. On a DMD host the table has no symbol of its
        // own; the class information has one.
        interfaceTable,
        // The `Interface` record `interfaces[index]` of a class information
        // of the host, at `address`.
        interfaceRecord,
    }

    public Kind kind;
    // For `interfaceTable` and `interfaceRecord`: the index in `interfaces`.
    public uint index;
    // The address in this process. For `interfaceTable` and
    // `interfaceRecord`, the class information: `wordOf` gives the word.
    public size_t address;
    // For `staticData` and `constantPool`: the datum that the address is the
    // start of. The compiler knows it where it makes the address, so a save
    // never searches for it by the value of the address.
    public DatumRef datum;

    public this(
        in Kind kind, in size_t address, in DatumRef datum = DatumRef.init,
        in uint index = 0,
    ) @safe pure nothrow @nogc {
        this.kind = kind;
        this.index = index;
        this.address = address;
        this.datum = datum;
    }
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

    // The table or the record `interfaces[index]` of the class information
    // `classInfo`, which another object holds.
    public static Address ofInterface(
        in Target.Kind kind, in TypeInfo_Class classInfo, in size_t index,
    ) @safe pure nothrow @nogc {
        assert(kind == Target.Kind.interfaceTable
            || kind == Target.Kind.interfaceRecord);
        Address result;
        result._target = Target(kind, cast(size_t) cast(const(void)*) classInfo,
            DatumRef.init, cast(uint) index);
        return result;
    }

    // The word that goes into the instruction or constant.
    package(snakebite) size_t word() const @trusted pure nothrow @nogc {
        return wordOf(_target);
    }

    public bool isNull() const @safe pure nothrow @nogc {
        return _target.address == 0;
    }
}


// The address that a word that names `target` holds in this process: the
// one resolution of a target, for a compile to RAM and for a load. The table
// and the record of an interface come from the class information through the
// public druntime API, when the word is made ready to run.
public size_t wordOf(in Target target) pure nothrow @nogc {
    switch (target.kind) with (Target.Kind) {
        case interfaceTable:
            return cast(size_t) interfaceOf(target).vtbl.ptr;
        case interfaceRecord:
            return cast(size_t) interfaceOf(target);
        default:
            return target.address;
    }
}

private const(Interface)* interfaceOf(in Target target) pure nothrow @nogc {
    auto info = cast(const(TypeInfo_Class)) cast(const(void)*) target.address;
    assert(target.index < info.interfaces.length,
        "a class information has the interface that a word names");
    return &info.interfaces[target.index];
}
