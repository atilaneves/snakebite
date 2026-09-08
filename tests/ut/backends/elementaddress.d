module ut.backends.elementaddress;


import ut;
import dmd.expression: Expression, IndexExp, SliceExp;
import snakebite.backends.elementaddress: BaseKind, classify, LengthSource;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;


// `classify` is a pure function of an `IndexExp`/`SliceExp`'s own
// `e1.type`, decided once and read by both backends the way
// `ut.backends.casts` pins `classify`'s `CastExp` counterpart.
private Expression returnExpOf(string body_) {
    auto module_ = parseSnippet(body_);
    auto function_ = findFunction(module_, "element_");
    assert(function_ !is null, "No function `element_` in the guest program");
    auto statements = function_.fbody.isCompoundStatement.statements;
    assert(statements !is null && statements.length == 1,
        "Expected one statement in the function");
    auto return_ = (*statements)[0].isReturnStatement;
    assert(return_ !is null, "Expected a return statement");
    return return_.exp;
}

private IndexExp indexOf(string body_) {
    auto index = returnExpOf(body_).isIndexExp;
    assert(index !is null, "Expected the return expression to be an index");
    return index;
}

private SliceExp sliceOf(string body_) {
    auto slice = returnExpOf(body_).isSliceExp;
    assert(slice !is null, "Expected the return expression to be a slice");
    return slice;
}


@("base.dynamicArray")
unittest {
    auto index = indexOf(q{
        int element_(int[] value, size_t i) { return value[i]; }
    });

    const plan = classify(index.e1.type);

    plan.base.should == BaseKind.dynamicArray;
    plan.length.should == LengthSource.runtimeWord;
    plan.elementFacts.size.should == int.sizeof;
}


@("base.staticArray")
unittest {
    auto index = indexOf(q{
        int element_(int[3] value, size_t i) { return value[i]; }
    });

    const plan = classify(index.e1.type);

    plan.base.should == BaseKind.staticArray;
    plan.length.should == LengthSource.staticDimension;
    plan.staticLength.should == 3;
    plan.elementFacts.size.should == int.sizeof;
}


@("base.pointer")
unittest {
    auto index = indexOf(q{
        int element_(int* value, size_t i) { return value[i]; }
    });

    const plan = classify(index.e1.type);

    plan.base.should == BaseKind.pointer;
    plan.length.should == LengthSource.none;
    plan.elementFacts.size.should == int.sizeof;
}


@("base.dynamicArray.slice")
unittest {
    auto slice = sliceOf(q{
        int[] element_(int[] value, size_t lo, size_t hi) {
            return value[lo .. hi];
        }
    });

    const plan = classify(slice.e1.type);

    plan.base.should == BaseKind.dynamicArray;
    plan.length.should == LengthSource.runtimeWord;
}
