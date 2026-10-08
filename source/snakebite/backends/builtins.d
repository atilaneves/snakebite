module snakebite.backends.builtins;


private:


// The value-passing convention every backend already uses for a native
// call (`snakebite.ffi.call.CallInvoker`, `snakebite.backends.bytecode.
// vm`'s own `executeCallPlan`): each argument is a pointer to its own
// native-layout bytes (CLAUDE.md "Runtime semantics"), and the result
// lands at a place the caller supplies. A builtin entry reads and writes
// exactly that shape, so routing a call here needs no separate
// marshalling step in either backend.
public alias BuiltinCall = extern(C) void function(
    void* returnPlace, scope const(void*)* arguments, size_t argumentCount,
) nothrow @nogc;


// `core.stdc.stdarg.va_start` as compiled D treats it: an intrinsic of the
// function that calls it, so it also reads that function's own cursor. The
// backend appends the cursor to the two declared arguments, `ap` and the
// last named parameter, which is ignored.
public extern(C) void startVariadicEntry(
    void*, scope const(void*)* arguments, size_t,
) nothrow @nogc {
    import snakebite.backends.variadic: startVariadic;

    startVariadic(
        *cast(void**) arguments[0], *cast(void**) arguments[2]);
}


// The concrete type of one parameter of a call's declaration - with the
// name, the other half of this table's lookup key, since dmd's own
// `BUILTIN` classification (`dmd.builtin.isBuiltin`) does not carry it:
// `sin(float)` and `sin(double)` both classify as `BUILTIN.sin`, and
// `bswap(uint)`/`bswap(ulong)` both classify as `BUILTIN.bswap`. Only the
// types that a wrapper of this table takes have a member.
// `void_` only describes a result.
public enum ParameterType {
    float_, double_, real_, ubyte_, ushort_, int_, uint_, long_, ulong_,
    vector_, ubytePointer_, ushortPointer_, uintPointer_, ulongPointer_,
    voidPointer_, void_,
}


// `name` is a string key, not dmd's `BUILTIN` enum value, so this
// module and the bytecode VM that calls into it need no DMD frontend
// import path (CODING.md, "Code organisation"). `null` means that no
// wrapper takes this name with exactly these parameter types and this
// result type: a wrapper writes its result at the size of its own result
// type, and reads each argument at the size of its own parameter type.
public BuiltinCall entryOf(
    in string name, in ParameterType[] parameters, in ParameterType result,
) @safe pure nothrow @nogc {
    if (parameters.length == 0)
        return null;
    final switch (parameters[0]) with (ParameterType) {
        case float_: return widthEntryOf!float(name, parameters, result);
        case double_: return widthEntryOf!double(name, parameters, result);
        case real_: return widthEntryOf!real(name, parameters, result);
        case ubyte_: return null;
        case ushort_: return integerEntryOf!ushort(name, parameters, result);
        case int_: return simdEntryOf(name, parameters[1 .. $], result);
        case uint_: return integerEntryOf!uint(name, parameters, result);
        case long_: return null;
        case ulong_: return integerEntryOf!ulong(name, parameters, result);
        case vector_: return null;
        case ubytePointer_:
            return pointerEntryOf!ubyte(name, parameters, result);
        case ushortPointer_:
            return pointerEntryOf!ushort(name, parameters, result);
        case uintPointer_:
            return pointerEntryOf!uint(name, parameters, result);
        case ulongPointer_:
            return pointerEntryOf!ulong(name, parameters, result);
        case voidPointer_:
            return name == "__prefetch"
                && parameters.takes(voidPointer_, ubyte_)
                && result == void_
                ? &prefetchEntry : null;
        case void_: return null;
    }
}


private bool takes(
    in ParameterType[] parameters, in ParameterType[] expected...
) @safe pure nothrow @nogc {
    return parameters == expected;
}


private template typeOf(T) {
    static if (is(T == float))
        enum typeOf = ParameterType.float_;
    else static if (is(T == double))
        enum typeOf = ParameterType.double_;
    else static if (is(T == real))
        enum typeOf = ParameterType.real_;
    else static if (is(T == ubyte))
        enum typeOf = ParameterType.ubyte_;
    else static if (is(T == ushort))
        enum typeOf = ParameterType.ushort_;
    else static if (is(T == int))
        enum typeOf = ParameterType.int_;
    else static if (is(T == uint))
        enum typeOf = ParameterType.uint_;
    else static if (is(T == long))
        enum typeOf = ParameterType.long_;
    else static if (is(T == ulong))
        enum typeOf = ParameterType.ulong_;
    else static if (is(T == void))
        enum typeOf = ParameterType.void_;
    else
        static assert(false, "no ParameterType for " ~ T.stringof);
}


// The parameter that the wrapper of `name` takes by address although the
// declaration passes it by value, or `size_t.max` if there is none. dmd's
// code generator takes the first operand of `__simd_sto` as the memory
// that the instruction writes.
public size_t destinationParameterOf(in string name) @safe pure nothrow @nogc {
    return name == "__simd_sto" ? 1 : size_t.max;
}


// A floating point result is any of the three types: dmd's code generator
// converts the operation's own result to the declared one, so `float
// sin(real)` is a `sin` narrowed once, as `cast(float) sin(x)`.
private BuiltinCall widthEntryOf(T)(
    in string name, in ParameterType[] parameters, in ParameterType result,
) @safe pure nothrow @nogc {
    enum self = typeOf!T;
    switch (name) {
        static foreach (oneArgumentName; oneArgumentNames)
            case oneArgumentName:
                return parameters.takes(self)
                    ? floatingResultEntryOf!(oneArgumentName, T)(result)
                    : null;
        static foreach (twoArgumentName; sameTypeTwoArgumentNames)
            case twoArgumentName:
                return parameters.takes(self, self)
                    ? floatingResultEntryOf!(twoArgumentName, T, T)(result)
                    : null;
        case "ldexp":
            // `ldexp`'s second argument is always `int`, never the
            // call's own floating point type - the one intrinsic here
            // whose arguments do not all share one type.
            return parameters.takes(self, ParameterType.int_)
                ? floatingResultEntryOf!("ldexp", T, int)(result)
                : null;
        case "rndtol":
            return parameters.takes(self) && result == ParameterType.long_
                ? &entry!("rndtol", long, T) : null;
        default:
            return null;
    }
}


private BuiltinCall floatingResultEntryOf(string name, Params...)(
    in ParameterType result,
) @safe pure nothrow @nogc {
    switch (result) with (ParameterType) {
        case float_: return &entry!(name, float, Params);
        case double_: return &entry!(name, double, Params);
        case real_: return &entry!(name, real, Params);
        default: return null;
    }
}


// Every `core.math` intrinsic snakebite has a builtin wrapper for, split
// by how many arguments it takes and, for the two-argument ones, whether
// the second argument shares the call's own floating point type.
// `rint` and `rndtol` are intrinsics of dmd's code generator
// (`dmd.glue.toir.intrinsic_op`) that its `BUILTIN` enum (`dmd.func`)
// omits, so `CallSelection` asks this table for them by module and name.
private enum oneArgumentNames = ["fabs", "sqrt", "sin", "cos", "rint", "toPrec"];
private enum sameTypeTwoArgumentNames = ["yl2x", "yl2xp1"];


// The accesses of `core.volatile` and `core.bitop`, and the bit test
// operations of `core.bitop`, keyed by the pointer's own element type.
private BuiltinCall pointerEntryOf(T)(
    in string name, in ParameterType[] parameters, in ParameterType result,
) @safe pure nothrow @nogc {
    enum element = typeOf!T;
    enum pointer = pointerTypeOf!T;
    switch (name) {
        case "volatileLoad":
            return parameters.takes(pointer) && result == element
                ? &entry!("volatileLoad", T, T*) : null;
        case "volatileStore":
            return parameters.takes(pointer, element)
                    && result == ParameterType.void_
                ? &entry!("volatileStore", void, T*, T) : null;
        static if (is(T == ulong))
            static foreach (bitTestName; bitTestNames)
                case bitTestName:
                    return parameters.takes(pointer, element)
                            && result == ParameterType.int_
                        ? &entry!(bitTestName, int, T*, T) : null;
        default:
            return null;
    }
}


private template pointerTypeOf(T) {
    static if (is(T == ubyte))
        enum pointerTypeOf = ParameterType.ubytePointer_;
    else static if (is(T == ushort))
        enum pointerTypeOf = ParameterType.ushortPointer_;
    else static if (is(T == uint))
        enum pointerTypeOf = ParameterType.uintPointer_;
    else static if (is(T == ulong))
        enum pointerTypeOf = ParameterType.ulongPointer_;
    else
        static assert(false, "no pointer ParameterType for " ~ T.stringof);
}


// `size_t` is the pointee and the bit number in `core.bitop`.
private enum bitTestNames = ["btc", "btr", "bts"];


// `core.simd.__prefetch` takes the same encoding `core.simd.prefetch`
// computes from its template arguments, and both host compilers have that
// function.
private extern(C) void prefetchEntry(
    void*, scope const(void*)* arguments, size_t argumentCount,
) @trusted nothrow @nogc {
    import core.simd: prefetch;

    assert(argumentCount == 2, "__prefetch arity");
    const address = *cast(const(void*)*) arguments[0];
    switch (*cast(const(ubyte)*) arguments[1]) {
        case 0: prefetch!(false, 3)(address); break;
        case 1: prefetch!(false, 2)(address); break;
        case 2: prefetch!(false, 1)(address); break;
        case 3: prefetch!(false, 0)(address); break;
        default: prefetch!(true, 0)(address); break;
    }
}


// dmd's own array operations (`core.internal.array.operations`) and
// `core.simd.loadUnaligned`/`storeUnaligned` move 16 bytes with these
// opcodes of `core.simd.XMM`. The values are the x86 encodings of the
// instructions, which neither host compiler declares as `XMM`: LDC has no
// `core.simd.__simd`.
private enum MoveOpcode : int {
    loadUps = 0x0F10, storeUps = 0x0F11,
    loadUpd = 0x660F10, storeUpd = 0x660F11,
    loadDqu = 0xF30F6F, storeDqu = 0xF30F7F,
}


private BuiltinCall simdEntryOf(
    in string name, in ParameterType[] rest, in ParameterType result,
) @safe pure nothrow @nogc {
    with (ParameterType) {
        if (result != vector_)
            return null;
        if (name == "__simd" && rest.takes(vector_))
            return &loadEntry;
        if (name == "__simd_sto" && rest.takes(vector_, vector_))
            return &storeEntry;
    }
    return null;
}


// `__simd(XMM opcode, void16 op1)`: the operand is the 16 bytes that the
// guest already read from memory, so the load instruction returns it.
private extern(C) void loadEntry(
    void* returnPlace, scope const(void*)* arguments, size_t argumentCount,
) @trusted nothrow @nogc {
    import core.stdc.string: memcpy;

    assert(argumentCount == 2, "__simd arity");
    requireMoveOpcode(*cast(const(int)*) arguments[0], false);
    memcpy(returnPlace, arguments[1], 16);
}


// `__simd_sto(XMM opcode, void16 op1, void16 op2)`: `op1` arrives as the
// address of the memory it names (`destinationParameterOf`).
private extern(C) void storeEntry(
    void* returnPlace, scope const(void*)* arguments, size_t argumentCount,
) @trusted nothrow @nogc {
    import core.stdc.string: memcpy;

    assert(argumentCount == 3, "__simd_sto arity");
    requireMoveOpcode(*cast(const(int)*) arguments[0], true);
    memcpy(*cast(void**) arguments[1], arguments[2], 16);
    memcpy(returnPlace, arguments[2], 16);
}


private void requireMoveOpcode(in int opcode, in bool store)
@trusted nothrow @nogc {
    import core.stdc.stdio: fprintf, stderr;

    with (MoveOpcode) switch (opcode) {
        case loadUps, loadUpd, loadDqu:
            if (!store)
                return;
            break;
        case storeUps, storeUpd, storeDqu:
            if (store)
                return;
            break;
        default:
            break;
    }
    fprintf(stderr, "snakebite: core.simd.%s has no wrapper for the opcode "
        ~ "0x%x\n", store ? "__simd_sto".ptr : "__simd".ptr, opcode);
    assert(0);
}


private BuiltinCall integerEntryOf(T)(
    in string name, in ParameterType[] parameters, in ParameterType result,
) @safe pure nothrow @nogc {
    import core.bitop;

    enum self = typeOf!T;

    switch (name) {
        // `bswap` has no `ushort` overload (`core.bitop` declares only
        // `bswap(uint)`/`bswap(ulong)` bodiless) - a plain `case` here
        // for every `T` this function is ever instantiated with would
        // still need to compile for `T == ushort`, where the call above
        // silently widens to `bswap(uint)` and returns the wrong type.
        // The `static if` keeps that case out of `T == ushort` instead,
        // matching dmd's own declarations rather than special-casing
        // `ushort` by name.
        static foreach (integerName; sameTypeIntegerNames)
            static if (is(
                typeof(mixin("core.bitop." ~ integerName ~ "(T.init)")) == T
            ))
                case integerName:
                    return parameters.takes(self) && result == self
                        ? &entry!(integerName, T, T) : null;
        // The result type is the one `core.bitop` declares for the
        // overload: `_popcnt(ushort)` returns `ushort`, the others `int`.
        static foreach (integerName; ownReturnTypeIntegerNames)
            static if (__traits(compiles,
                mixin("core.bitop." ~ integerName ~ "(T.init)")))
                case integerName:
                    return parameters.takes(self)
                            && result == typeOf!(typeof(
                                mixin("core.bitop." ~ integerName
                                    ~ "(T.init)")))
                        ? &entry!(integerName, typeof(
                            mixin("core.bitop." ~ integerName ~ "(T.init)")),
                            T)
                        : null;
        static if (is(T == uint) || is(T == ulong))
            static foreach (integerName; bitScanNames)
                case integerName:
                    return parameters.takes(self)
                            && result == ParameterType.int_
                        ? &entry!(integerName, int, T) : null;
        default:
            return null;
    }
}


// Every `core.bitop` intrinsic on an integer value that snakebite has a
// builtin wrapper for. `CallSelection` only asks for a wrapper of a
// function with no body, and `core.bitop` gives `bsf` and `bsr` one.
private enum sameTypeIntegerNames = ["bswap"];
private enum ownReturnTypeIntegerNames = ["_popcnt"];
private enum bitScanNames = ["bsf", "bsr"];


// Every entry this table serves is one concept: read each argument at
// its own parameter type from the argument pointers, call the named
// intrinsic with those values, and write the result at the type the
// guest's own declaration returns. `Result` comes from that declaration,
// never from what the host's intrinsic happens to return: LDC declares
// only the `real` overload of `yl2x`, and writing its `real` into a
// `float` result place would write bytes the place does not have.
// `core.math` and `core.bitop` declare no name in common, so importing
// both here and looking `name` up unqualified never collides.
private extern(C) void entry(string name, Result, Params...)(
    void* returnPlace, scope const(void*)* arguments, size_t argumentCount,
) @trusted nothrow @nogc {
    import snakebite.backends.dmdintrinsics;
    import core.bitop;
    import core.volatile;

    assert(argumentCount == Params.length, name ~ " arity");
    Params values;
    static foreach (i, P; Params)
        values[i] = *cast(P*) arguments[i];
    alias call = mixin(name);
    static if (is(Result == void))
        call(values);
    else
        *cast(Result*) returnPlace = cast(Result) call(values);
}
