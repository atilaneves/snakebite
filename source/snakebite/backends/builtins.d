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


// The concrete type a call's own first parameter declares - the other
// half of this table's lookup key, since dmd's own `BUILTIN`
// classification (`dmd.builtin.isBuiltin`) does not carry it: `sin
// (float)` and `sin(double)` both classify as `BUILTIN.sin`, and `bswap
// (uint)`/`bswap(ulong)` both classify as `BUILTIN.bswap`.
public enum ParameterType { float_, double_, real_, ushort_, uint_, ulong_ }


// `name` and `type`'s wrapper, or `null` when snakebite has none for a
// builtin dmd itself does classify. `name` is dmd's own `BUILTIN`
// classification (`dmd.builtin.isBuiltin`), as that enum member's bare
// name (`snakebite.backends.calls` converts it with `std.conv.text`
// before calling here) rather than the enum value itself, so this
// module never needs a DMD frontend import path - and neither does the
// bytecode VM, which imports only `BuiltinCall` from here (CODING.md,
// "Code organisation"). `CallSelection.buildDecision`
// (`snakebite.backends.calls`) turns a `null` here into a refusal at
// decision time, never at first execution.
public BuiltinCall entryOf(in string name, in ParameterType type) {
    final switch (type) with (ParameterType) {
        case float_: return widthEntryOf!float(name);
        case double_: return widthEntryOf!double(name);
        case real_: return widthEntryOf!real(name);
        case ushort_: return integerEntryOf!ushort(name);
        case uint_: return integerEntryOf!uint(name);
        case ulong_: return integerEntryOf!ulong(name);
    }
}


private BuiltinCall widthEntryOf(T)(in string name) {
    switch (name) {
        static foreach (oneArgumentName; oneArgumentNames)
            case oneArgumentName:
                return &entry!(oneArgumentName, T);
        static foreach (twoArgumentName; sameTypeTwoArgumentNames)
            case twoArgumentName:
                return &entry!(twoArgumentName, T, T);
        case "ldexp":
            // `ldexp`'s second argument is always `int`, never the
            // call's own floating point type - the one intrinsic here
            // whose arguments do not all share one type.
            return &entry!("ldexp", T, int);
        default:
            return null;
    }
}


// Every `core.math` intrinsic snakebite has a builtin wrapper for, split
// by how many arguments it takes and, for the two-argument ones, whether
// the second argument shares the call's own floating point type.
// `rint` and `rndtol` are real `core.math` intrinsics too, but dmd's own
// `BUILTIN` enum (`dmd.func`) has no member for either one - dmd's
// `isBuiltin` always answers `BUILTIN.unimp` for them, the same answer a
// function that is not a compiler intrinsic at all gets, and so does
// dmd's own CTFE engine (`dmd.dinterpret.evaluateIfBuiltin` gates on the
// identical check). A call to either of them never reaches this table:
// `CallSelection` keeps routing it through FFI, same as before this
// module existed.
private enum oneArgumentNames = ["fabs", "sqrt", "sin", "cos"];
private enum sameTypeTwoArgumentNames = ["yl2x", "yl2xp1"];


private BuiltinCall integerEntryOf(T)(in string name) {
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
                    return &entry!(integerName, T);
        static foreach (integerName; ownReturnTypeIntegerNames)
            static if (__traits(compiles,
                mixin("core.bitop." ~ integerName ~ "(T.init)")))
                case integerName:
                    return &entry!(integerName, T);
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
// `core.math`/`core.bitop` intrinsic with those values, and write the
// result at whatever type the call itself returns - `Result` comes from
// `typeof(call(values))`, not from `Params`, so this one template covers
// a same-type result (`fabs`, `bswap`), a mixed-type argument list
// (`ldexp`'s trailing `int`) and a result narrower than the argument
// (`_popcnt(uint)` returns `int`) without a separate template per shape.
// `core.math` and `core.bitop` declare no name in common, so importing
// both here and looking `name` up unqualified never collides.
private extern(C) void entry(string name, Params...)(
    void* returnPlace, scope const(void*)* arguments, size_t argumentCount,
) @trusted nothrow @nogc {
    import core.math;
    import core.bitop;

    assert(argumentCount == Params.length, name ~ " arity");
    Params values;
    static foreach (i, P; Params)
        values[i] = *cast(const(P)*) arguments[i];
    alias call = mixin(name);
    alias Result = typeof(call(values));
    *cast(Result*) returnPlace = call(values);
}
