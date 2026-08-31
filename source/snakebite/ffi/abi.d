module snakebite.ffi.abi;


private:


// The call plan keeps this many parameter slots. The integer register
// limit is separate: values after the first six integer words go on the
// stack, but they still belong to the function's parameter list.
public enum maxArguments = 16;
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

private enum ValueClass {
    none,
    integer,
    sse,
    memory,
}

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

    public static Register of(imported!"dmd.mtype".Type type) {
        if (type.ty == Tvoid)
            return Register(Kind.none, 0);

        const plan = aggregatePlan(type);
        if (plan.memory || plan.count == 0) {
            import std.conv: text;

            throw new Exception(
                text("ffi cannot pass a value of type `", type.toString,
                    "` in one register"),
            );
        }
        return plan.registers[0];
    }
}

// How a value travels. A regular value has at most two eightbytes after
// the SysV cleanup rule. A MEMORY value is handled by a hidden pointer for
// returns and is refused for explicit parameters until stack memory values
// have a separate call path.
public struct ArgumentPlan {
    public Register[2] registers;
    public ubyte count;
    public bool memory;

    public static ArgumentPlan of(imported!"dmd.mtype".Type type) {
        auto plan = aggregatePlan(type);
        if (plan.memory) {
            import std.conv: text;

            throw new Exception(
                text("ffi cannot pass a value of type `", type.toString,
                    "`: its ABI class is MEMORY"),
            );
        }
        return plan;
    }
}

// The return words from an indirect call. This is output storage for the
// invocation helper, not a type used as the native function's return type:
// the native return type must itself have the right INTEGER/SSE ABI class.
public struct ReturnWords {
    public size_t first;
    public size_t second;
    public size_t floatingFirst;
    public size_t floatingSecond;
}

// The SysV ABI classifies a MEMORY result as a hidden return pointer. This
// also catches an unaligned aggregate, which the ABI classifies as MEMORY
// even when its size is at most two eightbytes.
public bool needsHiddenReturnPointer(imported!"dmd.mtype".Type type) {
    return aggregatePlan(type).memory;
}

private ArgumentPlan aggregatePlan(imported!"dmd.mtype".Type type) {
    import dmd.astenums:
        Taarray, Tclass, Tfloat32, Tfloat64, Tpointer, Tvoid;
    import dmd.typesem: size;
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
        return plan;
    }

    ValueClass[2] classes = [ValueClass.none, ValueClass.none];
    bool memory;
    classify(type, 0, classes, memory);
    if (memory) {
        plan.memory = true;
        return plan;
    }

    foreach (i; 0 .. count) {
        final switch (classes[i]) with (ValueClass) {
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
    ref ValueClass[2] classes,
    ref bool memory,
) {
    import dmd.astenums:
        Tarray, Tclass, Tcomplex32, Tcomplex64, Tdelegate, Tfloat32,
        Tfloat64, Tpointer, Tsarray;
    import dmd.typesem: size;

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
        merge(classes, offset, bytes, ValueClass.sse, memory);
        return;
    }

    if (type.ty == Tcomplex32 || type.ty == Tcomplex64) {
        foreach (i; 0 .. (bytes + 7) / 8)
            merge(classes, offset + i * 8, 8, ValueClass.sse, memory);
        return;
    }

    if (type.ty == Tpointer || type.ty == Tclass || type.ty == Tdelegate) {
        foreach (i; 0 .. (bytes + 7) / 8)
            merge(classes, offset + i * 8, 8, ValueClass.integer, memory);
        return;
    }

    if (type.ty == Tarray) {
        merge(classes, offset, 8, ValueClass.integer, memory);
        merge(classes, offset + 8, 8, ValueClass.integer, memory);
        return;
    }

    if (type.isIntegral) {
        merge(classes, offset, bytes, ValueClass.integer, memory);
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
    ref ValueClass[2] classes,
    in size_t offset,
    in size_t bytes,
    in ValueClass incoming,
    ref bool memory,
) {
    const first = offset / 8;
    const last = (offset + bytes - 1) / 8;
    if (last >= 2) {
        memory = true;
        return;
    }

    foreach (i; first .. last + 1) {
        if (classes[i] == ValueClass.none)
            classes[i] = incoming;
        else if (classes[i] != incoming)
            classes[i] = ValueClass.integer;
    }
}

// Reads one eightbyte's native bytes and applies the scalar widening rule
// when the value is a scalar. Aggregate eightbytes are copied unchanged.
public size_t word(in Register register, in void* slot) {
    final switch (register.kind) with (Register.Kind) {
        case pointer:
            return cast(size_t) *cast(void**) slot;

        case unsigned:
            switch (register.size) {
                case 1: return *cast(ubyte*) slot;
                case 2: return *cast(ushort*) slot;
                case 4: return *cast(uint*) slot;
                case 8: return *cast(size_t*) slot;
                default: assert(false, "unsupported unsigned size");
            }

        case signed:
            switch (register.size) {
                case 1: return cast(size_t) cast(long) *cast(byte*) slot;
                case 2: return cast(size_t) cast(long) *cast(short*) slot;
                case 4: return cast(size_t) cast(long) *cast(int*) slot;
                case 8: return *cast(size_t*) slot;
                default: assert(false, "unsupported signed size");
            }

        case integer:
        case sse: {
            size_t result;
            import core.stdc.string: memcpy;
            memcpy(&result, slot, register.size);
            return result;
        }

        case none:
            assert(false, "a `void` argument has nothing to pass");
    }
}

// Writes one raw return eightbyte back into native storage.
public void writeWord(
    in Register register,
    in size_t result,
    void* place,
) {
    if (register.kind == Register.Kind.none)
        return;

    if (register.kind == Register.Kind.signed
            || register.kind == Register.Kind.unsigned
            || register.kind == Register.Kind.pointer) {
        import snakebite.nativelayout: storeIntegral;
        storeIntegral(place, result, register.size);
        return;
    }

    import core.stdc.string: memcpy;
    memcpy(place, &result, register.size);
}

private enum ReturnKind {
    void_,
    integer,
    integerPair,
    sse,
    ssePair,
    mixed,
}

private struct IntegerReturn {
    size_t first;
    size_t second;
}

private struct FloatingReturn {
    double first;
    double second;
}

private struct MixedReturn {
    size_t integer;
    double floating;
}

// Calls `address` with raw argument words. The class sequence is in the
// callee's declaration order. With no stack words, integer and SSE words
// can be grouped because SysV allocates the two register files separately.
// A mixed call with stack words needs source-order stack slots, so it is
// rejected until that call shape has a dedicated lowering.
public ReturnWords invoke(
    void* address,
    scope const size_t[] words,
    scope const Register.Kind[] kinds,
    in ArgumentPlan returnPlan,
) {
    assert(words.length == kinds.length);

    size_t[maxArguments] integerWords;
    size_t[maxArguments] floatingWords;
    size_t integerCount;
    size_t floatingCount;
    bool hasInteger;
    bool hasFloating;
    foreach (i, kind; kinds) {
        final switch (kind) with (Register.Kind) {
            case signed:
            case unsigned:
            case pointer:
            case integer:
                integerWords[integerCount++] = words[i];
                hasInteger = true;
                break;
            case sse:
                floatingWords[floatingCount++] = words[i];
                hasFloating = true;
                break;
            case none:
                assert(false, "a `void` argument has no ABI class");
        }
    }

    if (hasInteger && hasFloating
            && integerCount > maxIntegerArguments
            && floatingCount > maxFloatingArguments)
        throw new Exception(
            "ffi cannot call a mixed INTEGER/SSE shape with stack arguments",
        );

    const kind = returnKind(returnPlan);
    switch (kind) {
        static foreach (returnKind_; [
            ReturnKind.void_, ReturnKind.integer, ReturnKind.integerPair,
            ReturnKind.sse, ReturnKind.ssePair, ReturnKind.mixed,
        ]) {
            case returnKind_:
                return dispatch!(returnKind_)(address,
                    integerWords[0 .. integerCount],
                    floatingWords[0 .. floatingCount]);
        }
        default:
            assert(false);
    }
}

private ReturnKind returnKind(in ArgumentPlan plan) {
    size_t integers;
    size_t floating;
    foreach (register; plan.registers[0 .. plan.count]) {
        if (register.kind == Register.Kind.sse)
            ++floating;
        else
            ++integers;
    }

    if (integers == 0 && floating == 0)
        return ReturnKind.void_;
    if (integers == 1 && floating == 0)
        return ReturnKind.integer;
    if (integers == 2 && floating == 0)
        return ReturnKind.integerPair;
    if (integers == 0 && floating == 1)
        return ReturnKind.sse;
    if (integers == 0 && floating == 2)
        return ReturnKind.ssePair;
    if (integers == 1 && floating == 1)
        return ReturnKind.mixed;
    assert(false, "unsupported return class shape");
}

private ReturnWords dispatch(ReturnKind kind)(
    void* address,
    scope const size_t[] integerWords,
    scope const size_t[] floatingWords,
) {
    static foreach (integerCount; 0 .. maxArguments + 1) {
        if (integerWords.length == integerCount) {
            static foreach (floatingCount; 0 .. maxArguments + 1) {
                if (floatingWords.length == floatingCount)
                    return call!(kind, integerCount, floatingCount)(
                        address, integerWords, floatingWords,
                    );
            }
        }
    }
    assert(false, "arity is checked before dispatch");
    return ReturnWords.init;
}

private ReturnWords call(ReturnKind kind, size_t integerCount,
    size_t floatingCount)(
    void* address,
    scope const size_t[] integerWords,
    scope const size_t[] floatingWords,
) {
    double[maxArguments] floatingArguments;
    foreach (i; 0 .. floatingCount)
        *cast(size_t*) &floatingArguments[i] = floatingWords[i];

    alias Native = NativeFunction!(kind, integerCount, floatingCount).Native;
    ReturnWords result;
    static if (kind == ReturnKind.void_) {
        mixin("(cast(Native) address)(" ~
            argumentList(integerCount, floatingCount) ~ ");");
    } else {
        mixin("const nativeResult = (cast(Native) address)(" ~
            argumentList(integerCount, floatingCount) ~ ");");
        static if (kind == ReturnKind.integer)
            result.first = nativeResult;
        else static if (kind == ReturnKind.integerPair) {
            result.first = nativeResult.first;
            result.second = nativeResult.second;
        } else static if (kind == ReturnKind.sse)
            result.floatingFirst = bits(nativeResult);
        else static if (kind == ReturnKind.ssePair) {
            result.floatingFirst = bits(nativeResult.first);
            result.floatingSecond = bits(nativeResult.second);
        } else static if (kind == ReturnKind.mixed) {
            result.first = nativeResult.integer;
            result.floatingFirst = bits(nativeResult.floating);
        }
    }
    return result;
}

private template NativeFunction(ReturnKind kind, size_t integerCount,
    size_t floatingCount) {
    import std.meta: Repeat;

    static if (kind == ReturnKind.void_)
        alias Return = void;
    else static if (kind == ReturnKind.integer)
        alias Return = size_t;
    else static if (kind == ReturnKind.integerPair)
        alias Return = IntegerReturn;
    else static if (kind == ReturnKind.sse)
        alias Return = double;
    else static if (kind == ReturnKind.ssePair)
        alias Return = FloatingReturn;
    else
        alias Return = MixedReturn;

    alias Native = extern(C) Return function(
        Repeat!(integerCount, size_t),
        Repeat!(floatingCount, double),
    );
}

private size_t bits(in double value) {
    return *cast(const size_t*) &value;
}

private string argumentList(in size_t integerCount, in size_t floatingCount) {
    import std.conv: text;

    string list;
    foreach (i; 0 .. integerCount) {
        if (list.length != 0)
            list ~= ", ";
        list ~= text("integerWords[", i, "]");
    }
    foreach (i; 0 .. floatingCount) {
        if (list.length != 0)
            list ~= ", ";
        list ~= text("floatingArguments[", i, "]");
    }
    return list;
}
