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
// `word`'s widening rules, are this one ABI's, and no other is implemented.
public enum supported = () {
    version (Posix) {
        version (X86_64)
            return true;
        else
            return false;
    } else
        return false;
}();

// Widens the native bytes at `slot` to the one argument register that
// carries a value of `type`.
//
// The widening is the ABI's rule, not a convenience: a callee reading a
// 32-bit `int` argument out of a 64-bit register expects the high bits to
// carry the sign, so widening a negative `int` with zeroes would hand it a
// large positive number instead.
public size_t word(imported!"dmd.mtype".Type type, in void* slot) {
    import dmd.astenums: Tpointer;
    import dmd.typesem: size;
    import std.conv: text;

    if (type.ty == Tpointer)
        return cast(size_t) *cast(void**) slot;

    if (type.isIntegral) {
        const unsigned = type.isUnsigned;
        switch (type.size) {
            case 1:
                return unsigned
                    ? *cast(ubyte*) slot
                    : cast(size_t) cast(long) *cast(byte*) slot;
            case 2:
                return unsigned
                    ? *cast(ushort*) slot
                    : cast(size_t) cast(long) *cast(short*) slot;
            case 4:
                return unsigned
                    ? *cast(uint*) slot
                    : cast(size_t) cast(long) *cast(int*) slot;
            case 8:
                return *cast(size_t*) slot;
            default:
                break;
        }
    }

    // A floating-point value travels in an SSE register, and a struct by
    // value can be split across several registers or go on the stack
    // entirely, by a classification this does not implement. Refused
    // rather than passed in the wrong register, which would run and
    // return a plausible-looking wrong answer.
    throw new Exception(
        text("ffi cannot pass a value of type `", type.toString,
            "`: only integer-class arguments are implemented"),
    );
}

// Writes the return register back into `place` as a value of `type`.
public void writeWord(
    imported!"dmd.mtype".Type type,
    in size_t result,
    void* place,
) {
    import dmd.astenums: Tpointer;
    import dmd.typesem: size;
    import std.conv: text;

    if (type.ty == Tpointer) {
        *cast(void**) place = cast(void*) result;
        return;
    }

    if (type.isIntegral) {
        // The callee left the value in the low bits of the return
        // register; anything above the type's own width is not part of it.
        switch (type.size) {
            case 1: *cast(ubyte*) place = cast(ubyte) result; return;
            case 2: *cast(ushort*) place = cast(ushort) result; return;
            case 4: *cast(uint*) place = cast(uint) result; return;
            case 8: *cast(size_t*) place = result; return;
            default: break;
        }
    }

    throw new Exception(
        text("ffi cannot return a value of type `", type.toString,
            "`: only integer-class returns are implemented"),
    );
}

// Calls `address` with `words` in argument registers and hands back the
// return register, raw. A `void` function leaves it holding whatever the
// callee happened to leave there, so only a caller that knows the callee
// returns something reads it.
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
            throw new Exception(
                text("ffi cannot call a function with ", words.length,
                    " arguments: at most ", maxArguments,
                    " are passed in registers"),
            );
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
