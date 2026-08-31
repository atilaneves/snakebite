module snakebite.ffi.abi;


private:


// How many arguments this can hand over.
//
// The System V AMD64 ABI passes the first six integer-class arguments -
// integers, pointers, and anything else that fits one general-purpose
// register - in registers, and the rest on the stack in a layout this does
// not build. Six is therefore the limit, not an arbitrary cap.
public enum maxArguments = 6;

// Whether this can call anything at all: the register count above, and
// `Register`'s widening rules, are this one ABI's, and no other is
// implemented.
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
// System V convention does; ldc and gdc keep the C order. The compiler
// that built this binary also built the druntime it links, so this is a
// compile-time fact about the host process, not about the guest.
public enum reversedDParameters = () {
    version (DigitalMars)
        return true;
    else
        return false;
}();

// Whether a method that returns a large aggregate receives its context
// before its hidden return pointer. dmd puts `this` first; ldc follows the
// System V order and puts the hidden return pointer first.
public enum contextPrecedesHiddenReturnPointer = () {
    version (DigitalMars)
        return true;
    else
        return false;
}();

// What one value's bytes have to become to travel in one argument or
// return register - all a call needs to know about a type, decided once
// from the dmd `Type` and then kept, so no call reads a dmd type again.
public struct Register {
    // Which widening rule the ABI applies. The distinction is not
    // cosmetic: a callee reading a 32-bit `int` argument out of a 64-bit
    // register expects the high bits to carry the sign, so widening a
    // negative `int` with zeroes would hand it a large positive number
    // instead.
    public enum Kind {
        signed,
        unsigned,
        pointer,
        none, // nothing travels: a `void` return
    }

    public Kind kind;
    // In bytes, and always 1, 2, 4 or 8 for anything but `none`.
    public ubyte size;

    // The rule for `type`, or a refusal naming what could not travel.
    //
    // A floating-point value travels in an SSE register, and a struct by
    // value can be split across several registers or go on the stack
    // entirely, by a classification this does not implement. Both are
    // refused here - once, when the plan is prepared - rather than passed
    // in the wrong register, which would run and return a
    // plausible-looking wrong answer.
    public static Register of(imported!"dmd.mtype".Type type) {
        import dmd.astenums: Taarray, Tclass, Tpointer, Tvoid;
        import dmd.typesem: size;
        import std.conv: text;

        if (type.ty == Tvoid)
            return Register(Kind.none, 0);

        // A class reference is a pointer at native layout, same as any
        // other: `TypeInfo`, the one class-typed argument this ABI is
        // asked to pass so far (`GC.malloc`'s `ti`), is a GC-owned object
        // the guest never allocates or destructures, only hands over by
        // its address. An associative array is the same shape again: its
        // native representation is one pointer to druntime's own `Impl`
        // (or null, for an empty one) - `V[K]`, the parameter
        // `_d_aaGetRvalueX` (on the rvalue-AA-index lowering's own chain)
        // takes its associative array by, is exactly this.
        if (type.ty == Tpointer || type.ty == Tclass || type.ty == Taarray)
            return Register(Kind.pointer, 8);

        if (type.isIntegral) {
            import snakebite.nativelayout: isIntegralSize;

            const bytes = type.size;
            if (bytes.isIntegralSize)
                return Register(
                    type.isUnsigned ? Kind.unsigned : Kind.signed,
                    cast(ubyte) bytes,
                );
        }

        throw new Exception(
            text("ffi cannot pass a value of type `", type.toString,
                "`: only integer-class values are implemented"),
        );
    }
}

// How a single argument travels: one register for anything `Register`
// alone already covers, or the two a dynamic array by value needs - the
// System V AMD64 ABI classifies a 16-byte aggregate of two non-float
// eightbytes into two general-purpose registers, and a dynamic array's
// `{length, ptr}` is exactly that. druntime's own GC hooks
// (`gc_expandArrayUsed`, `gc_shrinkArrayUsed`) take the array being
// appended to this way, so this is not a value class the FFI can decline:
// declining it would mean declining to call them at all.
public struct ArgumentPlan {
    public Register[2] registers;
    public ubyte count;

    public static ArgumentPlan of(imported!"dmd.mtype".Type type) {
        import dmd.astenums: Tarray;

        if (type.ty == Tarray) {
            ArgumentPlan plan;
            plan.registers[0] = Register(Register.Kind.unsigned, 8);
            plan.registers[1] = Register(Register.Kind.pointer, 8);
            plan.count = 2;
            return plan;
        }

        ArgumentPlan plan;
        plan.registers[0] = Register.of(type);
        plan.count = 1;
        return plan;
    }
}

// The return words from an indirect call. A dynamic array's native value is
// two integer-class words, and the other supported return values use only the
// first word. Keeping both words here lets the caller preserve the exact
// native return representation without converting it.
public struct ReturnWords {
    public size_t first;
    public size_t second;
}

// Whether `type` returns through a hidden pointer instead of a register:
// the System V AMD64 ABI classifies an aggregate over 16 bytes as MEMORY
// regardless of its fields, which means the caller allocates the result's
// storage and passes its address as an extra, invisible first argument -
// `druntime`'s own `gc_query` (`GC.query`'s body-less leaf, reached when
// appending to an already-allocated array asks the block it is growing
// for its current attributes) returns `BlkInfo`, three words wide, this
// way. A struct of 16 bytes or less is classified by its fields instead
// and can travel in one or two registers - out of scope here, since
// nothing on this path returns one, and `Register.of` still refuses it.
public bool needsHiddenReturnPointer(imported!"dmd.mtype".Type type) {
    import dmd.astenums: Tstruct;
    import dmd.typesem: size;

    return type.ty == Tstruct && type.size > 16;
}

// Widens the native bytes at `slot` to the one argument register that
// carries them.
public size_t word(in Register register, in void* slot) {
    import std.conv: text;

    final switch (register.kind) with (Register.Kind) {
        case pointer:
            return cast(size_t) *cast(void**) slot;

        case unsigned:
            switch (register.size) {
                case 1: return *cast(ubyte*) slot;
                case 2: return *cast(ushort*) slot;
                case 4: return *cast(uint*) slot;
                case 8: return *cast(size_t*) slot;
                default: assert(false, "unsupported unsigned size");
            }

        case signed:
            switch (register.size) {
                case 1: return cast(size_t) cast(long) *cast(byte*) slot;
                case 2: return cast(size_t) cast(long) *cast(short*) slot;
                case 4: return cast(size_t) cast(long) *cast(int*) slot;
                case 8: return *cast(size_t*) slot;
                default: assert(false, "unsupported signed size");
            }

        case none:
            assert(false, "a `void` argument has nothing to pass");
    }
}

// Writes the return register back into `place`.
public void writeWord(
    in Register register,
    in size_t result,
    void* place,
) {
    if (register.kind == Register.Kind.none)
        return;

    import snakebite.nativelayout: storeIntegral;

    // The callee left the value in the low bits of the return register;
    // anything above the type's own width is not part of it, which is
    // exactly what storing at the type's own width keeps.
    storeIntegral(place, result, register.size);
}

// Calls `address` with `words` in argument registers and hands back the
// first two integer-class return registers, raw. A `void` callee leaves them
// holding whatever it last used them for, so only a caller whose plan says
// something is returned reads them.
public ReturnWords invoke(void* address, scope const size_t[] words) {
    import std.conv: text;

    switch (words.length) {
        static foreach (count; 0 .. maxArguments + 1) {
            case count:
                // The arity has to be in the function pointer's own type -
                // one variadic type cannot stand in for all of them, since
                // a variadic callee is passed differently.
                mixin("return (cast(Native!count) address)(",
                    argumentList(count), ");");
        }
        default:
            assert(false, "arity is checked when the plan is prepared");
    }
}

private template Native(size_t count) {
    import std.meta: Repeat;

    alias Native = extern(C) ReturnWords function(Repeat!(count, size_t));
}

private string argumentList(in size_t count) {
    import std.conv: text;

    string list;
    foreach (i; 0 .. count) {
        if (i > 0)
            list ~= ", ";
        list ~= text("words[", i, "]");
    }

    return list;
}
