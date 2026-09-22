module ut.backends.aggregateinit;


import ut;
import dmd.expression: Expression, NewExp, StructLiteralExp;
import snakebite.backends.aggregateinit:
    InitStep, planPositionalFields, planStructLiteral;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;


// `planStructLiteral`/`planPositionalFields` are pure functions of a
// `StructLiteralExp`/`NewExp` and its `StructDeclaration`, decided once
// and read by both backends the way `ut.backends.casts` pins `classify`'s
// `CastExp` counterpart.
private Expression returnExpOf(string body_) {
    auto module_ = parseSnippet(body_);
    auto function_ = findFunction(module_, "make");
    assert(function_ !is null, "No function `make` in the guest program");
    assert(function_.returns !is null && function_.returns.length == 1,
        "Expected one return statement in the function");
    return (*function_.returns)[0].exp;
}

private StructLiteralExp structLiteralOf(string body_) {
    auto literal = returnExpOf(body_).isStructLiteralExp;
    assert(literal !is null,
        "Expected the return expression to be a struct literal");
    return literal;
}

private NewExp newOf(string body_) {
    auto new_ = returnExpOf(body_).isNewExp;
    assert(new_ !is null, "Expected the return expression to be `new`");
    return new_;
}


@("structLiteral.value")
unittest {
    auto literal = structLiteralOf(q{
        struct Point { int x; int y; }
        Point make(int a, int b) { return Point(a, b); }
    });

    const plan = planStructLiteral(literal);

    plan.zeroFill.should == true;
    plan.steps.length.should == 2;
    plan.steps[0].kind.should == InitStep.Kind.value;
    plan.steps[0].offset.should == 0;
    plan.steps[0].facts.size.should == int.sizeof;
    plan.steps[1].kind.should == InitStep.Kind.value;
    plan.steps[1].offset.should == int.sizeof;
}


@("structLiteral.bitfield")
unittest {
    auto literal = structLiteralOf(q{
        struct Flags { uint a : 4; uint b : 4; }
        Flags make(uint x, uint y) { return Flags(x, y); }
    });

    const plan = planStructLiteral(literal);

    plan.steps.length.should == 2;
    plan.steps[0].kind.should == InitStep.Kind.bitfield;
    (plan.steps[0].field !is null).should == true;
    plan.steps[1].kind.should == InitStep.Kind.bitfield;
}


@("structLiteral.broadcast")
unittest {
    auto literal = structLiteralOf(q{
        struct Inner { int x = 5; }
        struct Outer { int a; Inner[3] inners; }
        Outer make(int a) { return Outer(a); }
    });

    const plan = planStructLiteral(literal);

    plan.steps.length.should == 2;
    plan.steps[0].kind.should == InitStep.Kind.value;
    plan.steps[1].kind.should == InitStep.Kind.broadcast;
    plan.steps[1].count.should == 3;
    plan.steps[1].facts.size.should == int.sizeof;
}


@("structLiteral.vthis")
unittest {
    // `Nested` captures `captured` through its own method, so dmd gives
    // it a hidden `vthis` field: the literal's plan must fill it, ahead
    // of the two ordinary fields.
    auto literal = structLiteralOf(q{
        auto make(int a) {
            int captured = a;
            struct Nested {
                int x;
                int y;
                int read() { return captured; }
            }
            return Nested(a, a);
        }
    });

    const plan = planStructLiteral(literal);

    plan.steps.length.should == 3;
    plan.steps[0].kind.should == InitStep.Kind.vthis;
    (plan.steps[0].parentFunction !is null).should == true;
    plan.steps[1].kind.should == InitStep.Kind.value;
    plan.steps[2].kind.should == InitStep.Kind.value;
}


@("positionalFields.zeroFillIsFalse")
unittest {
    auto new_ = newOf(q{
        struct Point { int x; int y; }
        Point* make(int a, int b) { return new Point(a, b); }
    });

    auto structType = new_.newtype.isTypeStruct;
    assert(structType !is null, "Expected `new` of a struct type");

    const plan = planPositionalFields(structType.sym, new_.arguments);

    plan.zeroFill.should == false;
    plan.steps.length.should == 2;
    plan.steps[0].kind.should == InitStep.Kind.value;
    plan.steps[1].kind.should == InitStep.Kind.value;
}


@("positionalFields.omittedZeroSizeFieldIsSkipped")
unittest {
    // `value` is a zero-size field (`void[0]`), always omitted from a
    // `new Entry(a)` call with no matching argument. dmd's own `fill`
    // (`expressionsem.d`) still pads `new_.arguments` out to one entry
    // per non-hidden field, but stores `null` for an omitted zero-size
    // field rather than a default-initializer expression: there is
    // nothing to evaluate, so the plan must skip it instead of crashing
    // on a null `source`.
    auto new_ = newOf(q{
        struct Entry { int key; void[0] value; }
        Entry* make(int a) { return new Entry(a); }
    });

    auto structType = new_.newtype.isTypeStruct;
    assert(structType !is null, "Expected `new` of a struct type");

    const plan = planPositionalFields(structType.sym, new_.arguments);

    plan.zeroFill.should == false;
    plan.steps.length.should == 1;
    plan.steps[0].kind.should == InitStep.Kind.value;
    plan.steps[0].offset.should == 0;
}
