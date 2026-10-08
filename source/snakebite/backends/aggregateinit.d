module snakebite.backends.aggregateinit;


private:


import snakebite.nativelayout: TypeFacts;
import snakebite.nativelayout: fieldOffset;
import dmd.typesem: toBasetype;


// The single decision both backends use for a `NewExp`'s storage. A heap
// allocation is already recorded in `lowering`; placement construction uses
// the address of its lvalue, and an on-stack class gets frame storage. The
// object kind is normalized here so consumers do not classify `newtype`
// independently.
public struct NewPlan {
    import dmd.expression: Expression;

    public enum Destination {
        lowering,
        placement,
        stack,
    }

    public enum ObjectKind {
        scalar,
        struct_,
        class_,
    }

    public Destination destination;
    public ObjectKind objectKind;
    public Expression placement;
    public Expression argumentPrefix;
}

public NewPlan planNew(imported!"dmd.expression".NewExp expression) {
    auto type = expression.newtype.toBasetype;
    auto objectKind = type.isTypeClass !is null
        ? NewPlan.ObjectKind.class_
        : type.isTypeStruct !is null
            ? NewPlan.ObjectKind.struct_
            : NewPlan.ObjectKind.scalar;

    if (expression.placement !is null)
        return NewPlan(
            NewPlan.Destination.placement,
            objectKind,
            expression.placement,
            expression.argprefix,
        );

    // dmd gives no `lowering` to a `scope class` (it never uses the GC) and
    // sets `onstack` only for a `scope` variable's initialiser, so any
    // other `new` of one is a frame temporary.
    return NewPlan(
        expression.onstack || expression.type.isScopeClass
            ? NewPlan.Destination.stack
            : NewPlan.Destination.lowering,
        objectKind,
        null,
        expression.argprefix,
    );
}


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
    import dmd.dsymbol: Dsymbol;

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
    // The expression to evaluate for `value`, `bitfield` and `broadcast`,
    // and, for a `vthis` step whose source is `NewExp.thisexp` rather than
    // an enclosing function's context, the outer-object expression itself.
    public Expression source;
    // The field being written, for a `bitfield` step's masked store.
    public VarDeclaration field;
    // The symbol whose context a `vthis` step stores, when the aggregate
    // is a nested one made in a function, or in an aggregate whose `this`
    // is the context: dmd gives `vthis` the context of the declaration
    // scope and, for an aggregate with two contexts, `vthis2` the context
    // of the instantiation scope. `null` is not itself an error: it leaves
    // the field at its `.init` zero, which is the language's own treatment
    // of a `static struct` with no captured context. Also `null`, and
    // unused, for a `vthis` step whose `source` is set instead (a nested
    // class's `NewExp.thisexp`).
    public Dsymbol contextOwner;
    // A byte adjustment a `vthis` step with `source` set adds after
    // evaluating it - the same base-class offset dmd's own glue layer
    // (`glue/e2ir.d`, `NewExp.thisexp` case) adds when `thisexp`'s static
    // type is a class *derived* from the nested class's actual lexical
    // parent, computed the same way an upcast `CastExp` computes it
    // (`snakebite.backends.casts.classify`'s `classReference` kind).
    public int sourceAdjustment;
}

public struct AggregateInitPlan {
    // `true` for a `StructLiteralExp`, whose destination starts as
    // arbitrary frame bytes; `false` for a `NewExp`'s positional fields,
    // whose destination is already the allocation's zeroed-and-blitted
    // `.init` image and needs only the fields actually given.
    public bool zeroFill;
    public InitStep[] steps;
}

// Checked by `applyStep` and `driveInit`: a backend's hooks type needs
// exactly these four per-`InitStep.Kind` methods - its own methods, or a
// small adapter over them - so a backend that gets a name wrong sees one
// clear "does not satisfy" error at its own call site rather than an
// obscure one inside this module.
private enum isAggregateInitHooks(Hooks) = is(typeof((ref Hooks hooks, InitStep step) {
    hooks.applyVthis(step);
    hooks.applyValue(step);
    hooks.applyBitfield(step);
    hooks.applyBroadcast(step);
}));

// The one place that turns an `InitStep.Kind` into an action, shared by
// both backends instead of each keeping its own `final switch`. `Hooks`
// is a compile-time parameter, not four delegates, so a backend states
// its four per-kind actions - "store a value into a field", "store a
// bitfield", "broadcast a static-array element", "write the hidden
// context pointer" - once, instead of rebuilding the same four lambdas
// at every call site; `step.kind` alone chooses which method runs.
public void applyStep(Hooks)(ref Hooks hooks, InitStep step)
if (isAggregateInitHooks!Hooks)
{
    final switch (step.kind) with (InitStep.Kind) {
    case vthis: hooks.applyVthis(step); return;
    case value: hooks.applyValue(step); return;
    case bitfield: hooks.applyBitfield(step); return;
    case broadcast: hooks.applyBroadcast(step); return;
    }
}

// The single order both backends' `NewExp` adapters used to re-derive for
// themselves: every `vthis` step runs first, so a constructor's own body
// already sees the right hidden context the moment it starts, whether
// that body reads it directly or hands it on to a nested aggregate of its
// own. A plan with a constructor to call (`hasConstructor`) then hands
// off to it and stops - the constructor's own body owns the rest of
// construction, not this driver - otherwise the remaining, non-`vthis`
// steps run in the plan's own order, the same "no constructor" shape
// `planPositionalFields`'s own doc describes. Neither backend decides
// this order for itself any more; each supplies only the same `Hooks`
// `applyStep` takes, plus how to call the constructor - which stays a
// per-call argument since the two call sites genuinely differ here (a
// `NewExp`'s own constructor call vs. none for a `StructLiteralExp`).
public void driveInit(Hooks)(
    ref Hooks hooks,
    AggregateInitPlan plan,
    in bool hasConstructor,
    scope void delegate() callConstructor,
)
if (isAggregateInitHooks!Hooks)
{
    foreach (step; plan.steps)
        if (step.kind == InitStep.Kind.vthis)
            applyStep(hooks, step);

    if (hasConstructor) {
        callConstructor();
        return;
    }

    foreach (step; plan.steps)
        if (step.kind != InitStep.Kind.vthis)
            applyStep(hooks, step);
}

// The single decision both backends' `StructLiteralExp` adapters read:
// `expression.elements` pairs positionally with `expression.sd.fields`,
// with a `null` entry for a field the literal leaves out entirely.
public AggregateInitPlan planStructLiteral(
    imported!"dmd.expression".StructLiteralExp expression,
) {
    assert(expression.elements is null
        || expression.elements.length <= expression.sd.fields.length,
        "a struct literal has no more elements than fields");

    InitStep[] steps;

    // CTFE literals can include the hidden fields. Like dmd's e2ir, only
    // acquire an implicit context when those fields are absent.
    if (expression.elements is null
        || expression.elements.length != expression.sd.fields.length)
        steps ~= vthisStepsOf(expression.sd);

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
    auto steps = vthisStepsOf(sd);

    if (arguments !is null)
        foreach (i, argument; *arguments) {
            if (argument is null)
                continue;

            steps ~= fieldStep(sd.fields[i], argument);
        }

    return AggregateInitPlan(false, steps);
}

// The single decision both backends' heap `NewExp` adapters read for a
// class's own hidden context fields: empty for every `NewExp` but a nested
// class's own construction, one `vthis` step otherwise, and one more for
// the `vthis2` of a class with two contexts. dmd's semantic
// pass (`expressionsem.d`, `NewExp` semantic) synthesizes `thisexp` for
// the implicit `new Inner()` written inside a method the same way it
// resolves the explicit `outer.new Inner()`/`this.new Inner()` forms -
// walking `.outer` once per further nesting level - so both surface forms
// reach this plan identically through `classVthisStep`. A class nested in
// a *function* rather than a class never gets a `thisexp` at all - there
// is no outer object to name - so that case falls to the same
// `tryVthisStep` the struct paths above use, reading the enclosing
// function's own frame instead.
public AggregateInitPlan planClassContext(
    imported!"dmd.expression".NewExp expression,
) {
    auto classType = expression.newtype.isTypeClass;
    if (classType is null)
        return AggregateInitPlan.init;

    auto steps = vthisStepsOf(classType.sym, expression.thisexp);
    return steps.length == 0
        ? AggregateInitPlan.init : AggregateInitPlan(false, steps);
}

// `ad.isNested()` is true only when dmd gave the aggregate a hidden
// `vthis` field; a `static struct`/`static class` declared inside a
// function is lexically nested but has no such field. Shared by a nested
// struct's own construction and a nested *class*'s construction when it
// has no `thisexp` (nested in a function, not in another class) - both
// read the same enclosing function's frame the same way. An aggregate
// with two contexts has a `vthis2` field as well, which `setEthis` in
// dmd's code generator fills with the context of the instantiation scope.
// `thisexp`, when given, is the outer object of a nested class and fills
// `vthis` instead of the enclosing context.
private InitStep[] vthisStepsOf(
    imported!"dmd.aggregate".AggregateDeclaration ad,
    imported!"dmd.expression".Expression thisexp = null,
) {
    if (!ad.isNested() || ad.vthis is null)
        return null;

    InitStep[] steps;
    if (thisexp !is null)
        steps ~= classVthisStep(ad.isClassDeclaration, thisexp);
    else {
        steps ~= InitStep(InitStep.Kind.vthis, ad.vthis.offset);
        steps[0].contextOwner = ad.vthis2 is null
            ? ad.toParent2() : ad.toParentLocal();
    }

    if (ad.vthis2 !is null) {
        steps ~= InitStep(InitStep.Kind.vthis, ad.vthis2.offset);
        steps[1].contextOwner = ad.toParent2();
    }
    return steps;
}

// `thisexp`'s own static type can be a class *derived* from `cd`'s actual
// lexical parent - dmd allows constructing a class nested in a base class
// through a more-derived outer instance - so the pointer stored into
// `vthis` is not always `thisexp`'s own value unchanged. `classify` (the
// same plan an upcast `CastExp` builds) gives the identical byte offset
// dmd's own glue layer (`glue/e2ir.d`, `NewExp.thisexp` case) adds in that
// situation; when `thisexp`'s type already *is* the lexical parent, that
// offset comes back zero, so this needs no separate same-type case.
private InitStep classVthisStep(
    imported!"dmd.dclass".ClassDeclaration cd,
    imported!"dmd.expression".Expression thisexp,
)
in (cd.isNested() && cd.vthis !is null)
{
    import snakebite.backends.casts: classify;

    auto step = InitStep(
        InitStep.Kind.vthis, cd.vthis.offset, TypeFacts.pointer(),
        thisexp.type);
    step.source = thisexp;
    step.sourceAdjustment = classify(
        thisexp.type, cd.toParentLocal().isClassDeclaration().type,
    ).referenceOffset;
    return step;
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
            InitStep.Kind.bitfield, fieldOffset(field), facts, field.type);
        step.source = source;
        step.field = field;
        return step;
    }

    auto step = InitStep(InitStep.Kind.value, field.offset, facts, field.type);
    step.source = source;
    return step;
}
