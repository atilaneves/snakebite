module snakebite.backends.bytecode.relocation;


private:


import snakebite.native.address: Target;


// What a compiled function needs to know about every word that holds an
// address of this process. A stored image has to load into a process whose
// addresses differ, so each such word names the thing it points at. This
// module imports nothing of the frontend: the VM compiles without it.
//
// A word that holds code of the host executable (the handler of an
// instruction, the entry of a builtin call, the action of a halting check) has
// no `Reloc`: the file holds it as a distance from one handler, and a field of
// that kind says so with `hostCode`.

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


public struct Reloc {
    public Place place;
    public Target target;
}

static assert(Reloc.sizeof == 56, "a function keeps one Reloc for each address");


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

// The field holds code of the host executable and has no `Reloc`: the file
// holds it as a distance from one handler. Only a field of the handler type
// of an instruction is never null.
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


// The classification of field `index` of `T`: `Plain`, `Relocated`, `HostCode`
// or `SetBy`.
// A field with none, or with two, stops the build.
public template classificationOf(T, size_t index) {
    import std.meta: Filter;
    import std.traits: FieldNameTuple;

    alias attributes = __traits(getAttributes, T.tupleof[index]);
    enum isKind(alias attribute) = is(typeof(attribute) == Plain)
        || is(typeof(attribute) == Relocated)
        || is(typeof(attribute) == HostCode)
        || is(typeof(attribute) == SetBy);
    alias kinds = Filter!(isKind, attributes);
    static assert(kinds.length == 1, T.stringof ~ "." ~ FieldNameTuple!T[index]
        ~ " has to say how it reaches the file: @plain, @relocated, @hostCode or @setBy");
    enum classificationOf = kinds[0];
}

// Whether `T` is a type of the VM whose fields have to say how they reach the
// file.
public enum isClassified(T) = is(T == struct)
    && (moduleName!T == "snakebite.backends.bytecode.vm"
        || moduleName!T == "snakebite.backends.bytecode.program");

private template moduleName(T) {
    import std.traits: moduleName_ = moduleName;

    enum moduleName = moduleName_!T;
}

// Calls `visit` with each field of `record` that holds an address, and its
// word.
public void eachRelocated(T)(
    ref const T record, scope void delegate(in Relocated, size_t) visit,
) {
    import std.traits: FieldNameTuple, Unqual;

    static foreach (index, name; FieldNameTuple!T) {{
        enum classification = classificationOf!(T, index);
        alias Field = typeof(T.tupleof[index]);
        static if (is(typeof(classification) == Relocated)) {
            static assert(Field.sizeof == size_t.sizeof);
            visit(classification,
                cast(size_t) cast(const(void)*) record.tupleof[index]);
        }
        else static if (is(typeof(classification) == Plain)
                && isClassified!(Unqual!Field))
            eachRelocated(record.tupleof[index], visit);
    }}
}

// The word of the field of `record` that is relocated at `field`, or null
// when `record` has no such field.
public inout(size_t)* relocatedWord(T)(
    ref inout T record, in Place.Field field,
) {
    import std.traits: FieldNameTuple, Unqual;

    static foreach (index, name; FieldNameTuple!T) {{
        enum classification = classificationOf!(T, index);
        alias Field = typeof(T.tupleof[index]);
        static if (is(typeof(classification) == Relocated)) {
            if (classification.field == field)
                return cast(inout(size_t)*) &record.tupleof[index];
        } else static if (is(typeof(classification) == Plain)
                && isClassified!(Unqual!Field)) {
            if (auto word = relocatedWord(record.tupleof[index], field))
                return word;
        }
    }}
    return null;
}
