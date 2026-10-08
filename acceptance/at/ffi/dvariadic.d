module at.ffi.dvariadic;


import unit_threaded;
import snakebite.backends.backend: Program;
import snakebite.backends.bytecode: Bytecode;
import snakebite.backends.interpreter: Interpreter;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;


private alias DVariadicCallback = extern(D) int function(int, ...);

pragma(mangle, "snakebite_at_invoke_dvariadic_callback")
private extern(C) int invokeDVariadicCallback(
    DVariadicCallback callback,
) {
    return callback(10, 32);
}


// `bin/at` is built with ldc2 (`reggaefile.d`'s own `dubTarget` call for
// the `"at"` output), unlike `bin/ut`, which dmd builds - so this callee
// is the one place in this project's own test suites an `extern(D)`
// untyped variadic callee's hidden `_arguments` argument actually
// reaches ldc2's own ABI (`snakebite.ffi.abi.dVariadicArgumentsIsSlice`'s
// own doc): ldc2's codegen passes it as a two-register `TypeInfo[]`
// slice, not the one pointer dmd's codegen passes, so a plan that got
// that shape wrong would either read garbage out of `_arguments` here,
// or misplace the struct extra argument that follows it in the integer
// register file - not silently pass.
//
// The unit tests cover the DMD host. A vector extra here also checks that
// LDC's druntime reads the full XMM register through guest TypeInfo.
private struct AtVariadicPoint {
    int x;
    int y;
}


pragma(mangle, "snakebite_at_dvariadic_probe")
private extern(D) int snakebite_at_dvariadic_probe(
    AtVariadicPoint point, ...
) {
    import core.vararg;

    assert(_arguments.length == 4, "wrong _arguments.length");
    assert(_arguments[0] is typeid(int), "wrong _arguments[0]");

    int total = point.x + point.y;
    foreach (i; 0 .. _arguments.length) {
        if (_arguments[i] is typeid(int))
            total += va_arg!int(_argptr);
        else if (_arguments[i].tsize == 16) {
            double[2] lanes = [-1.0, -1.0];
            va_arg(_argptr, _arguments[i], lanes.ptr);
            assert(lanes[0] == 3.0 && lanes[1] == 17.0);
        }
        else {
            AtVariadicPoint extra;
            va_arg(_argptr, _arguments[i], &extra);
            total += extra.x + extra.y;
        }
    }
    return total;
}


private enum snippet = q{
    struct GuestPoint {
        int x;
        int y;
    }
    struct VectorValue { __vector(double[2]) lanes; }

    pragma(mangle, "snakebite_at_dvariadic_probe")
    extern(D) int probe(GuestPoint point, ...);

    int answer() {
        GuestPoint point;
        point.x = 3;
        point.y = 4;
        GuestPoint extra;
        extra.x = 5;
        extra.y = 6;
        VectorValue vector;
        vector.lanes.array[0] = 3.0;
        vector.lanes.array[1] = 17.0;
        return probe(point, 1, 2, extra, vector);
    }
};


private enum callbackSnippet = q{
    import core.vararg;

    alias Callback = extern(D) int function(int, ...);
    pragma(mangle, "snakebite_at_invoke_dvariadic_callback")
    extern(C) int invokeDVariadicCallback(Callback callback);

    int guest(int fixed, ...) {
        assert(_arguments.length == 1, "wrong callback _arguments.length");
        assert(_arguments[0] is typeid(int), "wrong callback _arguments[0]");
        return fixed + va_arg!int(_argptr);
    }

    int answer() {
        return invokeDVariadicCallback(&guest);
    }
};


@("dVariadicSliceOnLdcHost.Interpreter")
@Tags("Interpreter")
unittest {
    auto module_ = parseSnippet(snippet);
    auto function_ = findFunction(module_, "answer");
    assert(function_ !is null, "No `answer` in the guest program");

    int result;
    new Interpreter(Program([module_])).call(function_, &result, []);

    // point (3 + 4) + extras 1 + 2 + extra struct (5 + 6).
    result.should == 21;
}


@("dVariadicCallbackSliceOnLdcHost.Interpreter")
@Tags("Interpreter")
unittest {
    auto module_ = parseSnippet(callbackSnippet);
    auto function_ = findFunction(module_, "answer");
    assert(function_ !is null, "No `answer` in the guest program");

    int result;
    new Interpreter(Program([module_])).call(function_, &result, []);
    result.should == 42;
}


@("dVariadicCallbackSliceOnLdcHost.Bytecode")
@Tags("Bytecode")
unittest {
    auto module_ = parseSnippet(callbackSnippet);
    auto function_ = findFunction(module_, "answer");
    assert(function_ !is null, "No `answer` in the guest program");

    int result;
    new Bytecode(Program([module_])).call(function_, &result, []);
    result.should == 42;
}


@("dVariadicSliceOnLdcHost.Bytecode")
@Tags("Bytecode")
unittest {
    auto module_ = parseSnippet(snippet);
    auto function_ = findFunction(module_, "answer");
    assert(function_ !is null, "No `answer` in the guest program");

    int result;
    new Bytecode(Program([module_])).call(function_, &result, []);

    // point (3 + 4) + extras 1 + 2 + extra struct (5 + 6).
    result.should == 21;
}
