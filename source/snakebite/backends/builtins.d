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
public enum ParameterType {
    float_, double_, real_, ubyte_, ushort_, int_, uint_, ulong_, vector_,
    ubytePointer_, ushortPointer_, uintPointer_, ulongPointer_, voidPointer_,
}


// `name` is a string key, not dmd's `BUILTIN` enum value, so this
// module and the bytecode VM that calls into it need no DMD frontend
// import path (CODING.md, "Code organisation"). `null` means that no
// wrapper takes this name with these parameter types.
public BuiltinCall entryOf(in string name, in ParameterType[] types)
@safe pure nothrow @nogc {
    assert(types.length > 0);
    final switch (types[0]) with (ParameterType) {
        case float_: return widthEntryOf!float(name);
        case double_: return widthEntryOf!double(name);
        case real_: return widthEntryOf!real(name);
        case ubyte_: return null;
        case ushort_: return integerEntryOf!ushort(name);
        case int_: return simdEntryOf(name, types[1 .. $]);
        case uint_: return integerEntryOf!uint(name);
        case ulong_: return integerEntryOf!ulong(name);
        case vector_: return null;
        case ubytePointer_: return volatileEntryOf!ubyte(name);
        case ushortPointer_: return volatileEntryOf!ushort(name);
        case uintPointer_: return volatileEntryOf!uint(name);
        case ulongPointer_: return volatileEntryOf!ulong(name);
        case voidPointer_: return name == "__prefetch" ? &prefetchEntry : null;
    }
}


// The parameter that the wrapper of `name` takes by address although the
// declaration passes it by value, or `size_t.max` if there is none. dmd's
// code generator takes the first operand of `__simd_sto` as the memory
// that the instruction writes.
public size_t destinationParameterOf(in string name) @safe pure nothrow @nogc {
    return name == "__simd_sto" ? 1 : size_t.max;
}


private BuiltinCall widthEntryOf(T)(in string name)
@safe pure nothrow @nogc {
    switch (name) {
        static foreach (oneArgumentName; oneArgumentNames)
            case oneArgumentName:
                return &entry!(oneArgumentName, T, T);
        static foreach (twoArgumentName; sameTypeTwoArgumentNames)
            case twoArgumentName:
                return &entry!(twoArgumentName, T, T, T);
        case "ldexp":
            // `ldexp`'s second argument is always `int`, never the
            // call's own floating point type - the one intrinsic here
            // whose arguments do not all share one type.
            return &entry!("ldexp", T, T, int);
        case "rndtol":
            return &entry!("rndtol", long, T);
        default:
            return null;
    }
}


// Every `core.math` intrinsic snakebite has a builtin wrapper for, split
// by how many arguments it takes and, for the two-argument ones, whether
// the second argument shares the call's own floating point type.
// `rint` and `rndtol` are intrinsics of dmd's code generator
// (`dmd.glue.toir.intrinsic_op`) that its `BUILTIN` enum (`dmd.func`)
// omits, so `CallSelection` asks this table for them by module and name.
private enum oneArgumentNames = ["fabs", "sqrt", "sin", "cos", "rint"];
private enum sameTypeTwoArgumentNames = ["yl2x", "yl2xp1"];


// `core.volatile`'s accesses, keyed by the pointer's own element type.
private BuiltinCall volatileEntryOf(T)(in string name)
@safe pure nothrow @nogc {
    switch (name) {
        case "volatileLoad": return &entry!("volatileLoad", T, T*);
        case "volatileStore": return &entry!("volatileStore", void, T*, T);
        default: return null;
    }
}


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


private BuiltinCall simdEntryOf(in string name, in ParameterType[] types)
@safe pure nothrow @nogc {
    if (types.length == 1 && types[0] == ParameterType.vector_) {
        if (name == "__simd")
            return &loadEntry;
        return null;
    }
    if (types.length == 2 && types[0] == ParameterType.vector_
            && types[1] == ParameterType.vector_ && name == "__simd_sto")
        return &storeEntry;
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


private BuiltinCall integerEntryOf(T)(in string name)
@safe pure nothrow @nogc {
    import core.bitop;

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
                    return &entry!(integerName, T, T);
        static foreach (integerName; ownReturnTypeIntegerNames)
            static if (__traits(compiles,
                mixin("core.bitop." ~ integerName ~ "(T.init)")))
                case integerName:
                    return &entry!(integerName, int, T);
        default:
            return null;
    }
}


// Every `core.bitop` intrinsic snakebite has a builtin wrapper for.
// `bsf` and `bsr` also classify (`BUILTIN.bsf`/`BUILTIN.bsr`), but both
// have real bodies in `core.bitop`, and `CallSelection` only asks for a
// wrapper of a function with no body: `bswap` and `_popcnt`.
private enum sameTypeIntegerNames = ["bswap"];
private enum ownReturnTypeIntegerNames = ["_popcnt"];


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
