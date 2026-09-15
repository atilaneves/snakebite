module at.ffi.dvariadic;


import unit_threaded;
import snakebite.backends.backend: Program;
import snakebite.backends.bytecode: Bytecode;
import snakebite.backends.interpreter: Interpreter;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;


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
// This same shape - one declared `struct` parameter, then extras of
// `int` and `struct` type, `_arguments` checked from inside the callee -
// also runs as a `bin/ut` test (`tests/ut/backends/call/ffi.d`'s own
// `variadic.externD.lengthFirstTypeAndSums`), with an otherwise
// identical callee dmd builds instead: dmd's own `_arguments` shape (one
// pointer to the `TypeInfo_Tuple`) is unaffected by this step, so that
// test already covers the dmd host without needing ldc2 to build it.
private struct AtVariadicPoint {
    int x;
    int y;
}


pragma(mangle, "snakebite_at_dvariadic_probe")
private extern(D) int snakebite_at_dvariadic_probe(
    AtVariadicPoint point, ...
) {
    import core.vararg;

    assert(_arguments.length == 3, "wrong _arguments.length");
    assert(_arguments[0] is typeid(int), "wrong _arguments[0]");

    int total = point.x + point.y;
    foreach (i; 0 .. _arguments.length) {
        if (_arguments[i] is typeid(int))
            total += va_arg!int(_argptr);
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

    pragma(mangle, "snakebite_at_dvariadic_probe")
    extern(D) int probe(GuestPoint point, ...);

    int answer() {
        GuestPoint point;
        point.x = 3;
        point.y = 4;
        GuestPoint extra;
        extra.x = 5;
        extra.y = 6;
        return probe(point, 1, 2, extra);
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
