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
        import dmd.astenums: Tpointer, Tvoid;
        import dmd.typesem: size;
        import std.conv: text;

        if (type.ty == Tvoid)
            return Register(Kind.none, 0);

        if (type.ty == Tpointer)
            return Register(Kind.pointer, 8);

        if (type.isIntegral) {
            const bytes = type.size;
            if (bytes == 1 || bytes == 2 || bytes == 4 || bytes == 8)
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

    // The callee left the value in the low bits of the return register;
    // anything above the type's own width is not part of it.
    switch (register.size) {
        case 1: *cast(ubyte*) place = cast(ubyte) result; return;
        case 2: *cast(ushort*) place = cast(ushort) result; return;
        case 4: *cast(uint*) place = cast(uint) result; return;
        case 8: *cast(size_t*) place = result; return;
        default: assert(false, "unsupported return size");
    }
}

// Calls `address` with `words` in argument registers and hands back the
// return register, raw. A `void` callee leaves it holding whatever it last
// used it for, so only a caller whose plan says something is returned
// reads it.
public size_t invoke(void* address, scope const size_t[] words) {
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

    alias Native = extern(C) size_t function(Repeat!(count, size_t));
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
