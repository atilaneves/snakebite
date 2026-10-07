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


// The concrete type a call's own first parameter declares - the other
// half of this table's lookup key, since dmd's own `BUILTIN`
// classification (`dmd.builtin.isBuiltin`) does not carry it: `sin
// (float)` and `sin(double)` both classify as `BUILTIN.sin`, and `bswap
// (uint)`/`bswap(ulong)` both classify as `BUILTIN.bswap`.
public enum ParameterType {
    float_, double_, real_, ushort_, uint_, ulong_,
    ubytePointer_, ushortPointer_, uintPointer_, ulongPointer_, voidPointer_,
    other_,
}


// `name` is a string key, not dmd's `BUILTIN` enum value, so this
// module and the bytecode VM that calls into it need no DMD frontend
// import path (CODING.md, "Code organisation"). `null` means the pair
// is not a bodiless declaration dmd classifies as a builtin.
public BuiltinCall entryOf(in string name, in ParameterType type)
@safe pure nothrow @nogc {
    final switch (type) with (ParameterType) {
        case float_: return widthEntryOf!float(name);
        case double_: return widthEntryOf!double(name);
        case real_: return widthEntryOf!real(name);
        case ushort_: return integerEntryOf!ushort(name);
        case uint_: return integerEntryOf!uint(name);
        case ulong_: return integerEntryOf!ulong(name);
        case ubytePointer_: return volatileEntryOf!ubyte(name);
        case ushortPointer_: return volatileEntryOf!ushort(name);
        case uintPointer_: return volatileEntryOf!uint(name);
        case ulongPointer_: return volatileEntryOf!ulong(name);
        case voidPointer_: return name == "__prefetch" ? &prefetchEntry : null;
        case other_: return null;
    }
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
// computes from its template arguments. Hosts without `D_SIMD` compile no
// prefetch, and a prefetch changes no value a program can read.
private extern(C) void prefetchEntry(
    void*, scope const(void*)* arguments, size_t argumentCount,
) @trusted nothrow @nogc {
    assert(argumentCount == 2, "__prefetch arity");
    version (D_SIMD) {
        import core.simd: prefetch;

        const address = *cast(const(void*)*) arguments[0];
        switch (*cast(const(ubyte)*) arguments[1]) {
            case 0: prefetch!(false, 3)(address); break;
            case 1: prefetch!(false, 2)(address); break;
            case 2: prefetch!(false, 1)(address); break;
            case 3: prefetch!(false, 0)(address); break;
            default: prefetch!(true, 0)(address); break;
        }
    }
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
// have real bodies in `core.bitop` (`pragma(inline, false)` wrapping a
// soft fallback, kept so intrinsic detection still works on the type
// this table never sees them through) - `CallSelection.buildDecision`
// only ever asks `builtinDecision` about a function whose `fbody is
// null`, so a name here is only ever one dmd itself declared bodiless:
// `bswap` and `_popcnt`.
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
