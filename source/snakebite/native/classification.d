module snakebite.native.classification;

// The classification of each field of the types that a compiled program
// holds, and `Place`, which `Relocated` names. The bytecode VM and the
// shared host-call layout both import this module; it imports no frontend
// module and nothing of a backend.

private:

import snakebite.native.address: Target;

// Where a word that holds an address sits: in a `Function`, or in a datum of
// static data.
public struct Place {
    public enum Section : ubyte {
        // The `Function` itself.
        function_,
        instruction,
        constant,
        callSite,
        exceptionHandler,
        // The bytes of a datum of a `StaticBlocks`. The `index` is the
        // offset in the datum.
        datum,
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
        nativePlan,
        valueSignature,
        // `ExceptionHandler`.
        type,
        // `Function`.
        signature,
    }

    // The two enums come first so that a `Place` is 16 bytes.
    public Section section;
    public Field field;
    // The instruction, constant, call site or exception handler.
    public size_t index;
}


// How each field of a compiled program reaches a file. Every field of a type
// that a `Function` holds says it where it is declared, and a field that
// says nothing stops the build of the file writer.
//
// `plain`: the field is data. It is written as it is. A field that can hold
// an address (a pointer, a delegate or a class reference) is plain only for
// the value null: nothing but a run writes an address into it.
public struct Plain {}
public enum plain = Plain();

// The field holds an address of this process. It is not written: a `Reloc`
// of the function names what it points at, and a load puts the address of the
// same thing in the new process back. The `section` and `field` are where
// the `Reloc` says it sits, and `kind` is what the address points at.
// This attribute is the one description of the field: the recording of the
// relocs, the file and the test view all read it.
public struct Relocated {
    public Place.Section section;
    public Place.Field field;
    public Target.Kind kind;
}

public Relocated relocated(
    in Place.Section section, in Place.Field field, in Target.Kind kind,
) @safe pure nothrow @nogc {
    return Relocated(section, field, kind);
}

// The field holds code of the host executable and has no `Reloc`: the
// compiler writes it as a distance from one handler, the file holds the
// distance, and `Program.complete` makes it an address.
public struct HostCode {}
public enum hostCode = HostCode();

// The field is not in the file. The function `name` sets it after a load,
// and the same function sets it after a compile.
public struct SetBy {
    public string name;
}

public SetBy setBy(in string name) @safe pure nothrow @nogc {
    return SetBy(name);
}

// The field is not in the file, and a load leaves it at its initial value. The
// file holds only what a load needs (ADR-0017): a field that only the compile
// reads, or that no test needs after a load, says this.
public struct Unsaved {}
public enum unsaved = Unsaved();


// The classification of field `index` of `T`: `Plain`, `Relocated`, `HostCode`,
// `SetBy` or `Unsaved`.
// A field with none, or with two, stops the build.
public template classificationOf(T, size_t index) {
    import std.meta: Filter;
    import std.traits: FieldNameTuple;

    alias attributes = __traits(getAttributes, T.tupleof[index]);
    enum isKind(alias attribute) = is(typeof(attribute) == Plain)
        || is(typeof(attribute) == Relocated)
        || is(typeof(attribute) == HostCode)
        || is(typeof(attribute) == SetBy)
        || is(typeof(attribute) == Unsaved);
    alias kinds = Filter!(isKind, attributes);
    static assert(kinds.length == 1, T.stringof ~ "." ~ FieldNameTuple!T[index]
        ~ " has to say how it reaches the file: @plain, @relocated, @hostCode,"
        ~ " @setBy or @unsaved");
    enum classificationOf = kinds[0];
}

// Whether `T` is a type of the VM whose fields have to say how they reach the
// file.
public enum isClassified(T) = is(T == struct)
    && (moduleName!T == "snakebite.backends.bytecode.vm"
        || moduleName!T == "snakebite.backends.bytecode.program"
        || moduleName!T == "snakebite.stack.hostcall");

private template moduleName(T) {
    import std.traits: moduleName_ = moduleName;

    enum moduleName = moduleName_!T;
}
