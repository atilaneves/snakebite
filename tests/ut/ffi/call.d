module ut.ffi.call;


import ut;
import snakebite.ffi: CallAdapter;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction, findStruct, typeFunctionOf;


// `CallAdapter` is a pure function of a declaration's or a bare
// `TypeFunction`'s own dmd facts, decided once and read by both backends -
// the bytecode compiler for the return place it reserves at a call site,
// the interpreter for the return place it fills at run time. These pin
// that one decision directly, the way `ut.ffi.plan` pins `PlanCache`.
@("returnShape.value")
unittest {
    auto module_ = parseSnippet(q{
        int addOne(int value) { return value + 1; }
    });
    auto function_ = findFunction(module_, "addOne");
    assert(function_ !is null, "No function `addOne` in the guest program");

    const shape = CallAdapter.of(function_);

    shape.isVoid.should == false;
    shape.isReferenceResult.should == false;
    shape.returnFacts.size.should == int.sizeof;
}


@("returnShape.reference")
unittest {
    auto module_ = parseSnippet(q{
        ref int identity(ref int value) { return value; }
    });
    auto function_ = findFunction(module_, "identity");
    assert(function_ !is null, "No function `identity` in the guest program");

    const shape = CallAdapter.of(function_);

    shape.isVoid.should == false;
    shape.isReferenceResult.should == true;
    // A `ref` return's own place holds the result's address, always
    // pointer-sized regardless of the pointee's own width.
    shape.returnFacts.size.should == size_t.sizeof;
}


@("returnShape.void")
unittest {
    auto module_ = parseSnippet(q{
        void discard(int value) {}
    });
    auto function_ = findFunction(module_, "discard");
    assert(function_ !is null, "No function `discard` in the guest program");

    const shape = CallAdapter.of(function_);

    shape.isVoid.should == true;
}


@("returnShape.constructorIsVoidEvenThoughItConstructsAValue")
unittest {
    auto module_ = parseSnippet(q{
        struct S {
            int value;
            this(int value) { this.value = value; }
        }
    });
    auto struct_ = findStruct(module_, "S");
    assert(struct_ !is null, "No struct `S` in the guest program");
    auto ctor = findFunction(struct_, "__ctor");
    assert(ctor !is null, "No constructor found on `S`");

    const shape = CallAdapter.of(ctor);

    // A constructor never returns a value into a call site's own return
    // place - what it "returns" is the receiver the caller already holds
    // the address of - so its own call shape is void regardless of what
    // running it accomplishes.
    shape.isVoid.should == true;
}


@("argument.refIsAddress")
unittest {
    auto module_ = parseSnippet(q{
        void takesRef(ref int value) {}
    });
    auto function_ = findFunction(module_, "takesRef");
    assert(function_ !is null, "No function `takesRef` in the guest program");

    auto parameter = typeFunctionOf(function_).parameterList[0];
    CallAdapter.Argument.of(parameter).isReference.should == true;
}


@("argument.outIsAddress")
unittest {
    auto module_ = parseSnippet(q{
        void takesOut(out int value) {}
    });
    auto function_ = findFunction(module_, "takesOut");
    assert(function_ !is null, "No function `takesOut` in the guest program");

    auto parameter = typeFunctionOf(function_).parameterList[0];
    CallAdapter.Argument.of(parameter).isReference.should == true;
}


@("argument.valueIsNotAddress")
unittest {
    auto module_ = parseSnippet(q{
        void takesValue(int value) {}
    });
    auto function_ = findFunction(module_, "takesValue");
    assert(function_ !is null, "No function `takesValue` in the guest program");

    auto parameter = typeFunctionOf(function_).parameterList[0];
    CallAdapter.Argument.of(parameter).isReference.should == false;
}


// `lazy` is not address-passing at the ABI boundary this adapter decides
// between: it is dmd's own implicit delegate, a value the caller
// evaluates and stores like any other, never the argument's own address.
@("argument.lazyIsNotAddress")
unittest {
    auto module_ = parseSnippet(q{
        void takesLazy(lazy int value) {}
    });
    auto function_ = findFunction(module_, "takesLazy");
    assert(function_ !is null, "No function `takesLazy` in the guest program");

    auto parameter = typeFunctionOf(function_).parameterList[0];
    CallAdapter.Argument.of(parameter).isReference.should == false;
}
