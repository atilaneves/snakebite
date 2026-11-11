module snakebite.ffi.argumentplan;


private:


// The plain data of a ready call plan: how one value travels in System V
// AMD64 registers (`Register`, `ArgumentPlan`), the host-compiler switches
// a plan reads to interpret that shape, and the calling convention
// (`Linkage`). This module imports no part of the dmd frontend, so code that
// executes a plan needs nothing from it. `snakebite.ffi.abi` classifies dmd
// types into these shapes.

// The calling convention of a function, as far as a plan cares. It has one
// member for each member of dmd's `LINK`;
// `snakebite.ffi.abi.linkageOf` converts one.
public enum Linkage {
    default_,
    d,
    c,
    cpp,
    windows,
    objc,
    system,
}

// The integer register limit is separate: values after the first six
// integer words go on the stack, but they still belong to the function's
// parameter list.
public enum maxIntegerArguments = 6;
public enum maxFloatingArguments = 8;

// Whether this can call anything at all: these rules are for the SysV
// AMD64 ABI, and no other host ABI is implemented.
public enum supported = () {
    version (Posix) {
        version (X86_64)
            return true;
        else
            return false;
    } else
        return false;
}();

// Whether native `extern(D)` code in this process assigns parameters to
// registers in reverse declaration order. dmd's `extern(D)` variant of the
// System V convention does; ldc and gdc keep the C order.
public enum reversedDParameters = () {
    version (DigitalMars)
        return true;
    else
        return false;
}();

// Whether a method that returns a large aggregate receives its context
// before its hidden return pointer. dmd puts `this` first for `extern(D)`;
// ldc follows the System V order and puts the hidden return pointer first,
// for every linkage. On dmd, a non-`extern(D)` method - `extern(C++)`
// chief among them - follows the System V/Itanium order instead: the
// glue layer (`e2ir.d`'s `callfunc`) only folds the hidden return pointer
// in ahead of `this` when `tf.linkage == LINK.d`; for every other linkage
// on a POSIX target it is appended after `this` instead, which its own
// parameter-list nesting makes the *first* argument register, ahead of
// `this` (verified against dmd's own `callfunc`, the comment "ehidden
// goes last on Linux/OSX C++" marking exactly this branch).
public bool contextPrecedesHiddenReturnPointer(in Linkage linkage) @safe @nogc nothrow pure {
    version (DigitalMars)
        return linkage == Linkage.d || linkage == Linkage.default_;
    else
        return false;
}

// Whether an `extern(D)` untyped variadic call site's hidden `_arguments`
// argument travels as a two-register `TypeInfo[]`
// slice instead of dmd's own single pointer to the `TypeInfo_Tuple` the
// frontend's leading `typeid` expression evaluates to. Both host
// compilers' frontends insert that same `typeid` expression - this is a
// codegen difference, not a frontend one: dmd's codegen forwards the
// `TypeInfo_Tuple` reference itself, and the callee's own prologue reads
// its `elements` field to build the slice; ldc's codegen reads `elements`
// at the *call site* instead, and passes the resulting slice directly
// (verified: disassembling a real `extern(D) int f(int a, int b, int c,
// ...)` call built by ldc2 1.43, frontend 2.113.0 - the same frontend
// version this project vendors - shows `%edi`/`%esi`=length/pointer, not
// one pointer register; an ldc2-built callee's own prologue starts
// `gp_offset` at 0x18, three GP registers for `_arguments`+`a`, matching
// only the slice shape).
public enum dVariadicArgumentsIsSlice = () {
    version (LDC)
        return true;
    else
        return false;
}();

// Convert the host compiler's callback argument shape to the tuple pointer
// the frontend inserts for a guest `extern(D)` variadic call. LDC passes
// the tuple's `elements` as a slice; dmd passes the tuple object itself.
public const(void)* callbackVariadicTypes(const(void)* argument) {
    import object: TypeInfo, TypeInfo_Tuple;

    static if (dVariadicArgumentsIsSlice) {
        auto elements = *cast(TypeInfo[]*) argument;
        auto tuple = new TypeInfo_Tuple;
        tuple.elements = elements;
        return cast(const(void)*) tuple;
    } else
        return *cast(const(void)**) argument;
}

// What one value's bytes have to become to travel in one argument or
// return register. `integer` is used for an aggregate eightbyte; the
// scalar kinds retain their widening rules.
public struct Register {
    public enum Kind {
        signed,
        unsigned,
        pointer,
        integer,
        sse,
        sseup,
        x87,
        none, // nothing travels: a `void` return
    }

    public Kind kind;
    // In bytes, 1..8 for anything but `none` - not just 1, 2, 4 or 8: a
    // partial register-class eightbyte (a struct field straddling one)
    // can be any width in between, and so can a MEMORY-class argument's
    // last eightbyte.
    public ubyte size;
}

// How a value travels. A regular value has at most two eightbytes after
// the SysV cleanup rule; bare `creal` returns use two x87 registers. A
// MEMORY value - larger than two eightbytes, or
// with an unaligned field - travels as `memoryWords` whole eightbytes on
// the stack, in declaration position, a plain "copy bytes" load each:
// `registers`/`count` above are meaningless for it.
// A hidden-pointer return (`needsHiddenReturnPointer`) still bypasses this
// entirely and never builds a MEMORY `ArgumentPlan` for the return value.
public struct ArgumentPlan {
    public Register[2] registers;
    public ubyte count;
    public bool memory;
    // MEMORY-class only: this value's own byte size, never truncated -
    // `memoryWords` below is how many whole eightbytes that rounds up to,
    // the count `snakebite.ffi.plan.CallPlan.buildMoves` places on the
    // stack. Stays `0` unless `memory` is `true`.
    public size_t memoryBytes;
    // The value's ABI alignment in bytes. The stack planner uses this to
    // insert padding before an aligned value, including register-class
    // values that spill after their register file is full.
    public size_t stackAlignment;
    public bool indirect;

    public size_t memoryWords() const @safe @nogc nothrow pure scope {
        return (memoryBytes + 7) / 8;
    }
}
