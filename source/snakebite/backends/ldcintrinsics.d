/// The wrappers of LDC's intrinsics. A guest that LDC's druntime source
/// declares with `pragma(LDC_intrinsic)`, `LDC_atomic_*` or `LDC_fence` has
/// no host symbol to call, so each call goes to a wrapper that LDC compiles
/// into the host: the result is the one that native code built by LDC gives.
module snakebite.backends.ldcintrinsics;

private:

version (LDC):

import snakebite.backends.builtins: BuiltinCall;
import snakebite.internalfailure: internalFailure;
import ldc.intrinsics;
import core.int128: Cent;

// The wrapper for the LLVM intrinsic `llvmName` (`llvm.sin.f64`), or `null`
// when none takes it. The name pins the signature, so a guest's own
// declaration with the same name is served too.
public BuiltinCall intrinsicEntryOf(in const(char)[] llvmName) nothrow @nogc {
    foreach (row; intrinsicRows)
        if (row.name == llvmName)
            return row.call;
    return null;
}

// `size` is the size of the template argument, `operation` the string of
// `pragma(LDC_atomic_rmw)`.
public BuiltinCall atomicLoadEntryOf(in size_t size) nothrow @nogc {
    switch (size) {
        static foreach (Unsigned; AtomicTypes)
            case Unsigned.sizeof: return &atomicLoad!Unsigned;
        default: return null;
    }
}

public BuiltinCall atomicStoreEntryOf(in size_t size) nothrow @nogc {
    switch (size) {
        static foreach (Unsigned; AtomicTypes)
            case Unsigned.sizeof: return &atomicStore!Unsigned;
        default: return null;
    }
}

public BuiltinCall atomicCompareExchangeEntryOf(in size_t size) nothrow @nogc {
    switch (size) {
        static foreach (Unsigned; AtomicTypes)
            case Unsigned.sizeof: return &atomicCompareExchange!Unsigned;
        default: return null;
    }
}

public BuiltinCall atomicReadModifyWriteEntryOf(
    in const(char)[] operation, in size_t size,
) nothrow @nogc {
    switch (operation) {
        static foreach (name; readModifyWriteOperations)
            case name:
                switch (size) {
                    static foreach (Unsigned; Integers)
                        case Unsigned.sizeof:
                            return &atomicReadModifyWrite!(name, Unsigned);
                    default: return null;
                }
        default: return null;
    }
}

public BuiltinCall fenceEntry() nothrow @nogc {
    return &fence;
}

// `core.bitop` reaches the host's volatile access through `ldc.bitop.vld`
// and `vst`: the width of the access is the width of the value.
public BuiltinCall volatileLoadEntryOf(in size_t size) nothrow @nogc {
    switch (size) {
        static foreach (Unsigned; Integers)
            case Unsigned.sizeof: return &volatileLoad!Unsigned;
        default: return null;
    }
}

public BuiltinCall volatileStoreEntryOf(in size_t size) nothrow @nogc {
    switch (size) {
        static foreach (Unsigned; Integers)
            case Unsigned.sizeof: return &volatileStore!Unsigned;
        default: return null;
    }
}

private alias Integers = imported!"std.meta".AliasSeq!(ubyte, ushort, uint, ulong);
// `core.atomic` takes a `Cent` for any type of 16 bytes. The read-modify-write
// operations stop at the size of a pointer (`AtomicRmwSizeLimit`).
private alias AtomicTypes = imported!"std.meta".AliasSeq!(ubyte, ushort, uint, ulong, Cent);
private enum readModifyWriteOperations = [
    "xchg", "add", "sub", "and", "nand", "or", "xor", "max", "min", "umax", "umin",
];

private struct Row {
    string name;
    BuiltinCall call;
}

// The scalar types that an intrinsic template is tried with, `bool` among
// them (LLVM's `i1`). A template that a type does not satisfy has no
// instance.
private alias Scalars = imported!"std.meta".AliasSeq!(
    float, double, real, bool, ubyte, ushort, uint, ulong,
);

// The length of a copy is not an `i1`. LLVM 22 has no x86 instruction
// selection for `minimum` and `maximum` on `real` (`f80`): LDC stops the
// compilation of any call, so no wrapper for them can exist.
private template takesType(string name, T) {
    enum takesType = !(is(T == bool)
        && (name == "llvm_memcpy" || name == "llvm_memmove" || name == "llvm_memset"))
        && !(is(T == real) && (name == "llvm_minimum" || name == "llvm_maximum"));
}

// The parameters that LLVM wants as constants, by intrinsic name: the
// position and the number of values. The wrapper chooses the call with the
// constant that the argument holds.
private struct Constants {
    string name;
    size_t[] positions;
    size_t[] domains;
}

private enum constants = [
    Constants("llvm.ctlz", [1], [2]),
    Constants("llvm.cttz", [1], [2]),
    Constants("llvm.prefetch", [1, 2, 3], [2, 4, 2]),
    Constants("llvm.memcpy", [3], [2]),
    Constants("llvm.memmove", [3], [2]),
    Constants("llvm.memset", [3], [2]),
];

private template constantsOf(string llvmName) {
    enum constantsOf = () {
        foreach (entry; constants)
            if (llvmName.length >= entry.name.length
                    && llvmName[0 .. entry.name.length] == entry.name)
                return entry;
        return Constants.init;
    }();
}

private immutable(Row)[] intrinsicRows = () {
    Row[] rows;
    static foreach (memberName; __traits(allMembers, ldc.intrinsics)) {
        static if (memberName.length > 5 && memberName[0 .. 5] == "llvm_") {
            static if (hasNoWrapper(memberName)) {
            } else static if (__traits(isTemplate, member!memberName)) {
                static foreach (Scalar; Scalars) {
                    static if (takesType!(memberName, Scalar) && is(typeof(instance!(memberName, Scalar))))
                        rows ~= Row(
                            instance!(memberName, Scalar).mangleof,
                            &entry!(instance!(memberName, Scalar).mangleof, instance!(memberName, Scalar)),
                        );
                }
            } else static if (is(typeof(member!memberName))) {
                rows ~= Row(member!memberName.mangleof, &entry!(member!memberName.mangleof, member!memberName));
            }
        }
    }
    static foreach (Float; imported!"std.meta".AliasSeq!(float, double, real))
        rows ~= Row(llvm_is_fpclass!Float.mangleof, &isFpclass!Float);
    return rows;
}();

// The intrinsics with no wrapper, by the name of the D declaration. Calling
// one reports its name (`snakebite.ffi.plan`).
//
// The frame intrinsics answer for the frame of the function that calls them;
// a wrapper would answer for its own. The atomics and the fence are not LLVM
// intrinsics by name; they have wrappers of their own. `llvm_powi` and
// `llvm_thread_pointer` do not compile with LDC 1.43 and LLVM 22 at all
// (LDC leaves the overloaded name unmangled, and LLVM's verifier ends the
// compilation), and `llvm_pcmarker` has no instruction selection on x86.
// `llvm_is_fpclass` has a wrapper of its own below.
private bool hasNoWrapper(in string name) {
    if (name.length > 12 && name[0 .. 12] == "llvm_atomic_" || name == "llvm_memory_fence")
        return true;
    switch (name) {
        case "llvm_returnaddress", "llvm_frameaddress", "llvm_stackaddress",
                "llvm_stacksave", "llvm_stackrestore",
                "llvm_is_fpclass",
                "llvm_powi", "llvm_thread_pointer", "llvm_pcmarker":
            return true;
        default:
            return false;
    }
}

// The mask of `llvm.is.fpclass` is an immediate of ten bits, one for each
// class, and the result is true when the value is in any class that the mask
// names: one call for each bit gives the same answer.
private extern(C) void isFpclass(Float)(
    void* returnPlace, scope const(void*)* arguments, size_t,
) nothrow @nogc {
    import core.stdc.string: memcpy;

    Float value;
    memcpy(&value, arguments[0], Float.sizeof);
    const mask = *cast(const(uint)*) arguments[1];
    bool result;
    static foreach (bit; 0 .. 10)
        if (mask & (1u << bit))
            result = result || llvm_is_fpclass!Float(value, 1u << bit);
    *cast(bool*) returnPlace = result;
}

private alias member(string name) = __traits(getMember, ldc.intrinsics, name);

private template instance(string name, Scalar) {
    alias M = member!name;
    alias instance = M!Scalar;
}

private extern(C) void entry(string key, alias intrinsic)(
    void* returnPlace, scope const(void*)* arguments, size_t argumentCount,
) nothrow @nogc {
    import core.stdc.string: memcpy;
    import std.traits: Parameters, ReturnType;

    alias Params = Parameters!intrinsic;
    if (argumentCount != Params.length)
        internalFailure("an LLVM intrinsic wrapper got the wrong number of arguments");
    // A vector or a 16-byte value in a frame slot is not always aligned as
    // its type is.
    Params values;
    static foreach (i, P; Params)
        memcpy(&values[i], arguments[i], P.sizeof);
    enum chosen = constantsOf!(intrinsic.mangleof);
    static if (is(ReturnType!intrinsic == void)) {
        invoke!(intrinsic, chosen.positions, chosen.domains)(values);
    } else {
        auto result = invoke!(intrinsic, chosen.positions, chosen.domains)(values);
        memcpy(returnPlace, &result, result.sizeof);
    }
}

private auto invoke(alias intrinsic, size_t[] positions, size_t[] domains, size_t[] chosen = [], Params...)(
    ref Params values,
) {
    static if (chosen.length == positions.length) {
        enum text = () {
            string result = "intrinsic(";
            foreach (i; 0 .. Params.length) {
                if (i)
                    result ~= ", ";
                size_t found = size_t.max;
                foreach (k, p; positions)
                    if (p == i)
                        found = k;
                result ~= found == size_t.max
                    ? "values[" ~ digits(i) ~ "]"
                    : "cast(Params[" ~ digits(i) ~ "])" ~ digits(chosen[found]);
            }
            return result ~ ")";
        }();
        return mixin(text);
    } else {
        switch (cast(size_t) values[positions[chosen.length]]) {
            static foreach (v; 0 .. domains[chosen.length])
                case v:
                    return invoke!(intrinsic, positions, domains, chosen ~ v)(values);
            default:
                internalFailure("an LLVM constant out of its range");
        }
    }
}

private string digits(size_t value) {
    string result;
    do {
        result = cast(char) ('0' + value % 10) ~ result;
        value /= 10;
    } while (value != 0);
    return result;
}

// The orderings that LLVM accepts for an access, as constants. `Consume`
// has the strength of `Acquire`.
private enum loadOrderings = [
    AtomicOrdering.Unordered, AtomicOrdering.Monotonic, AtomicOrdering.Acquire,
    AtomicOrdering.SequentiallyConsistent,
];
private enum storeOrderings = [
    AtomicOrdering.Unordered, AtomicOrdering.Monotonic, AtomicOrdering.Release,
    AtomicOrdering.SequentiallyConsistent,
];
private enum updateOrderings = [
    AtomicOrdering.Monotonic, AtomicOrdering.Acquire, AtomicOrdering.Release,
    AtomicOrdering.AcquireRelease, AtomicOrdering.SequentiallyConsistent,
];
private enum failureOrderings = [
    AtomicOrdering.Monotonic, AtomicOrdering.Acquire,
    AtomicOrdering.SequentiallyConsistent,
];

// A value in a frame slot is not always aligned as its type is.
private T fetch(T)(const(void)* place) nothrow @nogc {
    import core.stdc.string: memcpy;

    T value;
    memcpy(&value, place, T.sizeof);
    return value;
}

private void store(T)(void* place, in T value) nothrow @nogc {
    import core.stdc.string: memcpy;

    memcpy(place, &value, T.sizeof);
}

private extern(C) void atomicLoad(Unsigned)(
    void* returnPlace, scope const(void*)* arguments, size_t,
) nothrow @nogc {
    auto pointer = cast(shared(Unsigned)*) *cast(void**) arguments[0];
    switch (*cast(const(int)*) arguments[1]) {
        static foreach (ordering; loadOrderings)
            case ordering:
                store(returnPlace, llvm_atomic_load!Unsigned(pointer, ordering));
                return;
        case AtomicOrdering.Consume:
            store(returnPlace, llvm_atomic_load!Unsigned(pointer, AtomicOrdering.Acquire));
            return;
        default: internalFailure("atomic load ordering");
    }
}

private extern(C) void atomicStore(Unsigned)(
    void*, scope const(void*)* arguments, size_t,
) nothrow @nogc {
    const value = fetch!Unsigned(arguments[0]);
    auto pointer = cast(shared(Unsigned)*) *cast(void**) arguments[1];
    switch (*cast(const(int)*) arguments[2]) {
        static foreach (ordering; storeOrderings)
            case ordering:
                llvm_atomic_store!Unsigned(value, pointer, ordering);
                return;
        default: internalFailure("atomic store ordering");
    }
}

private extern(C) void atomicCompareExchange(Unsigned)(
    void* returnPlace, scope const(void*)* arguments, size_t,
) nothrow @nogc {
    auto pointer = cast(shared(Unsigned)*) *cast(void**) arguments[0];
    const expected = fetch!Unsigned(arguments[1]);
    const desired = fetch!Unsigned(arguments[2]);
    const success = *cast(const(int)*) arguments[3];
    const failure = *cast(const(int)*) arguments[4];
    const weak = *cast(const(bool)*) arguments[5];
    static foreach (s; updateOrderings)
        static foreach (f; failureOrderings)
            static foreach (isWeak; [false, true])
                if (success == s && failure == f && weak == isWeak) {
                    store(returnPlace, llvm_atomic_cmp_xchg!Unsigned(pointer, expected, desired, s, f, isWeak));
                    return;
                }
    internalFailure("atomic compare-exchange ordering");
}

private template Signed(Unsigned) {
    static if (is(Unsigned == ubyte))
        alias Signed = byte;
    else static if (is(Unsigned == ushort))
        alias Signed = short;
    else static if (is(Unsigned == uint))
        alias Signed = int;
    else
        alias Signed = long;
}

private extern(C) void atomicReadModifyWrite(string operation, Unsigned)(
    void* returnPlace, scope const(void*)* arguments, size_t,
) nothrow @nogc {
    static if (operation == "max" || operation == "min")
        alias Value = Signed!Unsigned;
    else
        alias Value = Unsigned;
    auto pointer = cast(shared(Value)*) *cast(void**) arguments[0];
    const value = *cast(const(Value)*) arguments[1];
    const ordering = *cast(const(int)*) arguments[2];
    alias operate = imported!"std.meta".Alias!(mixin("llvm_atomic_rmw_" ~ operation));
    static foreach (o; updateOrderings)
        if (ordering == o) {
            *cast(Value*) returnPlace = operate!Value(pointer, value, o);
            return;
        }
    internalFailure("atomic read-modify-write ordering");
}

private extern(C) void fence(void*, scope const(void*)* arguments, size_t) nothrow @nogc {
    const ordering = *cast(const(int)*) arguments[0];
    const scope_ = *cast(const(int)*) arguments[1];
    static foreach (o; updateOrderings)
        static foreach (s; [SynchronizationScope.SingleThread, SynchronizationScope.CrossThread])
            if (ordering == o && scope_ == s) {
                llvm_memory_fence(o, s);
                return;
            }
    internalFailure("fence ordering");
}

private extern(C) void volatileLoad(Unsigned)(
    void* returnPlace, scope const(void*)* arguments, size_t,
) nothrow @nogc {
    import core.volatile: volatileLoad;

    *cast(Unsigned*) returnPlace = volatileLoad(*cast(Unsigned**) arguments[0]);
}

private extern(C) void volatileStore(Unsigned)(
    void*, scope const(void*)* arguments, size_t,
) nothrow @nogc {
    import core.volatile: volatileStore;

    volatileStore(*cast(Unsigned**) arguments[0], *cast(const(Unsigned)*) arguments[1]);
}
