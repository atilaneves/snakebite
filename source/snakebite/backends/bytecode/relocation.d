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
        assertSite,
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
        // `AssertSite`.
        message,
        file,
        // `ExceptionHandler`.
        type,
        // `Function`.
        signature,
    }

    // The two enums come first so that a `Place` is 16 bytes.
    public Section section;
    public Field field;
    // The instruction, constant, call site, assert site or exception handler.
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
// the `Reloc` says it sits.
public struct Relocated {
    public Place.Section section;
    public Place.Field field;
}

public Relocated relocated(
    in Place.Section section, in Place.Field field,
) @safe pure nothrow @nogc {
    return Relocated(section, field);
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
