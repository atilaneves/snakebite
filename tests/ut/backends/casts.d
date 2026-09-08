module ut.backends.casts;


import ut;
import dmd.expression: CastExp;
import dmd.func: FuncDeclaration;
import snakebite.backends.casts: classify, Kind;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction, typeFunctionOf;


// `classify` is a pure function of a `CastExp`'s source and destination
// types, decided once and read by both backends the way `ut.ffi.plan`
// pins `PlanCache` and `ut.ffi.call` pins `CallAdapter`.
private CastExp castOf(FuncDeclaration function_) {
    auto statements = function_.fbody.isCompoundStatement.statements;
    assert(statements !is null && statements.length == 1,
        "Expected one statement in the function");
    auto return_ = (*statements)[0].isReturnStatement;
    assert(return_ !is null, "Expected a return statement");
    auto cast_ = return_.exp.isCastExp;
    assert(cast_ !is null, "Expected the return expression to be a cast");
    return cast_;
}


private FuncDeclaration castFunctionOf(string body_) {
    auto module_ = parseSnippet(body_);
    auto function_ = findFunction(module_, "cast_");
    assert(function_ !is null, "No function `cast_` in the guest program");
    return function_;
}


@("kind.narrow")
unittest {
    auto function_ = castFunctionOf(q{
        int cast_(long value) { return cast(int) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == Kind.narrow;
    plan.sourceFacts.size.should == long.sizeof;
    plan.destFacts.size.should == int.sizeof;
}


@("kind.widenUnsigned")
unittest {
    auto function_ = castFunctionOf(q{
        ulong cast_(uint value) { return cast(ulong) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == Kind.widenUnsigned;
}


@("kind.widenSigned")
unittest {
    auto function_ = castFunctionOf(q{
        long cast_(int value) { return cast(long) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == Kind.widenSigned;
}


@("kind.toBool")
unittest {
    auto function_ = castFunctionOf(q{
        bool cast_(int value) { return cast(bool) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == Kind.toBool;
}


@("kind.copy.equalWidthIntegral")
unittest {
    auto function_ = castFunctionOf(q{
        uint cast_(int value) { return cast(uint) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == Kind.copy;
}


@("kind.pointerToIntegral")
unittest {
    auto function_ = castFunctionOf(q{
        ulong cast_(int* value) { return cast(ulong) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == Kind.pointerToIntegral;
}


// `xs.ptr` on a static array collapses to a plain address in dmd's own
// AST whenever it can compute one directly (a local, a global, a field
// reached through a pointer), leaving no `CastExp` for `classify` to see
// - the same shape a covariant return or an indirect call site can still
// hand this cast, so `classify` is exercised directly on the two
// parameter types a real one would carry instead.
@("kind.sarrayToPointer")
unittest {
    auto module_ = parseSnippet(q{
        void shapes_(int[3] source, int* dest) {}
    });
    auto function_ = findFunction(module_, "shapes_");
    assert(function_ !is null, "No function `shapes_` in the guest program");
    auto parameters = typeFunctionOf(function_).parameterList;

    const plan = classify(parameters[0].type, parameters[1].type);

    plan.kind.should == Kind.sarrayToPointer;
}


@("kind.sliceToPointer")
unittest {
    auto function_ = castFunctionOf(q{
        int* cast_(int[] value) { return cast(int*) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == Kind.sliceToPointer;
}


@("kind.reinterpretSlice")
unittest {
    auto function_ = castFunctionOf(q{
        void[] cast_(int[] value) { return cast(void[]) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == Kind.reinterpretSlice;
    plan.sourceFacts.elementSize.should == int.sizeof;
    plan.destFacts.elementSize.should == 1;
}


@("kind.floatWidth")
unittest {
    auto function_ = castFunctionOf(q{
        double cast_(float value) { return cast(double) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == Kind.floatWidth;
}


@("kind.integralToFloat")
unittest {
    auto function_ = castFunctionOf(q{
        double cast_(int value) { return cast(double) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == Kind.integralToFloat;
}


@("kind.floatToIntegral")
unittest {
    auto function_ = castFunctionOf(q{
        int cast_(double value) { return cast(int) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == Kind.floatToIntegral;
}


// dmd's semantic pass leaves a class cast unlowered only when the
// destination is a base of the source (`expressionsem.lowerCastExp`):
// here a cast to an interface the class implements. Every other class
// cast - a downcast, a cast to an unrelated interface - is lowered to
// `_d_cast` and never classified at all.
@("kind.classReference")
unittest {
    auto function_ = castFunctionOf(q{
        interface Shape {}
        class Circle : Shape {}

        Shape cast_(Circle value) { return cast(Shape) value; }
    });
    auto cast_ = castOf(function_);
    (cast_.lowering is null).should == true;

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == Kind.classReference;
}
