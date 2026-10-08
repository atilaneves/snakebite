module ut.backends.casts;


import ut;
import dmd.expression: CastExp;
import dmd.func: FuncDeclaration;
import snakebite.backends.casts: classify;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction, typeFunctionOf;
import snakebite.nativevalue: CastKind;


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


@("kind.copy.equalWidthIntegral")
unittest {
    auto function_ = castFunctionOf(q{
        uint cast_(int value) { return cast(uint) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastKind.copy;
}


@("kind.pointerToIntegral")
unittest {
    auto function_ = castFunctionOf(q{
        ubyte cast_(int* value) { return cast(ubyte) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastKind.pointerToIntegral;
}


@("kind.pointerToFloat")
unittest {
    auto function_ = castFunctionOf(q{
        double cast_(int* value) { return cast(double) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastKind.pointerToFloat;
}


@("kind.floatToPointer")
unittest {
    auto function_ = castFunctionOf(q{
        int* cast_(double value) { return cast(int*) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastKind.floatToPointer;
}


@("kind.sarrayToVoidSliceLength")
unittest {
    auto function_ = castFunctionOf(q{
        int[2] values;
        void[] cast_() { return cast(void[]) values; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastKind.sarrayToSlice;
    plan.staticLength.should == 8;
}




// The reverse of `kind.pointerToIntegral`: `size_t` and a pointer are both
// `size_t.sizeof` bytes wide, so preserving the value's own bits across the
// cast is the same plain move `copy` already covers for two equal-width
// integrals - `alignUp`'s own `return cast(T) b;`, `core.stdc.stdarg`'s
// only cast from a `size_t` to its own type parameter (issue: `core/stdc/
// stdarg.d(69)`).
@("kind.copy.sizeTToPointer")
unittest {
    auto function_ = castFunctionOf(q{
        void* cast_(size_t value) { return cast(void*) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastKind.copy;
}


// A narrower integral cast to a pointer has to sign- or zero-extend into
// the pointer's own width first, exactly as widening that same operand to
// a wider integral would - the same `widenSigned`/`widenUnsigned` kinds an
// integral destination already uses.
@("kind.widenSigned.intToPointer")
unittest {
    auto function_ = castFunctionOf(q{
        void* cast_(int value) { return cast(void*) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastKind.widenSigned;
}


@("kind.widenUnsigned.uintToPointer")
unittest {
    auto function_ = castFunctionOf(q{
        void* cast_(uint value) { return cast(void*) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastKind.widenUnsigned;
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

    plan.kind.should == CastKind.sarrayToPointer;
}


@("kind.integralToFloat")
unittest {
    auto function_ = castFunctionOf(q{
        double cast_(int value) { return cast(double) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastKind.integralToFloat;
}


@("kind.complexToIntegral")
unittest {
    auto function_ = castFunctionOf(q{
        int cast_(cdouble value) { return cast(int) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastKind.complexToIntegral;
}
