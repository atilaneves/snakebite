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
    void* returnPlace, scope const(void*)* arguments, size_t argumentCount);


// Which of `core.math`'s `float`/`double`/`real` overloads a call
// resolved to - the other half of this table's lookup key, since dmd's
// own `BUILTIN` classification (`dmd.builtin.isBuiltin`) does not carry
// it: `sin(float)` and `sin(double)` both classify as `BUILTIN.sin`.
public enum FloatWidth { float_, double_, real_ }


// `kind` and `width`'s wrapper, or `null` when snakebite has none for a
// builtin dmd itself does classify. `CallSelection.buildDecision`
// (`snakebite.backends.calls`) turns a `null` here into a refusal at
// decision time, never at first execution.
public BuiltinCall entryOf(
    in imported!"dmd.func".BUILTIN kind, in FloatWidth width,
) {
    final switch (width) with (FloatWidth) {
        case float_: return widthEntryOf!float(kind);
        case double_: return widthEntryOf!double(kind);
        case real_: return widthEntryOf!real(kind);
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


private BuiltinCall widthEntryOf(T)(in imported!"dmd.func".BUILTIN kind) {
    import dmd.func: BUILTIN;

    switch (kind) with (BUILTIN) {
        static foreach (name; oneArgumentNames)
            case __traits(getMember, BUILTIN, name):
                return &oneArgument!(name, T);
        static foreach (name; sameTypeTwoArgumentNames)
            case __traits(getMember, BUILTIN, name):
                return &sameTypeTwoArguments!(name, T);
        case ldexp:
            return &ldexpEntry!T;
        default:
            return null;
    }
}


// `core.math`'s own one-argument intrinsics (`fabs`, `sqrt`, `sin`,
// `cos`): one entry per `(name, T)` pair, generated instead of
// hand-written so the four names above are the only place a new
// one-argument intrinsic needs adding.
private extern(C) void oneArgument(string name, T)(
    void* returnPlace, scope const(void*)* arguments, size_t argumentCount,
) @trusted nothrow @nogc {
    import core.math;

    assert(argumentCount == 1, name ~ " takes one argument");
    const value = *cast(const(T)*) arguments[0];
    *cast(T*) returnPlace = __traits(getMember, core.math, name)(value);
}


// `core.math`'s two-argument intrinsics whose second argument shares the
// first's type (`yl2x`, `yl2xp1`): `yl2x(x, y)` computes `y * log2(x)`,
// `yl2xp1(x, y)` computes `y * log2(x + 1)` - both real `core.math`
// intrinsics on every type this table serves (verified against both dmd
// and ldc for `float`, `double` and `real`), so neither needs the
// `std.math` fallback a host lacking them would.
private extern(C) void sameTypeTwoArguments(string name, T)(
    void* returnPlace, scope const(void*)* arguments, size_t argumentCount,
) @trusted nothrow @nogc {
    import core.math;

    assert(argumentCount == 2, name ~ " takes two arguments");
    const x = *cast(const(T)*) arguments[0];
    const y = *cast(const(T)*) arguments[1];
    *cast(T*) returnPlace = __traits(getMember, core.math, name)(x, y);
}


// `ldexp`'s second argument is always `int`, never the call's own
// floating point type - the one intrinsic here whose arguments do not
// all share one type, so it keeps its own entry instead of fitting
// `sameTypeTwoArguments`.
private extern(C) void ldexpEntry(T)(
    void* returnPlace, scope const(void*)* arguments, size_t argumentCount,
) @trusted nothrow @nogc {
    import core.math: ldexp;

    assert(argumentCount == 2, "ldexp takes two arguments");
    const value = *cast(const(T)*) arguments[0];
    const exponent = *cast(const(int)*) arguments[1];
    *cast(T*) returnPlace = ldexp(value, exponent);
}
