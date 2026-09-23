module ut.backends.casts;


import ut;
import dmd.expression: CastExp;
import dmd.func: FuncDeclaration;
import snakebite.backends.casts: classify, CastPlan;
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

    plan.kind.should == CastPlan.Kind.narrow;
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

    plan.kind.should == CastPlan.Kind.widenUnsigned;
}


@("kind.widenSigned")
unittest {
    auto function_ = castFunctionOf(q{
        long cast_(int value) { return cast(long) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.widenSigned;
}


@("kind.toBool")
unittest {
    auto function_ = castFunctionOf(q{
        bool cast_(int value) { return cast(bool) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.toBool;
}


@("kind.copy.equalWidthIntegral")
unittest {
    auto function_ = castFunctionOf(q{
        uint cast_(int value) { return cast(uint) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.copy;
}


@("kind.pointerToIntegral")
unittest {
    auto function_ = castFunctionOf(q{
        ulong cast_(int* value) { return cast(ulong) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.pointerToIntegral;
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

    plan.kind.should == CastPlan.Kind.copy;
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

    plan.kind.should == CastPlan.Kind.widenSigned;
}


@("kind.widenUnsigned.uintToPointer")
unittest {
    auto function_ = castFunctionOf(q{
        void* cast_(uint value) { return cast(void*) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.widenUnsigned;
}


// `cast(bool)` on a pointer is a dmd frontend-legal cast (unlike a class
// reference or a delegate, both of which dmd itself refuses to cast to
// `bool`), and tests the same nonzero bytes `kind.toBool`'s integral
// operand already does.
@("kind.toBool.pointer")
unittest {
    auto function_ = castFunctionOf(q{
        bool cast_(int* value) { return cast(bool) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.toBool;
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

    plan.kind.should == CastPlan.Kind.sarrayToPointer;
}


@("kind.sliceToPointer")
unittest {
    auto function_ = castFunctionOf(q{
        int* cast_(int[] value) { return cast(int*) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.sliceToPointer;
}


@("kind.reinterpretSlice")
unittest {
    auto function_ = castFunctionOf(q{
        void[] cast_(int[] value) { return cast(void[]) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.reinterpretSlice;
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

    plan.kind.should == CastPlan.Kind.floatWidth;
}


@("kind.integralToFloat")
unittest {
    auto function_ = castFunctionOf(q{
        double cast_(int value) { return cast(double) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.integralToFloat;
}


@("kind.floatToIntegral")
unittest {
    auto function_ = castFunctionOf(q{
        int cast_(double value) { return cast(int) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.floatToIntegral;
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

    plan.kind.should == CastPlan.Kind.classReference;
}


// An associative array is one pointer-sized handle natively, the same
// shape a class reference already gets `copy` for at the equivalent
// `Tclass`-`Tpointer` pair above - `source/dub/internal/undead/xml.d`'s
// `Tag.opCmp` casts a `const(string[string])` field to `void*` to compare
// two AAs by handle identity (issue: bytecode compiler rejected this cast
// outright).
@("kind.copy.aaToPointer")
unittest {
    auto function_ = castFunctionOf(q{
        void* cast_(int[int] value) { return cast(void*) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.copy;
}


// The reverse of `kind.copy.aaToPointer`: dmd accepts `cast(int[int])
// somePointer` the same way it accepts `cast(void*) someAA` - both sides
// of the pointer-sized handle are `Tpointer`/`Taarray`, so the same
// bit-preserving `copy` applies.
@("kind.copy.pointerToAA")
unittest {
    auto function_ = castFunctionOf(q{
        int[int] cast_(void* value) { return cast(int[int]) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.copy;
}


// `cast(void*) someDelegate` is deprecated (superseded by `.ptr`) but
// still accepted by dmd's frontend, which keeps only the delegate's
// context word - unlike `cast(bool)`/`cast(size_t)` on a delegate, both
// of which dmd's frontend refuses outright, or the reverse direction
// (`cast(SomeDelegate) somePointer`), which dmd also refuses.
@("kind.delegateToPointer")
unittest {
    auto function_ = castFunctionOf(q{
        void* cast_(void delegate() value) { return cast(void*) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.delegateToPointer;
}


// `complex`/`imaginary` are deprecated but still full members of the
// language `classify` has to answer for (coordinator probe items 1-5, 8).
@("kind.complexToBool")
unittest {
    auto function_ = castFunctionOf(q{
        bool cast_(cdouble value) { return cast(bool) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.complexToBool;
}


@("kind.complexToReal")
unittest {
    auto function_ = castFunctionOf(q{
        double cast_(cdouble value) { return cast(double) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.complexToReal;
}


// `someComplex.im`: dmd's own semantic pass (`typesem.d`'s `Id.im` case
// for `Tcomplex64`) builds `e.castTo(sc, idouble)` and then overwrites
// the resulting node's own `.type` straight to `double` - `.to` still
// names the cast actually performed, which is what `classify` has to
// see here (both backends' `compileCast`/`visitUnloweredCast` prefer
// `.to` over `.type` for exactly this reason).
@("kind.complexToImaginary")
unittest {
    auto function_ = castFunctionOf(q{
        idouble cast_(cdouble value) { return cast(idouble) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.complexToImaginary;
}


@("kind.complexToIntegral")
unittest {
    auto function_ = castFunctionOf(q{
        int cast_(cdouble value) { return cast(int) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.complexToIntegral;
}


@("kind.complexWidth")
unittest {
    auto function_ = castFunctionOf(q{
        cfloat cast_(creal value) { return cast(cfloat) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.complexWidth;
}


@("kind.realToComplex")
unittest {
    auto function_ = castFunctionOf(q{
        cdouble cast_(double value) { return cast(cdouble) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.realToComplex;
}


@("kind.integralToComplex")
unittest {
    auto function_ = castFunctionOf(q{
        cdouble cast_(int value) { return cast(cdouble) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.integralToComplex;
}


@("kind.imaginaryToComplex")
unittest {
    auto function_ = castFunctionOf(q{
        cdouble cast_(idouble value) { return cast(cdouble) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.imaginaryToComplex;
}


// A real value has no imaginary axis to carry over - dmd's own constant
// folding (`toImaginary`) answers `0` regardless of the real value, the
// same answer a side-effect-preserving zero fill gives at run time.
@("kind.zero.realToImaginary")
unittest {
    auto function_ = castFunctionOf(q{
        idouble cast_(double value) { return cast(idouble) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.zero;
}


// The reverse of `kind.zero.realToImaginary`: an imaginary value has no
// real axis either.
@("kind.zero.imaginaryToReal")
unittest {
    auto function_ = castFunctionOf(q{
        double cast_(idouble value) { return cast(double) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.zero;
}


@("kind.zero.integralToImaginary")
unittest {
    auto function_ = castFunctionOf(q{
        idouble cast_(int value) { return cast(idouble) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.zero;
}


@("kind.zero.imaginaryToIntegral")
unittest {
    auto function_ = castFunctionOf(q{
        int cast_(idouble value) { return cast(int) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.zero;
}


// An imaginary-to-imaginary width change is the identical byte operation
// a `float`-to-`double` one is - just the imaginary operand's own size.
@("kind.floatWidth.imaginaryToImaginary")
unittest {
    auto function_ = castFunctionOf(q{
        idouble cast_(ifloat value) { return cast(idouble) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.floatWidth;
}


// An imaginary value's own nonzero test is the identical byte operation
// a real operand's `cast(bool)` already is.
@("kind.floatToBool.imaginaryToBool")
unittest {
    auto function_ = castFunctionOf(q{
        bool cast_(idouble value) { return cast(bool) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.floatToBool;
}


// dmd's own `dcast.d` (bugzilla 3133) reinterprets two equal-size "fat
// values" - a `struct`, a static array, a vector - into one another once
// no constructor rewrite claims a `struct` destination first (coordinator
// probe item 7): `cast(ubyte[S.sizeof]) someS` has no matching
// constructor to rewrite to, so it is a genuine bit reinterpret by the
// time it reaches `classify`.
@("kind.copy.structToSarray")
unittest {
    auto function_ = castFunctionOf(q{
        struct S { int x; int y; }
        long[1] cast_(S value) { return cast(long[1]) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.copy;
}


@("kind.copy.sarrayToStruct")
unittest {
    auto function_ = castFunctionOf(q{
        struct S { int x; int y; }
        S cast_(int[2] value) { return cast(S) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.copy;
}


@("kind.copy.sarrayToSarray")
unittest {
    auto function_ = castFunctionOf(q{
        ubyte[8] cast_(int[2] value) { return cast(ubyte[8]) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.copy;
}


@("kind.copy.vectorToSarray")
unittest {
    auto function_ = castFunctionOf(q{
        import core.simd;
        int[4] cast_(int4 value) { return cast(int[4]) value; }
    });
    auto cast_ = castOf(function_);

    const plan = classify(cast_.e1.type, cast_.type);

    plan.kind.should == CastPlan.Kind.copy;
}
