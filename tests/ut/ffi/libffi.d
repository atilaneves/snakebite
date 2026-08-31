module ut.ffi.libffi;


import ut;
import snakebite.ffi: LibffiPlan;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;


private extern(C) int snakebite_ut_libffi_abs(int value) {
    return value < 0 ? -value : value;
}

private extern(C) double snakebite_ut_libffi_scale(double value) {
    return value * 2.5;
}

private extern(C) void snakebite_ut_libffi_throw() {
    throw new Exception("native FFI exception");
}

private struct Pair {
    int first;
    int second;
}

private extern(C) Pair snakebite_ut_libffi_pair(Pair value) {
    return Pair(value.first + 1, value.second + 2);
}

private void* planFor(string declaration, string name) {
    auto module_ = parseSnippet(declaration);
    auto function_ = findFunction(module_, name);
    assert(function_ !is null);
    return new LibffiPlan(function_);
}


@("called.scalar")
unittest {
    auto plan = cast(LibffiPlan*) planFor(
        "extern(C) int snakebite_ut_libffi_abs(int);",
        "snakebite_ut_libffi_abs",
    );
    int argument = -42;
    int result;
    plan.call(&result, [cast(const void*) &argument]);
    result.should == 42;
}


@("called.double")
unittest {
    auto plan = cast(LibffiPlan*) planFor(
        "extern(C) double snakebite_ut_libffi_scale(double);",
        "snakebite_ut_libffi_scale",
    );
    double argument = 1.5;
    double result;
    plan.call(&result, [cast(const void*) &argument]);
    result.should == 3.75;
}


@("called.smallStruct")
unittest {
    auto plan = cast(LibffiPlan*) planFor(
        q{
            struct Pair {
                int first;
                int second;
            }
            extern(C) Pair snakebite_ut_libffi_pair(Pair);
        },
        "snakebite_ut_libffi_pair",
    );
    Pair argument = Pair(39, 58);
    Pair result;
    plan.call(&result, [cast(const void*) &argument]);
    result.should == Pair(40, 60);
}


@("called.exceptionPropagates")
unittest {
    auto plan = cast(LibffiPlan*) planFor(
        "extern(C) void snakebite_ut_libffi_throw();",
        "snakebite_ut_libffi_throw",
    );
    plan.call(null, []).shouldThrowWithMessage("native FFI exception");
}
