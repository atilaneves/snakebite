module snakebite.ffi.abi;


private:


import snakebite.failure.report: internalFailure;
import snakebite.ffi.shape: ArgumentPlan, Linkage, Register;

// This module classifies one value's System V AMD64 ABI shape - the
// `ArgumentPlan` and `Register` of `snakebite.ffi.shape` - from a dmd
// `Type`. It does not dispatch a call itself: that moved to the assembly
// stub in `snakebite.ffi.sysv`, replayed by `snakebite.ffi.plan` (ADR-0001,
// issue #334).

// The classes an eightbyte takes while `classify` walks a value.
private enum ValueClass {
    none,
    integer,
    sse,
    sseup,
    // The two eightbytes a scalar `real` (`long double`) always
    // spans together (`classify`'s own `Tfloat80` case) - never
    // produced alone, since `real`'s own 16-byte size and alignment
    // mean nothing smaller ever reaches an X87 classification.
    x87,
    x87up,
    memory,
}

// The `Linkage` of dmd's `linkage`.
public Linkage linkageOf(in imported!"dmd.astenums".LINK linkage) {
    import dmd.astenums: LINK;

    final switch (linkage) {
        case LINK.default_:
            return Linkage.default_;
        case LINK.d:
            return Linkage.d;
        case LINK.c:
            return Linkage.c;
        case LINK.cpp:
            return Linkage.cpp;
        case LINK.windows:
            return Linkage.windows;
        case LINK.objc:
            return Linkage.objc;
        case LINK.system:
            return Linkage.system;
    }
}


// The shape of one parameter. `aggregatePlan` itself already gives a
// non-trivially-copyable type (`isNonTriviallyCopyable`'s own doc) the
// indirect, one-pointer shape this used to build only for LDC: the same
// Itanium rule holds for any host compiler, since it is a fact about the
// calling convention, not about which compiler built the caller. A
// return's shape comes from `returnPlanOf`.
public ArgumentPlan argumentPlanOf(imported!"dmd.mtype".Type type) {
    return aggregatePlan(type);
}

public ArgumentPlan returnPlanOf(imported!"dmd.mtype".Type type) {
    import dmd.astenums: Tcomplex80;
    import dmd.typesem: size, toBasetype;

    auto baseType = type.toBasetype;
    // SysV returns `creal` in ST0 and ST1. Its argument form is
    // MEMORY-class, and an aggregate that contains it stays that way.
    if (baseType.ty == Tcomplex80)
        return ArgumentPlan(
            [Register(Register.Kind.x87, 16),
                Register(Register.Kind.x87, 16)],
            2,
            false,
        );

    // A bare `real` return and a struct (or union) return that,
    // once classified, is nothing but the two eightbytes a `real`
    // field spans - `isX87OnlyAggregate`'s own doc - crosses in
    // `%st0` instead of a general-purpose or SSE register: the one
    // case `aggregatePlan` cannot answer for itself, since a
    // *parameter* of that same shape has no `%st0` argument
    // register to travel in and has to fall back to
    // `argumentPlanOf`'s own MEMORY route below (verified against
    // gcc -O0: `struct { long double r; } make(void)` compiles to
    // `fld`/`fstp`/`fld`/`ret`, ending with the value already loaded
    // into `%st0`).
    if (isX87OnlyAggregate(type))
        return ArgumentPlan(
            [Register(Register.Kind.x87, cast(ubyte) type.size),
                Register.init],
            1,
            false,
        );
    return argumentPlanOf(type);
}

// The SysV ABI classifies a MEMORY result as a hidden return pointer, and
// so does a non-trivially-copyable result (`isNonTriviallyCopyable`'s own
// doc) - the same NRVO a hidden-pointer return already gives any large
// aggregate, just triggered by non-POD-ness rather than size. This also
// catches an unaligned POD aggregate, which the ABI classifies as MEMORY
// even when its size is at most two eightbytes. Either path always takes
// this route, whatever its size or alignment - unlike a MEMORY-class
// explicit parameter, it never becomes an `ArgumentPlan` `buildMoves`
// places on the stack, so `argumentPlanOf`'s alignment limit does not
// apply to it.
public bool needsHiddenReturnPointer(imported!"dmd.mtype".Type unbasedType) {
    import dmd.astenums: Tcomplex80;
    import dmd.typesem: toBasetype;

    // An enum has its base type's native layout and classification -
    // `classify`'s own entry unwraps it the same way for a parameter or
    // a field, and `isX87OnlyAggregate` unwraps it again for itself, so
    // this only has to happen once more here, for `aggregatePlan`'s own
    // fallback below.
    auto type = unbasedType.toBasetype;

    // The bare complex value returns in ST0/ST1; aggregate planning still
    // classifies a struct that contains it as MEMORY.
    if (type.ty == Tcomplex80)
        return false;

    // A clean X87 return (`isX87OnlyAggregate`'s own doc) crosses in
    // `%st0`, never through a hidden pointer.
    if (isX87OnlyAggregate(type))
        return false;
    const plan = aggregatePlan(type);
    return plan.memory || plan.indirect;
}

// Whether `type`, classified by `classify` below, is nothing but the
// X87/X87UP eightbyte pair a scalar `real` field spans on its own - a
// bare `real`, or a struct/union whose only field (or only overlapping
// fields, for a union) is one, however deeply nested - with no other
// field sharing either eightbyte to force a different class. `real`'s
// own 16-byte size and 16-byte alignment mean this is the *only* shape
// an aggregate up to two eightbytes can take without also containing a
// non-`real` field in the same eightbyte: field 0 at offset 0 always
// claims the entire first eightbyte pair, so a second field can only
// ever land in the same eightbytes through a union, not sequential
// struct layout.
//
// A *parameter* of this same shape still has no `%st0` argument
// register to travel in - only `returnPlanOf` asks this question, ahead of
// `aggregatePlan`'s own MEMORY route (verified against gcc -O0: `struct
// { long double r; } take(struct S s)` reads `s` directly off the
// stack, at `[rbp+0x10]`, never through a register).
private bool isX87OnlyAggregate(imported!"dmd.mtype".Type unbasedType) {
    import dmd.astenums: Tvoid;
    import dmd.typesem: size, toBasetype;

    auto type = unbasedType.toBasetype;
    if (type.ty == Tvoid)
        return false;

    const bytes = type.size;
    if (bytes == 0 || bytes > 16 || isDmdIntegerPairArray(type))
        return false;

    ValueClass[2] classes = [
        ValueClass.none, ValueClass.none,
    ];
    bool memory;
    classify(type, 0, classes, memory);
    return !memory && classes[0] == ValueClass.x87;
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
// gated to one host compiler the way a parameter-only wrapper used to
// gate it to LDC alone.
private bool isNonTriviallyCopyable(imported!"dmd.mtype".Type type) {
    import dmd.dsymbolsem: isPOD;
    import dmd.typesem: baseElemOf;

    auto aggregate = type.baseElemOf.isTypeStruct;
    return aggregate !is null && !aggregate.sym.isPOD();
}

// Whether `type` is a static array of one `real`, with no struct around
// it. dmd's own code generator passes and returns it in two INTEGER
// eightbytes, where its own `toArgTypes_sysv_x64` and ldc say X87 (verified
// by disassembling `extern(C) real[1] f(real[1] x)` built by dmd and by ldc2;
// a `struct { real[1] a; }` is X87 on both).
private bool isDmdIntegerPairArray(imported!"dmd.mtype".Type unbasedType) {
    version (DigitalMars) {
        import dmd.astenums: Tfloat80, Timaginary80, Tsarray;
        import dmd.typesem: baseElemOf, size, toBasetype;

        auto type = unbasedType.toBasetype;
        const element = type.baseElemOf.toBasetype.ty;
        return type.ty == Tsarray && type.size == 16
            && (element == Tfloat80 || element == Timaginary80);
    } else
        return false;
}

private ArgumentPlan aggregatePlan(imported!"dmd.mtype".Type unbasedType) {
    import dmd.astenums:
        Taarray, Tclass, Tfloat32, Tfloat64, Tfloat80, Tnull, Tpointer,
        Tvector, Tvoid;
    import dmd.typesem: alignsize, isIntegral, isUnsigned, size, toBasetype;
    import std.algorithm: min;

    // An enum has its base type's native layout and classification - the
    // one rule this whole module follows (`classify`'s own doc). Every
    // `type.ty` check below only matches a base-type case, so an enum
    // argument or return has to be unwrapped once here, before any of
    // them run.
    auto type = unbasedType.toBasetype;

    ArgumentPlan plan;
    if (type.ty == Tvoid)
        return plan;

    plan.stackAlignment = type.alignsize;

    if (isDmdIntegerPairArray(type)) {
        plan.registers[0] = Register(Register.Kind.integer, 8);
        plan.registers[1] = Register(Register.Kind.integer, 8);
        plan.count = 2;
        return plan;
    }

    if (isNonTriviallyCopyable(type)) {
        plan.registers[0] = Register(Register.Kind.pointer, 8);
        plan.count = 1;
        plan.indirect = true;
        plan.stackAlignment = size_t.sizeof;
        return plan;
    }

    if (type.ty == Tvector) {
        if (type.size <= 16) {
            plan.registers[0] = Register(
                Register.Kind.sse, cast(ubyte) type.size);
            plan.count = 1;
        } else {
            plan.registers[0] = Register(Register.Kind.sse, 16);
            plan.registers[1] = Register(Register.Kind.sse, 16);
            plan.count = 2;
        }
        return plan;
    }

    if (type.ty == Tpointer || type.ty == Tclass || type.ty == Taarray
            || type.ty == Tnull) {
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

    if (type.ty == Tfloat80) {
        plan.memory = true;
        plan.memoryBytes = type.size;
        plan.stackAlignment = type.alignsize;
        return plan;
    }

    if (type.isIntegral) {
        import snakebite.native.value: isIntegralSize;

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
        plan.stackAlignment = type.alignsize;
        return plan;
    }

    ValueClass[2] classes = [
        ValueClass.none, ValueClass.none,
    ];
    bool memory;
    classify(type, 0, classes, memory);
    // The psABI post-merge cleanup turns an SSEUP into SSE when its
    // preceding eightbyte is not SSE or SSEUP. A union can leave that
    // shape after fields merge into different classes.
    if (!memory)
        foreach (i; 0 .. count)
            if (classes[i] == ValueClass.sseup
                    && (i == 0
                        || (classes[i - 1] != ValueClass.sse
                            && classes[i - 1]
                                != ValueClass.sseup)))
                classes[i] = ValueClass.sse;
    // No argument register exists for an X87/X87UP eightbyte - only a
    // *return* value can cross in `%st0` (`isX87OnlyAggregate`'s own
    // doc, checked by `returnPlanOf` before this function ever runs for a
    // clean real-only shape), so this function's own callers - every
    // parameter, and `returnPlanOf`'s own fallback for anything that is not
    // a clean X87 shape - always take the MEMORY route real native code
    // takes for such a value (verified against gcc -O0: `struct
    // { long double r; } take(struct S s)` reads `s` straight off the
    // stack, never a register; `union { long double r; short a; } u`
    // - X87UP without a preceding X87, once the union's `short` field
    // merges eightbyte 0 away from X87 - returns through a hidden
    // pointer the same as any other MEMORY-class return).
    if (!memory)
        foreach (class_; classes)
            if (class_ == ValueClass.x87
                    || class_ == ValueClass.x87up)
                memory = true;
    if (memory) {
        plan.memory = true;
        plan.memoryBytes = bytes;
        plan.stackAlignment = type.alignsize;
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
                if (i + 1 < count
                        && classes[i + 1] == ValueClass.sseup) {
                    plan.registers[plan.count++] = Register(
                        Register.Kind.sse, cast(ubyte) bytes);
                    break;
                }
                plan.registers[i] = Register(
                    Register.Kind.sse,
                    cast(ubyte) min(8, bytes - i * 8),
                );
                ++plan.count;
                break;
            case sseup:
                break;
            case x87, x87up:
                // Ruled out above: every path here already forced
                // `memory` for either class.
                internalFailure();
            case memory:
                internalFailure();
        }
    }
    return plan;
}

private void classify(
    imported!"dmd.mtype".Type unbasedType,
    in size_t offset,
    ref ValueClass[2] classes,
    ref bool memory,
) {
    import dmd.astenums: TY;
    import dmd.expressionsem: toInteger;
    import dmd.typesem: alignsize, isIntegral, nextOf, size, toBasetype;

    if (memory)
        return;

    // An enum has its base type's native layout and classification, the
    // same "native layout" rule every backend already follows for every
    // other type (`ai/CODING.md`'s runtime-semantics section). `type.ty`
    // below never matches `Tenum` itself, only a base-type case, so an
    // unclassified enum has to be unwrapped exactly once, here at this
    // function's own entry - the only place every path into `classify` (a
    // parameter, a return, a struct field walked recursively from
    // `aggregatePlan` below) passes through.
    auto type = unbasedType.toBasetype;

    const bytes = type.size;
    if (offset + bytes > 16) {
        memory = true;
        return;
    }

    final switch (type.ty) with (TY) {
    case Tfloat32, Tfloat64, Timaginary32, Timaginary64:
        merge(classes, offset, bytes, ValueClass.sse, memory);
        return;
    // `real` (`long double`) always spans exactly two eightbytes on this
    // ABI - its own 16-byte size and 16-byte alignment (`isIntegralSize`
    // never matches it, so it never takes the `isIntegral` case below)
    // - X87 for the low eightbyte, X87UP for the high one. A `creal`
    // field (`Tcomplex80`) never reaches this function at all: it is
    // always 32 bytes, so the `offset + bytes > 16` check above this
    // function's entry already forces MEMORY for it before any
    // type-specific case runs. A `creal` parameter and any aggregate
    // containing one take `aggregatePlan`'s own `count > 2` branch;
    // `returnPlanOf` handles bare `creal` before this route.
    case Tfloat80, Timaginary80:
        merge(classes, offset, 8, ValueClass.x87, memory);
        merge(classes, offset + 8, 8, ValueClass.x87up,
            memory);
        return;
    case Tcomplex32, Tcomplex64:
        foreach (i; 0 .. (bytes + 7) / 8)
            merge(classes, offset + i * 8, 8,
                ValueClass.sse, memory);
        return;
    case Tpointer, Tclass, Tdelegate, Taarray, Tnull:
        foreach (i; 0 .. (bytes + 7) / 8)
            merge(classes, offset + i * 8, 8,
                ValueClass.integer, memory);
        return;
    case Tarray:
        merge(classes, offset, 8, ValueClass.integer, memory);
        merge(classes, offset + 8, 8,
            ValueClass.integer, memory);
        return;
    // `void` only occurs as the element of a `void[N]`, which both host
    // compilers classify as `ubyte[N]`.
    case Tvoid, Tbool, Tchar, Twchar, Tdchar, Tint8, Tuns8, Tint16, Tuns16,
        Tint32, Tuns32, Tint64, Tuns64, Tint128, Tuns128:
        merge(classes, offset, bytes, ValueClass.integer,
            memory);
        return;
    case Tsarray: {
        auto array = type.isTypeSArray;
        assert(array !is null);
        const count = array.dim.toInteger;
        // dmd's `toArgTypes_sysv_x64` and ldc both make an aggregate that
        // holds a zero-length array MEMORY: it is an aggregate with no
        // fields.
        if (count == 0) {
            memory = true;
            return;
        }
        foreach (i; 0 .. count)
            classify(type.nextOf, offset + i * type.nextOf.size,
                classes, memory);
        return;
    }
    case Tstruct: {
        auto aggregate = type.isTypeStruct;
        assert(aggregate !is null);
        // dmd's own rule (`argtypes_sysv_x64.d`'s `toArgTypes_sysv_x64`:
        // "if (nfields == 0) return memory();"): a struct with no fields
        // classifies MEMORY, not `none` - an empty `fields` walk below
        // would otherwise leave every eightbyte class untouched instead
        // of reaching either outcome. Both host compilers still return
        // such a value through a hidden pointer, one byte written
        // through whatever the calling convention's hidden-pointer
        // register already held (verified with `objdump`: `struct E {}
        // E f() { return E(); }` compiles to `mov rax, rdi; mov byte
        // [rdi], 0; ret` on both dmd and ldc) - this is the same MEMORY
        // rule `aggregatePlan` already gives an oversized or unaligned
        // aggregate, just triggered by a field count of zero instead.
        if (aggregate.sym.fields.length == 0) {
            memory = true;
            return;
        }

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
    // These types cannot occur in a value after `toBasetype` and semantic
    // analysis. Vectors use the same two-SSE-register layout as their
    // element bytes on SysV AMD64.
    case Tvector:
        merge(classes, offset, 8, ValueClass.sse, memory);
        foreach (i; 1 .. (bytes + 7) / 8)
            merge(classes, offset + i * 8, 8,
                ValueClass.sseup, memory);
        return;
    case Tcomplex80:
        memory = true;
        return;
    // Like dmd, ignore a member that cannot hold a value.
    case Tnoreturn:
        return;
    case Tfunction, Treference, Tident, Tnone, Terror, Tenum,
        Tinstance, Ttypeof, Ttuple, Tslice, Treturn, Ttraits, Tmixin,
        Ttag:
        internalFailure();
    }
}

// The SysV merge rule two different eightbyte classes go through when a
// union overlaps them at the same offset (`classify`'s own `TypeStruct`
// case walks every field, union or not, at its own declared offset, so
// two fields sharing an eightbyte only ever happens for a union),
// applied in the ABI's own priority order: equal classes need no rule;
// otherwise NONE always loses to whatever else is there (the "first
// field at this offset" case, handled by the caller directly above);
// INTEGER always wins next, since a plain 8-byte register copy is a
// valid, lossless way to carry any of these eightbytes' raw bytes; an
// X87 or X87UP eightbyte that cannot merge into INTEGER has no shared
// register class left to fall back to - unlike two different
// non-INTEGER, non-X87 classes, which SSE always can - so the whole
// argument becomes MEMORY instead (verified against gcc -O0: `union
// { long double r; short a; } take(union U u)` reads `u` straight off
// the stack, and `union U make(void)` returns through a hidden pointer,
// not `%st0` - `a`'s own INTEGER class merges X87 away from eightbyte 0,
// leaving eightbyte 1's X87UP without the eightbyte 0 X87 the post-merge
// check right after this function's own caller requires).
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
        const existing = classes[i];
        if (existing == ValueClass.none) {
            classes[i] = incoming;
        } else if (existing == incoming) {
            // Nothing to merge - both fields already agree.
        } else if (existing == ValueClass.integer
                || incoming == ValueClass.integer) {
            classes[i] = ValueClass.integer;
        } else if (existing == ValueClass.x87
                || existing == ValueClass.x87up
                || incoming == ValueClass.x87
                || incoming == ValueClass.x87up) {
            memory = true;
        } else {
            classes[i] = ValueClass.sse;
        }
    }
}

