module ut.ffi.callback;


import ut.backends;
import snakebite.ffi: CallbackSignature, LibffiCallback;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;


private alias IntFunction = extern(C) int function(int);
private alias DoubleFunction = extern(C) double function(double);


private extern(C) int invokeIntCallback(IntFunction callback, int value) {
    return callback(value);
}


private extern(C) double invokeDoubleCallback(
    DoubleFunction callback,
    double value,
) {
    return callback(value);
}


@("nativeToInterpreted.callbackReturnsGuestValue.Interpreter")
@Tags("Interpreter")
unittest {
    auto module_ = parseSnippet(q{
        int increment(int value) {
            return value + 1;
        }
    });
    auto function_ = findFunction(module_, "increment");
    auto backend = interpreter(module_);
    auto callback = backend.callback(function_);

    invokeIntCallback(cast(IntFunction) callback.functionPointer, 41)
        .should == 42;
}


@("nativeToInterpreted.libffiClosurePropagatesGuestException.Interpreter")
@Tags("Interpreter", "libffi")
unittest {
    auto module_ = parseSnippet(q{
        bool failCondition() {
            return false;
        }

        int fail(int value) {
            assert(failCondition());
            return 0;
        }
    });
    auto function_ = findFunction(module_, "fail");
    auto backend = interpreter(module_);
    auto callback = LibffiCallback(backend.callbackTarget(function_));

    Throwable caught;
    try
        invokeIntCallback(cast(IntFunction) callback.functionPointer, 41);
    catch (Throwable throwable)
        caught = throwable;

    assert(caught !is null);
    import core.exception: AssertError;
    caught.classinfo.name.should == AssertError.classinfo.name;
}


@("nativeToInterpreted.callbackSupportsDouble.Interpreter")
@Tags("Interpreter")
unittest {
    auto module_ = parseSnippet(q{
        double scale(double value) {
            return value * 2.5;
        }
    });
    auto function_ = findFunction(module_, "scale");
    auto backend = interpreter(module_);

    auto trampoline = backend.callback(function_);
    invokeDoubleCallback(cast(DoubleFunction) trampoline.functionPointer, 1.5)
        .should == 3.75;

    auto closure = LibffiCallback(
        backend.callbackTarget(function_),
        CallbackSignature.doubleToDouble,
    );
    invokeDoubleCallback(cast(DoubleFunction) closure.functionPointer, 1.5)
        .should == 3.75;
}


@("nativeToInterpreted.libffiClosureReturnsGuestValue.Interpreter")
@Tags("Interpreter", "libffi")
unittest {
    auto module_ = parseSnippet(q{
        int increment(int value) {
            return value + 1;
        }
    });
    auto function_ = findFunction(module_, "increment");
    auto backend = interpreter(module_);
    auto callback = LibffiCallback(backend.callbackTarget(function_));

    invokeIntCallback(cast(IntFunction) callback.functionPointer, 41)
        .should == 42;
}


@("nativeToInterpreted.callbackPropagatesGuestException.Interpreter")
@Tags("Interpreter")
unittest {
    auto module_ = parseSnippet(q{
        bool failCondition() {
            return false;
        }

        int fail(int value) {
            assert(failCondition());
            return 0;
        }
    });
    auto function_ = findFunction(module_, "fail");
    auto backend = interpreter(module_);
    auto callback = backend.callback(function_);

    Throwable caught;
    try
        invokeIntCallback(cast(IntFunction) callback.functionPointer, 41);
    catch (Throwable throwable)
        caught = throwable;

    assert(caught !is null);
    import core.exception: AssertError;
    caught.classinfo.name.should == AssertError.classinfo.name;
}
