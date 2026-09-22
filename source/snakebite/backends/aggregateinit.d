module snakebite.backends.aggregateinit;


private:


import snakebite.nativelayout: TypeFacts;


// What each backend's `StructLiteralExp` field loop and `NewExp` positional
// field loop used to re-derive independently, one arm at a time: whether a
// field is a plain value, a bitfield needing a masked store, or a
// static-array field dmd's own `fill` (`expressionsem.d`, issue 12509)
// handed a single element-typed literal for the whole array rather than
// one entry per slot - and, ahead of any field, whether the aggregate
// itself needs its hidden context field (`vthis`) filled. `classify`
// decides these once; each backend keeps only "evaluate into place" and
// "store bitfield at address" for the field steps, plus its own way of
// reading a function's context for the `vthis` step.
public struct InitStep {
    import dmd.mtype: Type;
    import dmd.expression: Expression;
    import dmd.declaration: VarDeclaration;
    import dmd.func: FuncDeclaration;

    public enum Kind {
        vthis,
        value,
        bitfield,
        broadcast,
    }

    public Kind kind;
    public size_t offset;
    // Meaningful for `value`, `bitfield` and `broadcast`.
    public TypeFacts facts;
    public Type type;
    // The element count `broadcast` copies `source` into.
    public size_t count;
    // The expression to evaluate for `value`, `bitfield` and `broadcast`.
    public Expression source;
    // The field being written, for a `bitfield` step's masked store.
    public VarDeclaration field;
    // The enclosing function whose context a `vthis` step stores - `null`
    // when the struct's own lexical parent is not a function, which is
    // dmd fact and not itself an error: `sd.toParent2()` only ever names
    // a class parent for a class nested in a class, never for a struct.
    public FuncDeclaration parentFunction;
}

public struct AggregateInitPlan {
    // `true` for a `StructLiteralExp`, whose destination starts as
    // arbitrary frame bytes; `false` for a `NewExp`'s positional fields,
    // whose destination is already the allocation's zeroed-and-blitted
    // `.init` image and needs only the fields actually given.
    public bool zeroFill;
    public InitStep[] steps;
}

// The single decision both backends' `StructLiteralExp` adapters read:
// `expression.elements` pairs positionally with `expression.sd.fields`,
// with a `null` entry for a field the literal leaves out entirely.
//
// `expression.useStaticInit` marks a literal built from a nested struct
// type's own `.init` (dmd's `getProperty`, `Id._init`, sets it whenever
// the type `needsNested`), not from constructing a live instance: dmd's
// glue layer (`e2ir.d`) then copies that type's precomputed static `.init`
// image wholesale instead of emitting these steps at all, so it never
// reads a context for `vthis` - there is no enclosing frame to read one
// from, since a type's `.init` is a compile-time constant, not a value
// built at some particular call site. `visit(StructLiteralExp)` already
// zeroes the destination before running any step, so skipping the `vthis`
// step here reproduces that null context exactly, matching compiled D
// instead of chasing a static chain that provably cannot exist.
public AggregateInitPlan planStructLiteral(
    imported!"dmd.expression".StructLiteralExp expression,
) {
    InitStep[] steps;

    InitStep vthisStep;
    if (!expression.useStaticInit && tryVthisStep(expression.sd, vthisStep))
        steps ~= vthisStep;

    if (expression.elements !is null)
        foreach (i, element; *expression.elements) {
            if (element is null)
                continue;

            steps ~= fieldStep(expression.sd.fields[i], element);
        }

    return AggregateInitPlan(true, steps);
}

// The single decision both backends' `NewExp` positional-field adapters
// read: `arguments` pairs positionally with `sd.fields`. For a struct
// with no user-defined constructor, dmd's own `fill` (`expressionsem.d`)
// pads this list out to `sd.nonHiddenFields()`, one entry per field, using
// each omitted field's default-initializer expression - except where `fill`
// had nothing to evaluate for a field, where it stores `null` instead: a
// zero-size field (e.g. `void[0]`), a field with an explicit `= void`
// initializer, or a field already overlapped by a given union member. In
// each case the allocation's own `.init` blit already leaves the field
// correctly initialised (or, for `= void`, deliberately not), so a `null`
// entry is skipped here the same way `planStructLiteral` skips one. More
// arguments than fields is a shape dmd's own semantic pass already
// rejected, so it is asserted rather than checked again by each backend.
public AggregateInitPlan planPositionalFields(
    imported!"dmd.dstruct".StructDeclaration sd,
    imported!"dmd.expression".Expressions* arguments,
)
in (arguments is null || arguments.length <= sd.fields.length)
{
    InitStep[] steps;

    InitStep vthisStep;
    if (tryVthisStep(sd, vthisStep))
        steps ~= vthisStep;

    if (arguments !is null)
        foreach (i, argument; *arguments) {
            if (argument is null)
                continue;

            steps ~= fieldStep(sd.fields[i], argument);
        }

    return AggregateInitPlan(false, steps);
}

// `sd.isNested()` is true only when dmd gave the struct a hidden `vthis`
// field; a `static struct` declared inside a function is lexically nested
// but has no such field.
private bool tryVthisStep(
    imported!"dmd.dstruct".StructDeclaration sd, out InitStep step,
) {
    if (!sd.isNested() || sd.vthis is null)
        return false;

    auto parent = sd.toParent2();
    step = InitStep(InitStep.Kind.vthis, sd.vthis.offset);
    step.parentFunction = parent is null ? null : parent.isFuncDeclaration;
    return true;
}

private InitStep fieldStep(
    imported!"dmd.declaration".VarDeclaration field,
    imported!"dmd.expression".Expression source,
) {
    auto sarrayType = field.type.isTypeSArray;
    if (sarrayType !is null && !source.type.equals(field.type)) {
        const elementFacts = TypeFacts.of(source.type);
        const fieldFacts = TypeFacts.of(sarrayType);
        auto step = InitStep(
            InitStep.Kind.broadcast, field.offset, elementFacts, source.type,
        );
        step.count = fieldFacts.size / elementFacts.size;
        step.source = source;
        return step;
    }

    const facts = TypeFacts.of(field.type);
    if (field.isBitFieldDeclaration !is null) {
        auto step = InitStep(
            InitStep.Kind.bitfield, field.offset, facts, field.type);
        step.source = source;
        step.field = field;
        return step;
    }

    auto step = InitStep(InitStep.Kind.value, field.offset, facts, field.type);
    step.source = source;
    return step;
}
