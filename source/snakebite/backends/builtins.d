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
    float_, double_, real_, ubyte_, ushort_, short_, int_, uint_, long_, ulong_,
    vector_, pointer_, void_,
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
        case ubyte_: return portEntryOf!ubyte(name, parameters, result);
        case ushort_: return integerEntryOf!ushort(name, parameters, result);
        case short_: return integerEntryOf!ushort(name, parameters, result);
        case int_:
            return name == "__simd" || name == "__simd_sto"
                ? simdEntryOf(name, parameters[1 .. $], result)
                : integerEntryOf!uint(name, parameters, result);
        case uint_: return integerEntryOf!uint(name, parameters, result);
        case long_: return integerEntryOf!ulong(name, parameters, result);
        case ulong_: return integerEntryOf!ulong(name, parameters, result);
        case vector_: return null;
        case pointer_:
            return name == "__prefetch"
                && parameters.takes(pointer_, ubyte_)
                && result == void_
                ? &prefetchEntry : pointerEntryOf(name, parameters, result);
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
    else static if (is(T == short))
        enum typeOf = ParameterType.short_;
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
        static foreach (twoArgumentName; floatingTwoArgumentNames) {
            case twoArgumentName: {
                if (parameters.length != 2)
                    return null;
                switch (parameters[1]) with (ParameterType) {
                    case float_:
                        return floatingResultEntryOf!(twoArgumentName, T, float)(result);
                    case double_:
                        return floatingResultEntryOf!(twoArgumentName, T, double)(result);
                    case real_:
                        return floatingResultEntryOf!(twoArgumentName, T, real)(result);
                    default: return null;
                }
            }
        }
        case "ldexp":
            // `ldexp`'s second argument is always `int`, never the
            // call's own floating point type - the one intrinsic here
            // whose arguments do not all share one type.
            return parameters.takes(self, ParameterType.int_)
                ? floatingResultEntryOf!("ldexp", T, int)(result)
                : null;
        case "rndtol":
            return parameters.takes(self)
                ? roundedResultEntryOf!T(result) : null;
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
private enum floatingTwoArgumentNames = ["yl2x", "yl2xp1"];


// Volatile accesses use the result or stored value width. Memory bit
// operations use the index width. Neither uses the pointer's element type.
private BuiltinCall pointerEntryOf(
    in string name, in ParameterType[] parameters, in ParameterType result,
) @safe pure nothrow @nogc {
    switch (name) {
        case "volatileLoad":
            return parameters.takes(ParameterType.pointer_)
                ? volatileEntryOf!false(result) : null;
        case "volatileStore":
            if (parameters.length != 2)
                return null;
            return result == ParameterType.void_
                ? volatileEntryOf!true(parameters[1])
                : result == parameters[1]
                    ? volatileEntryOf!(true, true)(parameters[1]) : null;
        static foreach (bitTestName; bitTestNames) {
            case bitTestName: {
                if (parameters.length != 2)
                    return null;
                switch (parameters[1]) with (ParameterType) {
                    case short_, ushort_:
                        return integerResultEntryOf!(bitTestName, void*, ushort)(result);
                    case int_, uint_:
                        return integerResultEntryOf!(bitTestName, void*, uint)(result);
                    case long_, ulong_:
                        return integerResultEntryOf!(bitTestName, void*, ulong)(result);
                    default: return null;
                }
            }
        }
        default:
            return null;
    }
}


private BuiltinCall volatileEntryOf(bool store, bool returnsValue = false)(
    in ParameterType type,
)
@safe pure nothrow @nogc {
    switch (type) with (ParameterType) {
        case ubyte_: return &volatileEntry!(store, returnsValue, ubyte);
        case short_, ushort_: return &volatileEntry!(store, returnsValue, ushort);
        case int_, uint_, float_: return &volatileEntry!(store, returnsValue, uint);
        case long_, ulong_, double_, pointer_:
            return &volatileEntry!(store, returnsValue, ulong);
        case real_: return &volatileWideEntry!(store, returnsValue, 10);
        case vector_: return &volatileWideEntry!(store, returnsValue, 16);
        default: return null;
    }
}


private extern(C) void volatileEntry(bool store, bool returnsValue, T)(
    void* returnPlace, scope const(void*)* arguments, size_t argumentCount,
) nothrow @nogc {
    import core.volatile: volatileLoad, volatileStore;

    assert(argumentCount == (store ? 2 : 1));
    auto address = *cast(T**) arguments[0];
    static if (store) {
        volatileStore(address, *cast(const(T)*) arguments[1]);
        static if (returnsValue)
            *cast(T*) returnPlace = *cast(const(T)*) arguments[1];
    } else
        *cast(T*) returnPlace = volatileLoad(address);
}


// An x87 real has ten value bytes. Its native layout has padding that a
// volatile store must not write. A wide MMIO access must not be split into
// several unsigned loads or stores when dmd emits one instruction.
private extern(C) void volatileWideEntry(
    bool store, bool returnsValue, size_t width,
)(
    void* returnPlace, scope const(void*)* arguments, size_t argumentCount,
) nothrow @nogc {
    import snakebite.backends.dmdintrinsics: volatileCopyWide;

    assert(argumentCount == (store ? 2 : 1));
    auto address = *cast(void**) arguments[0];
    static if (store)
        volatileCopyWide!width(address, arguments[1]);
    else
        volatileCopyWide!width(returnPlace, address);
    static if (returnsValue) {
        import core.stdc.string: memcpy;

        memcpy(returnPlace, arguments[1], width);
    }
}


private BuiltinCall integerResultEntryOf(string name, Params...)(
    in ParameterType result,
) @safe pure nothrow @nogc {
    switch (result) with (ParameterType) {
        case ubyte_: return &entry!(name, ubyte, Params);
        case short_: return &entry!(name, short, Params);
        case ushort_: return &entry!(name, ushort, Params);
        case int_: return &entry!(name, int, Params);
        case uint_: return &entry!(name, uint, Params);
        case long_: return &entry!(name, long, Params);
        case ulong_: return &entry!(name, ulong, Params);
        default: return null;
    }
}


private BuiltinCall roundedResultEntryOf(T)(in ParameterType result)
@safe pure nothrow @nogc {
    switch (result) with (ParameterType) {
        case short_, ushort_: return &roundedEntry!(short, T);
        case int_, uint_: return &roundedEntry!(int, T);
        case long_, ulong_: return &roundedEntry!(long, T);
        default: return null;
    }
}


private extern(C) void roundedEntry(Result, T)(
    void* returnPlace, scope const(void*)* arguments, size_t argumentCount,
) nothrow @nogc {
    import snakebite.backends.dmdintrinsics: roundedTo;

    assert(argumentCount == 1);
    *cast(Result*) returnPlace = roundedTo!Result(*cast(const(T)*) arguments[0]);
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
    const self = parameters[0];
    switch (name) {
        case "inp", "inpw", "inpl", "outp", "outpw", "outpl":
            return portEntryOf!T(name, parameters, result);
        case "bswap":
            return parameters.takes(self) && result != ParameterType.ubyte_
                ? integerResultEntryOf!("bswap", T)(result) : null;
        static foreach (integerName; ["_popcnt", "bsf", "bsr"])
            case integerName:
                return parameters.takes(self)
                    ? integerResultEntryOf!(integerName, T)(result) : null;
        default:
            return null;
    }
}


private BuiltinCall portEntryOf(T)(
    in string name, in ParameterType[] parameters, in ParameterType result,
) @safe pure nothrow @nogc {
    switch (name) {
        static foreach (input; ["inp", "inpw", "inpl"]) {
            case input: {
                if (parameters.length != 1)
                    return null;
                switch (result) with (ParameterType) {
                    case ubyte_: return &entry!(input, ubyte, T);
                    case short_: return &entry!(input, short, T);
                    case ushort_: return &entry!(input, ushort, T);
                    case int_: return &entry!(input, int, T);
                    case uint_: return &entry!(input, uint, T);
                    default: return null;
                }
            }
        }
        static foreach (output; ["outp", "outpw", "outpl"]) {
            case output: {
                if (parameters.length != 2)
                    return null;
                switch (parameters[1]) with (ParameterType) {
                    case ubyte_:
                        return portOutputEntryOf!(output, T, ubyte)(result);
                    case short_, ushort_:
                        return portOutputEntryOf!(output, T, ushort)(result);
                    case int_, uint_:
                        return portOutputEntryOf!(output, T, uint)(result);
                    default: return null;
                }
            }
        }
        default: return null;
    }
}


private BuiltinCall portOutputEntryOf(string name, Port, Value)(
    in ParameterType result,
) @safe pure nothrow @nogc {
    return result == ParameterType.void_
        ? &entry!(name, void, Port, Value)
        : integerResultEntryOf!(name, Port, Value)(result);
}


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
    static if (name == "btc" || name == "btr" || name == "bts")
        alias call = bitTest!(name, Params[1]);
    else static if (name == "inp" || name == "inpw" || name == "inpl")
        alias call = portInput!(Result, Params[0]);
    else static if (name == "outp" || name == "outpw" || name == "outpl")
        alias call = portOutput!(Params[1], Params[0]);
    else static if (name == "bswap")
        alias call = swapTo!(Result, Params[0]);
    else
        alias call = mixin(name);
    static if (is(Params[0] == float) || is(Params[0] == double)
            || is(Params[0] == real)) {
        // x87 works at extended precision. A wider declared result must
        // not first pass through the operand's narrower result overload.
        static if (name == "sqrt" && is(Result == Params[0]))
            *cast(Result*) returnPlace = call(values);
        else static if (Params.length == 1)
            *cast(Result*) returnPlace = cast(Result) call(cast(real) values[0]);
        else static if (name == "ldexp")
            *cast(Result*) returnPlace = cast(Result) call(
                cast(real) values[0], values[1]);
        else
            *cast(Result*) returnPlace = cast(Result) call(
                cast(real) values[0], cast(real) values[1]);
    } else static if (is(Result == void))
        call(values);
    else
        *cast(Result*) returnPlace = cast(Result) call(values);
}
