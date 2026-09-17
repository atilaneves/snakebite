module snakebite.ffi.abi;


private:

// This module classifies one value's System V AMD64 ABI shape -
// `ArgumentPlan` and `Register` - and the two host-compiler switches
// below (`reversedDParameters`, `contextPrecedesHiddenReturnPointer`) a
// plan reads to interpret that shape. It no longer dispatches a call
// itself: that moved to the assembly stub in `snakebite.ffi.sysv`,
// replayed by `snakebite.ffi.plan` (ADR-0001, issue #334).
//
// The integer register limit is separate: values after the first six
// integer words go on the stack, but they still belong to the function's
// parameter list.
public enum maxIntegerArguments = 6;
public enum maxFloatingArguments = 8;

// Whether this can call anything at all: these rules are for the SysV
// AMD64 ABI, and no other host ABI is implemented.
public enum supported = () {
    version (Posix) {
        version (X86_64)
            return true;
        else
            return false;
    } else
        return false;
}();

// Whether native `extern(D)` code in this process assigns parameters to
// registers in reverse declaration order. dmd's `extern(D)` variant of the
// System V convention does; ldc and gdc keep the C order.
public enum reversedDParameters = () {
    version (DigitalMars)
        return true;
    else
        return false;
}();

// Whether a method that returns a large aggregate receives its context
// before its hidden return pointer. dmd puts `this` first for `extern(D)`;
// ldc follows the System V order and puts the hidden return pointer first,
// for every linkage. On dmd, a non-`extern(D)` method - `extern(C++)`
// chief among them - follows the System V/Itanium order instead: the
// glue layer (`e2ir.d`'s `callfunc`) only folds the hidden return pointer
// in ahead of `this` when `tf.linkage == LINK.d`; for every other linkage
// on a POSIX target it is appended after `this` instead, which its own
// parameter-list nesting makes the *first* argument register, ahead of
// `this` (verified against dmd's own `callfunc`, the comment "ehidden
// goes last on Linux/OSX C++" marking exactly this branch).
public bool contextPrecedesHiddenReturnPointer(
    in imported!"dmd.astenums".LINK linkage,
) {
    import dmd.astenums: LINK;

    version (DigitalMars)
        return linkage == LINK.d || linkage == LINK.default_;
    else
        return false;
}

// Whether an `extern(D)` untyped variadic call site's hidden `_arguments`
// argument (issue #334 step 6) travels as a two-register `TypeInfo[]`
// slice instead of dmd's own single pointer to the `TypeInfo_Tuple` the
// frontend's leading `typeid` expression evaluates to. Both host
// compilers' frontends insert that same `typeid` expression - this is a
// codegen difference, not a frontend one: dmd's codegen forwards the
// `TypeInfo_Tuple` reference itself, and the callee's own prologue reads
// its `elements` field to build the slice; ldc's codegen reads `elements`
// at the *call site* instead, and passes the resulting slice directly
// (verified: disassembling a real `extern(D) int f(int a, int b, int c,
// ...)` call built by ldc2 1.43, frontend 2.113.0 - the same frontend
// version this project vendors - shows `%edi`/`%esi`=length/pointer, not
// one pointer register; an ldc2-built callee's own prologue starts
// `gp_offset` at 0x18, three GP registers for `_arguments`+`a`, matching
// only the slice shape).
public enum dVariadicArgumentsIsSlice = () {
    version (LDC)
        return true;
    else
        return false;
}();

// What one value's bytes have to become to travel in one argument or
// return register. `integer` is used for an aggregate eightbyte; the
// scalar kinds retain their widening rules.
public struct Register {
    public enum Kind {
        signed,
        unsigned,
        pointer,
        integer,
        sse,
        none, // nothing travels: a `void` return
    }

    public Kind kind;
    // In bytes, 1..8 for anything but `none` - not just 1, 2, 4 or 8: a
    // partial register-class eightbyte (a struct field straddling one)
    // can be any width in between, and so can a MEMORY-class argument's
    // last eightbyte (issue #334 step 3).
    public ubyte size;
}

// How a value travels. A regular value has at most two eightbytes after
// the SysV cleanup rule. A MEMORY value - larger than two eightbytes, or
// with an unaligned field - travels as `memoryWords` whole eightbytes on
// the stack, in declaration position, a plain "copy bytes" load each
// (issue #334 step 3): `registers`/`count` above are meaningless for it.
// A hidden-pointer return (`needsHiddenReturnPointer`) still bypasses this
// entirely and never builds a MEMORY `ArgumentPlan` for the return value.
public struct ArgumentPlan {
    private import dmd.mtype: Type;

    private enum ValueClass {
        none,
        integer,
        sse,
        memory,
    }

    public Register[2] registers;
    public ubyte count;
    public bool memory;
    // MEMORY-class only: this value's own byte size, never truncated -
    // `memoryWords` below is how many whole eightbytes that rounds up to,
    // the count `snakebite.ffi.plan.CallPlan.buildMoves` places on the
    // stack. Stays `0` unless `memory` is `true`.
    public size_t memoryBytes;
    // MEMORY-class only: the value's ABI alignment in bytes. The stack
    // planner uses this to insert padding before an aligned value.
    public size_t memoryAlignment;
    public bool indirect;

    public size_t memoryWords() const @safe @nogc nothrow pure scope {
        return (memoryBytes + 7) / 8;
    }

    // The largest MEMORY-class argument this plans for, in bytes: 64
    // whole eightbytes. A large by-value aggregate does happen in
    // practice - for example `std.regex`'s `Regex!char`, a struct of a
    // dozen slices that `std.regex.matchFirst` takes by value, well over
    // the old 128-byte limit this replaces (issue #334 step 3) - so this
    // is a generous, independent sanity bound, not a derived one:
    // `snakebite.ffi.plan.CallPlan`'s own stack capacity is no longer
    // fixed (it grows on demand past its 16-word fast path - see
    // `CallPlan.callAt`'s own heap fallback), so there is no plan-side
    // number for this to track, and refusing here still gives a clearer
    // message than an unbounded allocation would.
    private enum size_t maxMemoryBytes = 64 * size_t.sizeof;

    // `aggregatePlan` itself already gives a non-trivially-copyable type
    // (`isNonTriviallyCopyable`'s own doc) the indirect, one-pointer shape
    // this used to build only for LDC: the same Itanium rule holds for
    // any host compiler, since it is a fact about the calling convention,
    // not about which compiler built the caller. `of` alone now answers
    // a parameter's own question and a return's alike (issue #336
    // review, finding 12: a parameter-only `ofParameter` wrapper stayed
    // behind after that unification with nothing left to add).
    public static ArgumentPlan of(Type type) {
        auto plan = aggregatePlan(type);
        if (plan.memory)
            validateMemoryParameter(type, plan);
        return plan;
    }
}

// The two ways a MEMORY-class parameter can be unsupported for now - see
// `ArgumentPlan.maxMemoryBytes` and the stack alignment limit below. Only
// called for an explicit parameter (`ArgumentPlan.of`); a MEMORY-class
// *return* still travels through a hidden pointer regardless of these
// limits (see `needsHiddenReturnPointer`), so this never runs for one.
private void validateMemoryParameter(
    imported!"dmd.mtype".Type type, in ArgumentPlan plan,
) {
    import dmd.typesem: alignsize;
    import std.conv: text;

    // The assembly stub aligns the stack argument area to 16 bytes. It
    // cannot satisfy a greater alignment without a dynamic stack base.
    if (type.alignsize > 16)
        throw new Exception(
            text("ffi cannot pass a value of type `", type.toString,
                "`: its ABI alignment is ", type.alignsize, " bytes, and " ~
                "only 16-byte-aligned MEMORY-class arguments are " ~
                "supported"),
        );

    if (plan.memoryBytes > ArgumentPlan.maxMemoryBytes)
        throw new Exception(
            text("ffi cannot pass a value of type `", type.toString,
                "`: its ", plan.memoryBytes, " bytes exceed the ",
                ArgumentPlan.maxMemoryBytes,
                "-byte limit for a MEMORY-class argument"),
        );
}

// The SysV ABI classifies a MEMORY result as a hidden return pointer, and
// so does a non-trivially-copyable result (`isNonTriviallyCopyable`'s own
// doc) - the same NRVO a hidden-pointer return already gives any large
// aggregate, just triggered by non-POD-ness rather than size. This also
// catches an unaligned POD aggregate, which the ABI classifies as MEMORY
// even when its size is at most two eightbytes. Either path always takes
// this route, whatever its size or alignment - unlike a MEMORY-class
// explicit parameter, it never becomes an `ArgumentPlan` `buildMoves`
// places on the stack, so neither of `ArgumentPlan.of`'s own limits
// applies to it.
public bool needsHiddenReturnPointer(imported!"dmd.mtype".Type type) {
    const plan = aggregatePlan(type);
    return plan.memory || plan.indirect;
}

// Whether `type` is a non-trivially-copyable struct, possibly through a
// static array - one where `dmd.dsymbolsem.isPOD` answers `false` for the
// element type: a user-declared copy constructor, a destructor, or a
// postblit, on the type itself or on any field, recursively. The Itanium
// ABI (and dmd's own `target.isReturnOnStack`/`argtypes_sysv_x64.
// toArgTypes_sysv_x64`, which this mirrors) passes such a value by
// indirect (hidden) reference instead of classifying it by field layout
// at all, whatever its own size: one pointer-sized register or stack
// word, exactly the shape a `ref` parameter already has, carrying the
// address of a temporary the frontend's own semantic pass already builds
// - the same copy-constructor call it inserts for passing such a struct
// to *any* function, `extern(D)` included, which is why this is not
// gated to one host compiler the way `ArgumentPlan.ofParameter` used to
// gate it to LDC alone.
private bool isNonTriviallyCopyable(imported!"dmd.mtype".Type type) {
    import dmd.dsymbolsem: isPOD;
    import dmd.typesem: baseElemOf;

    auto aggregate = type.baseElemOf.isTypeStruct;
    return aggregate !is null && !aggregate.sym.isPOD();
}

private ArgumentPlan aggregatePlan(imported!"dmd.mtype".Type type) {
    import dmd.astenums:
        Taarray, Tclass, Tfloat32, Tfloat64, Tpointer, Tvoid;
    import dmd.typesem: alignsize, isIntegral, isUnsigned, size;
    import std.algorithm: min;

    ArgumentPlan plan;
    if (type.ty == Tvoid)
        return plan;

    if (isNonTriviallyCopyable(type)) {
        plan.registers[0] = Register(Register.Kind.pointer, 8);
        plan.count = 1;
        plan.indirect = true;
        return plan;
    }

    if (type.ty == Tpointer || type.ty == Tclass || type.ty == Taarray) {
        plan.registers[0] = Register(Register.Kind.pointer, 8);
        plan.count = 1;
        return plan;
    }

    if (type.ty == Tfloat32 || type.ty == Tfloat64) {
        plan.registers[0] = Register(
            Register.Kind.sse,
            cast(ubyte) type.size,
        );
        plan.count = 1;
        return plan;
    }

    if (type.isIntegral) {
        import snakebite.nativelayout: isIntegralSize;

        const bytes = type.size;
        if (bytes.isIntegralSize) {
            plan.registers[0] = Register(
                type.isUnsigned
                    ? Register.Kind.unsigned
                    : Register.Kind.signed,
                cast(ubyte) bytes,
            );
            plan.count = 1;
            return plan;
        }
    }

    const bytes = type.size;
    if (bytes == 0)
        return plan;
    const count = (bytes + 7) / 8;
    if (count > 2) {
        plan.memory = true;
        plan.memoryBytes = bytes;
        plan.memoryAlignment = type.alignsize;
        return plan;
    }

    ArgumentPlan.ValueClass[2] classes = [
        ArgumentPlan.ValueClass.none, ArgumentPlan.ValueClass.none,
    ];
    bool memory;
    classify(type, 0, classes, memory);
    if (memory) {
        plan.memory = true;
        plan.memoryBytes = bytes;
        plan.memoryAlignment = type.alignsize;
        return plan;
    }

    foreach (i; 0 .. count) {
        final switch (classes[i]) with (ArgumentPlan.ValueClass) {
            case none:
                break;
            case integer:
                plan.registers[i] = Register(
                    Register.Kind.integer,
                    cast(ubyte) min(8, bytes - i * 8),
                );
                ++plan.count;
                break;
            case sse:
                plan.registers[i] = Register(
                    Register.Kind.sse,
                    cast(ubyte) min(8, bytes - i * 8),
                );
                ++plan.count;
                break;
            case memory:
                assert(false);
        }
    }
    return plan;
}

private void classify(
    imported!"dmd.mtype".Type type,
    in size_t offset,
    ref ArgumentPlan.ValueClass[2] classes,
    ref bool memory,
) {
    import dmd.astenums:
        Tarray, Tclass, Tcomplex32, Tcomplex64, Tdelegate, Tfloat32,
        Tfloat64, Tpointer, Tsarray;
    import dmd.expressionsem: toInteger;
    import dmd.typesem: alignsize, isIntegral, nextOf, size;

    if (memory)
        return;

    const bytes = type.size;
    if (bytes == 0)
        return;
    if (offset + bytes > 16) {
        memory = true;
        return;
    }

    if (type.ty == Tfloat32 || type.ty == Tfloat64) {
        merge(classes, offset, bytes, ArgumentPlan.ValueClass.sse, memory);
        return;
    }

    if (type.ty == Tcomplex32 || type.ty == Tcomplex64) {
        foreach (i; 0 .. (bytes + 7) / 8)
            merge(classes, offset + i * 8, 8,
                ArgumentPlan.ValueClass.sse, memory);
        return;
    }

    if (type.ty == Tpointer || type.ty == Tclass || type.ty == Tdelegate) {
        foreach (i; 0 .. (bytes + 7) / 8)
            merge(classes, offset + i * 8, 8,
                ArgumentPlan.ValueClass.integer, memory);
        return;
    }

    if (type.ty == Tarray) {
        merge(classes, offset, 8, ArgumentPlan.ValueClass.integer, memory);
        merge(classes, offset + 8, 8,
            ArgumentPlan.ValueClass.integer, memory);
        return;
    }

    if (type.isIntegral) {
        merge(classes, offset, bytes, ArgumentPlan.ValueClass.integer,
            memory);
        return;
    }

    if (auto array = type.isTypeSArray) {
        const count = array.dim.toInteger;
        foreach (i; 0 .. count)
            classify(type.nextOf, offset + i * type.nextOf.size,
                classes, memory);
        return;
    }

    if (auto aggregate = type.isTypeStruct) {
        // A nested non-POD field already made the whole aggregate
        // non-POD - `dmd.dsymbolsem.isPOD` checks every field itself -
        // and `aggregatePlan` catches that case before it ever reaches
        // here (see its own doc). Every field classified here is
        // therefore already known POD, and classifies by layout as usual.
        foreach (field; aggregate.sym.fields) {
            if (field.type is null)
                continue;

            const alignment = field.type.alignsize;
            const fieldOffset = offset + field.offset;
            if (alignment != 0 && fieldOffset % alignment != 0) {
                memory = true;
                return;
            }
            classify(field.type, fieldOffset, classes, memory);
        }
        return;
    }

    import std.conv: text;
    throw new Exception(
        text("ffi cannot classify a value of type `", type.toString, "`"),
    );
}

private void merge(
    ref ArgumentPlan.ValueClass[2] classes,
    in size_t offset,
    in size_t bytes,
    in ArgumentPlan.ValueClass incoming,
    ref bool memory,
) {
    const first = offset / 8;
    const last = (offset + bytes - 1) / 8;
    if (last >= 2) {
        memory = true;
        return;
    }

    foreach (i; first .. last + 1) {
        if (classes[i] == ArgumentPlan.ValueClass.none)
            classes[i] = incoming;
        else if (classes[i] != incoming)
            classes[i] = ArgumentPlan.ValueClass.integer;
    }
}
