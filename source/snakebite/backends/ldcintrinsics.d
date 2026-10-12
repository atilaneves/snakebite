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
        static foreach (Unsigned; Integers)
            case Unsigned.sizeof: return &atomicLoad!Unsigned;
        default: return null;
    }
}

public BuiltinCall atomicStoreEntryOf(in size_t size) nothrow @nogc {
    switch (size) {
        static foreach (Unsigned; Integers)
            case Unsigned.sizeof: return &atomicStore!Unsigned;
        default: return null;
    }
}

public BuiltinCall atomicCompareExchangeEntryOf(in size_t size) nothrow @nogc {
    switch (size) {
        static foreach (Unsigned; Integers)
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

alias Integers = imported!"std.meta".AliasSeq!(ubyte, ushort, uint, ulong);
enum readModifyWriteOperations = [
    "xchg", "add", "sub", "and", "nand", "or", "xor", "max", "min", "umax", "umin",
];

struct Row {
    string name;
    BuiltinCall call;
}

// The scalar types that an intrinsic template is tried with.
alias Scalars = imported!"std.meta".AliasSeq!(
    float, double, real, ubyte, ushort, uint, ulong,
);

// The parameters that LLVM wants as constants, by intrinsic name: the
// position and the number of values. The wrapper chooses the call with the
// constant that the argument holds.
struct Constants {
    string name;
    size_t[] positions;
    size_t[] domains;
}

enum constants = [
    Constants("llvm.ctlz", [1], [2]),
    Constants("llvm.cttz", [1], [2]),
    Constants("llvm.prefetch", [1, 2, 3], [2, 4, 2]),
    Constants("llvm.memcpy", [3], [2]),
    Constants("llvm.memmove", [3], [2]),
    Constants("llvm.memset", [3], [2]),
];

template constantsOf(string llvmName) {
    enum constantsOf = () {
        foreach (entry; constants)
            if (llvmName.length >= entry.name.length
                    && llvmName[0 .. entry.name.length] == entry.name)
                return entry;
        return Constants.init;
    }();
}

immutable(Row)[] intrinsicRows = () {
    Row[] rows;
    static foreach (memberName; __traits(allMembers, ldc.intrinsics)) {
        static if (memberName.length > 5 && memberName[0 .. 5] == "llvm_") {
            static if (isFrameIntrinsic(memberName)) {
            } else static if (__traits(isTemplate, member!memberName)) {
                static foreach (Scalar; Scalars) {
                    static if (is(typeof(instance!(memberName, Scalar))))
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
    return rows;
}();

// These answer for the frame of the function that calls them; a wrapper
// would answer for its own.
bool isFrameIntrinsic(in string name) {
    // The atomics and the fence are not LLVM intrinsics by name; they have
    // wrappers of their own.
    if (name.length > 12 && name[0 .. 12] == "llvm_atomic_" || name == "llvm_memory_fence")
        return true;
    switch (name) {
        case "llvm_returnaddress", "llvm_frameaddress", "llvm_stackaddress",
                "llvm_stacksave", "llvm_stackrestore":
            return true;
        // The mask is an immediate with 1024 values.
        case "llvm_is_fpclass":
            return true;
        // LDC does not mangle its overloaded name for every type.
        case "llvm_powi", "llvm_thread_pointer", "llvm_pcmarker":
            return true;
        default:
            return false;
    }
}

alias member(string name) = __traits(getMember, ldc.intrinsics, name);

template instance(string name, Scalar) {
    alias M = member!name;
    alias instance = M!Scalar;
}

extern(C) void entry(string key, alias intrinsic)(
    void* returnPlace, scope const(void*)* arguments, size_t argumentCount,
) nothrow @nogc {
    import std.traits: Parameters, ReturnType;

    alias Params = Parameters!intrinsic;
    if (argumentCount != Params.length)
        internalFailure("an LLVM intrinsic wrapper got the wrong number of arguments");
    Params values;
    static foreach (i, P; Params)
        values[i] = *cast(P*) arguments[i];
    enum chosen = constantsOf!(intrinsic.mangleof);
    static if (is(ReturnType!intrinsic == void)) {
        invoke!(intrinsic, chosen.positions, chosen.domains)(values);
    } else
        *cast(ReturnType!intrinsic*) returnPlace =
            invoke!(intrinsic, chosen.positions, chosen.domains)(values);
}

auto invoke(alias intrinsic, size_t[] positions, size_t[] domains, size_t[] chosen = [], Params...)(
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

string digits(size_t value) {
    string result;
    do {
        result = cast(char) ('0' + value % 10) ~ result;
        value /= 10;
    } while (value != 0);
    return result;
}

// The orderings that LLVM accepts for an access, as constants. `Consume`
// has the strength of `Acquire`.
enum loadOrderings = [
    AtomicOrdering.Unordered, AtomicOrdering.Monotonic, AtomicOrdering.Acquire,
    AtomicOrdering.SequentiallyConsistent,
];
enum storeOrderings = [
    AtomicOrdering.Unordered, AtomicOrdering.Monotonic, AtomicOrdering.Release,
    AtomicOrdering.SequentiallyConsistent,
];
enum updateOrderings = [
    AtomicOrdering.Monotonic, AtomicOrdering.Acquire, AtomicOrdering.Release,
    AtomicOrdering.AcquireRelease, AtomicOrdering.SequentiallyConsistent,
];
enum failureOrderings = [
    AtomicOrdering.Monotonic, AtomicOrdering.Acquire,
    AtomicOrdering.SequentiallyConsistent,
];

extern(C) void atomicLoad(Unsigned)(
    void* returnPlace, scope const(void*)* arguments, size_t,
) nothrow @nogc {
    auto pointer = cast(shared(Unsigned)*) *cast(void**) arguments[0];
    switch (*cast(const(int)*) arguments[1]) {
        static foreach (ordering; loadOrderings)
            case ordering:
                *cast(Unsigned*) returnPlace = llvm_atomic_load!Unsigned(pointer, ordering);
                return;
        case AtomicOrdering.Consume:
            *cast(Unsigned*) returnPlace = llvm_atomic_load!Unsigned(pointer, AtomicOrdering.Acquire);
            return;
        default: internalFailure("atomic load ordering");
    }
}

extern(C) void atomicStore(Unsigned)(
    void*, scope const(void*)* arguments, size_t,
) nothrow @nogc {
    const value = *cast(const(Unsigned)*) arguments[0];
    auto pointer = cast(shared(Unsigned)*) *cast(void**) arguments[1];
    switch (*cast(const(int)*) arguments[2]) {
        static foreach (ordering; storeOrderings)
            case ordering:
                llvm_atomic_store!Unsigned(value, pointer, ordering);
                return;
        default: internalFailure("atomic store ordering");
    }
}

extern(C) void atomicCompareExchange(Unsigned)(
    void* returnPlace, scope const(void*)* arguments, size_t,
) nothrow @nogc {
    auto pointer = cast(shared(Unsigned)*) *cast(void**) arguments[0];
    const expected = *cast(const(Unsigned)*) arguments[1];
    const desired = *cast(const(Unsigned)*) arguments[2];
    const success = *cast(const(int)*) arguments[3];
    const failure = *cast(const(int)*) arguments[4];
    const weak = *cast(const(bool)*) arguments[5];
    auto result = cast(CmpXchgResult!Unsigned*) returnPlace;
    static foreach (s; updateOrderings)
        static foreach (f; failureOrderings)
            static foreach (isWeak; [false, true])
                if (success == s && failure == f && weak == isWeak) {
                    *result = llvm_atomic_cmp_xchg!Unsigned(pointer, expected, desired, s, f, isWeak);
                    return;
                }
    internalFailure("atomic compare-exchange ordering");
}

template Signed(Unsigned) {
    static if (is(Unsigned == ubyte))
        alias Signed = byte;
    else static if (is(Unsigned == ushort))
        alias Signed = short;
    else static if (is(Unsigned == uint))
        alias Signed = int;
    else
        alias Signed = long;
}

extern(C) void atomicReadModifyWrite(string operation, Unsigned)(
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

extern(C) void fence(void*, scope const(void*)* arguments, size_t) nothrow @nogc {
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

extern(C) void volatileLoad(Unsigned)(
    void* returnPlace, scope const(void*)* arguments, size_t,
) nothrow @nogc {
    import core.volatile: volatileLoad;

    *cast(Unsigned*) returnPlace = volatileLoad(*cast(Unsigned**) arguments[0]);
}

extern(C) void volatileStore(Unsigned)(
    void*, scope const(void*)* arguments, size_t,
) nothrow @nogc {
    import core.volatile: volatileStore;

    volatileStore(*cast(Unsigned**) arguments[0], *cast(const(Unsigned)*) arguments[1]);
}
