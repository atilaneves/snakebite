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
// before its hidden return pointer. dmd puts `this` first; ldc follows the
// System V order and puts the hidden return pointer first.
public enum contextPrecedesHiddenReturnPointer = () {
    version (DigitalMars)
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
    // In bytes, and always 1, 2, 4 or 8 for anything but `none`.
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

    public size_t memoryWords() const {
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

    public static ArgumentPlan of(imported!"dmd.mtype".Type type) {
        auto plan = aggregatePlan(type);
        if (plan.memory)
            validateMemoryParameter(type, plan);
        return plan;
    }
}

// The two ways a MEMORY-class parameter can be unsupported for now - see
// `ArgumentPlan.maxMemoryBytes` and the alignment note below. Only called
// for an explicit parameter (`ArgumentPlan.of`); a MEMORY-class *return*
// still travels through a hidden pointer regardless of either limit (see
// `needsHiddenReturnPointer`), so this never runs for one.
private void validateMemoryParameter(
    imported!"dmd.mtype".Type type, in ArgumentPlan plan,
) {
    import dmd.typesem: alignsize;
    import std.conv: text;

    // The stack area `buildMoves` places a MEMORY argument's eightbytes
    // into is only 8-byte aligned, not 16 - a value whose own alignment
    // is 16 (for example a struct containing `real`, whose x86-64 System
    // V alignment is 16) needs padding this plan does not yet insert.
    // Refused for now, with a clear message, rather than silently
    // misaligning it.
    if (type.alignsize > 8)
        throw new Exception(
            text("ffi cannot pass a value of type `", type.toString,
                "`: its ABI alignment is ", type.alignsize, " bytes, and " ~
                "only 8-byte-aligned MEMORY-class arguments are " ~
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

// The SysV ABI classifies a MEMORY result as a hidden return pointer. This
// also catches an unaligned aggregate, which the ABI classifies as MEMORY
// even when its size is at most two eightbytes. A MEMORY-class return
// always takes this path, whatever its size or alignment - unlike a
// MEMORY-class explicit parameter, it never becomes an `ArgumentPlan`
// `buildMoves` places on the stack, so neither of `ArgumentPlan.of`'s own
// limits applies to it.
public bool needsHiddenReturnPointer(imported!"dmd.mtype".Type type) {
    return aggregatePlan(type).memory;
}

private ArgumentPlan aggregatePlan(imported!"dmd.mtype".Type type) {
    import dmd.astenums:
        Taarray, Tclass, Tfloat32, Tfloat64, Tpointer, Tvoid;
    import dmd.typesem: isIntegral, isUnsigned, size;
    import std.algorithm: min;

    ArgumentPlan plan;
    if (type.ty == Tvoid)
        return plan;

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
