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
        x87,
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
        // The two eightbytes a scalar `real` (`long double`) always
        // spans together (`classify`'s own `Tfloat80` case) - never
        // produced alone, since `real`'s own 16-byte size and alignment
        // mean nothing smaller ever reaches an X87 classification.
        x87,
        x87up,
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
            validateMemoryParameter(type);
        return plan;
    }

    public static ArgumentPlan ofReturn(Type type) {
        import dmd.typesem: size;

        // A bare `real` return and a struct (or union) return that,
        // once classified, is nothing but the two eightbytes a `real`
        // field spans - `isX87OnlyAggregate`'s own doc - crosses in
        // `%st0` instead of a general-purpose or SSE register: the one
        // case `aggregatePlan` cannot answer for itself, since a
        // *parameter* of that same shape has no `%st0` argument
        // register to travel in and has to fall back to `of`'s own
        // MEMORY route below (verified against gcc -O0: `struct
        // { long double r; } make(void)` compiles to `fld`/`fstp`/
        // `fld`/`ret`, ending with the value already loaded into
        // `%st0`).
        if (isX87OnlyAggregate(type))
            return ArgumentPlan(
                [Register(Register.Kind.x87, cast(ubyte) type.size),
                    Register.init],
                1,
                false,
            );
        return of(type);
    }
}

// Only explicit MEMORY-class parameters need the stack alignment check.
// A MEMORY-class return travels through a hidden pointer instead.
private void validateMemoryParameter(
    imported!"dmd.mtype".Type type,
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
}

// The SysV ABI classifies a MEMORY result as a hidden return pointer, and
// so does a non-trivially-copyable result (`isNonTriviallyCopyable`'s own
// doc) - the same NRVO a hidden-pointer return already gives any large
// aggregate, just triggered by non-POD-ness rather than size. This also
// catches an unaligned POD aggregate, which the ABI classifies as MEMORY
// even when its size is at most two eightbytes. Either path always takes
// this route, whatever its size or alignment - unlike a MEMORY-class
// explicit parameter, it never becomes an `ArgumentPlan` `buildMoves`
// places on the stack, so `ArgumentPlan.of`'s alignment limit does not
// apply to it.
public bool needsHiddenReturnPointer(imported!"dmd.mtype".Type unbasedType) {
    import dmd.typesem: toBasetype;

    // An enum has its base type's native layout and classification -
    // `classify`'s own entry unwraps it the same way for a parameter or
    // a field, and `isX87OnlyAggregate` unwraps it again for itself, so
    // this only has to happen once more here, for `aggregatePlan`'s own
    // fallback below.
    auto type = unbasedType.toBasetype;

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
// register to travel in - only `ofReturn` asks this question, ahead of
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
    if (bytes == 0 || bytes > 16)
        return false;

    ArgumentPlan.ValueClass[2] classes = [
        ArgumentPlan.ValueClass.none, ArgumentPlan.ValueClass.none,
    ];
    bool memory;
    classify(type, 0, classes, memory);
    return !memory && classes[0] == ArgumentPlan.ValueClass.x87;
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

private ArgumentPlan aggregatePlan(imported!"dmd.mtype".Type unbasedType) {
    import dmd.astenums:
        Taarray, Tclass, Tfloat32, Tfloat64, Tfloat80, Tnull, Tpointer,
        Tvoid;
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

    if (isNonTriviallyCopyable(type)) {
        plan.registers[0] = Register(Register.Kind.pointer, 8);
        plan.count = 1;
        plan.indirect = true;
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
        plan.memoryAlignment = type.alignsize;
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
    // No argument register exists for an X87/X87UP eightbyte - only a
    // *return* value can cross in `%st0` (`isX87OnlyAggregate`'s own
    // doc, checked by `ofReturn` before this function ever runs for a
    // clean real-only shape), so this function's own callers - every
    // parameter, and `ofReturn`'s own fallback for anything that is not
    // a clean X87 shape - always take the MEMORY route real native code
    // takes for such a value (verified against gcc -O0: `struct
    // { long double r; } take(struct S s)` reads `s` straight off the
    // stack, never a register; `union { long double r; short a; } u`
    // - X87UP without a preceding X87, once the union's `short` field
    // merges eightbyte 0 away from X87 - returns through a hidden
    // pointer the same as any other MEMORY-class return).
    if (!memory)
        foreach (class_; classes)
            if (class_ == ArgumentPlan.ValueClass.x87
                    || class_ == ArgumentPlan.ValueClass.x87up)
                memory = true;
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
            case x87, x87up:
                // Ruled out above: every path here already forced
                // `memory` for either class.
                assert(false);
            case memory:
                assert(false);
        }
    }
    return plan;
}

private void classify(
    imported!"dmd.mtype".Type unbasedType,
    in size_t offset,
    ref ArgumentPlan.ValueClass[2] classes,
    ref bool memory,
) {
    import dmd.astenums:
        Taarray, Tarray, Tclass, Tcomplex32, Tcomplex64, Tdelegate,
        Tfloat32, Tfloat64, Tfloat80, Tnull, Tpointer, Tsarray;
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

    // `real` (`long double`) always spans exactly two eightbytes on this
    // ABI - its own 16-byte size and 16-byte alignment (`isIntegralSize`
    // never matches it, so it never takes the `isIntegral` case below)
    // - X87 for the low eightbyte, X87UP for the high one. A `creal`
    // field (`Tcomplex80`) never reaches this function at all: it is
    // always 32 bytes, so the `offset + bytes > 16` check above this
    // function's entry already forces MEMORY for it before any
    // type-specific case runs, the same route a `creal` return or
    // parameter already takes through `aggregatePlan`'s own
    // `count > 2` branch.
    if (type.ty == Tfloat80) {
        merge(classes, offset, 8, ArgumentPlan.ValueClass.x87, memory);
        merge(classes, offset + 8, 8, ArgumentPlan.ValueClass.x87up,
            memory);
        return;
    }

    if (type.ty == Tcomplex32 || type.ty == Tcomplex64) {
        foreach (i; 0 .. (bytes + 7) / 8)
            merge(classes, offset + i * 8, 8,
                ArgumentPlan.ValueClass.sse, memory);
        return;
    }

    if (type.ty == Tpointer || type.ty == Tclass || type.ty == Tdelegate
            || type.ty == Taarray || type.ty == Tnull) {
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

    import std.conv: text;
    throw new Exception(
        text("ffi cannot classify a value of type `", type.toString, "`"),
    );
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
        const existing = classes[i];
        if (existing == ArgumentPlan.ValueClass.none) {
            classes[i] = incoming;
        } else if (existing == incoming) {
            // Nothing to merge - both fields already agree.
        } else if (existing == ArgumentPlan.ValueClass.integer
                || incoming == ArgumentPlan.ValueClass.integer) {
            classes[i] = ArgumentPlan.ValueClass.integer;
        } else if (existing == ArgumentPlan.ValueClass.x87
                || existing == ArgumentPlan.ValueClass.x87up
                || incoming == ArgumentPlan.ValueClass.x87
                || incoming == ArgumentPlan.ValueClass.x87up) {
            memory = true;
        } else {
            classes[i] = ArgumentPlan.ValueClass.sse;
        }
    }
}
