module ut.backends.call.routing;


// Whether a callee is interpreted or called natively is one decision,
// `Program.isInterpreted`: a callee owned by a root module is interpreted,
// any other callee runs as the native code this process links. These tests
// pin that ownership is the whole decision - not the callee's name, not
// its linkage, and not whether it has a body.


import ut.backends;
import snakebite.backends.backend: Program;
import snakebite.frontend.compiler: parseSnippet, parseSnippets;
import snakebite.frontend.dmd.functions: findFunction;
import std.algorithm.searching: canFind, startsWith;


// A root-owned declaration whose name copies druntime's `_d_*` convention
// is still root-owned, so it is interpreted. No native symbol for it
// exists in this process, so answering 42 at all is only possible by
// walking its body - a name-based rule sending `_d_*` spellings to native
// execution could not.
static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("rootOwned.underscoreDName." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                int _d_rootPretender() { return 42; }
                int answer() { return _d_rootPretender(); }
            },
            "answer",
        );
    }
}


// A callee in a module outside `Program.rootModules` is executed
// natively even though it has `extern(D)` linkage and a body the
// interpreter could walk. No native build of `routing_helper` exists, so
// the call must fail at the FFI boundary, naming the symbol it needed -
// walking the body instead would answer 42 and pass silently.
@("nonRootOwned.bodyIsNotWalked.Interpreter")
@Tags("Interpreter")
unittest {
    auto modules = parseSnippets([
        q{
            module routing_root;
            import routing_helper;
            int answer() { return fortyTwo(); }
        },
        q{
            module routing_helper;
            int fortyTwo() { return 42; }
        },
    ]);
    auto program = Program([modules[0]]);
    auto function_ = findFunction(modules[0], "answer");

    int result;
    const thrown = (new Interpreter(program))
        .call(function_, &result, [])
        .shouldThrow;

    thrown.msg.startsWith("ffi cannot resolve the symbol").should == true;
}


// `arr ~= element` is lowered by dmd's own semantic pass to druntime's
// `_d_arrayappendcTX`, the hook that resizes the array - a template
// declared by `core.internal.array.appending`, never by the program, so
// it is executed natively by ownership even though its name starts with
// `_d_` and its body is available to walk. The element type here is
// declared only by the guest, so no native instantiation of the hook
// exists in this process and the call must fail at the FFI boundary,
// naming the hook's symbol - walking its body instead would grow the
// array and pass silently. (Growing an `int[]` the same way succeeds
// through the native hook: `arrays.append.element.Interpreter` and its
// siblings.)
@("nonRootOwned.druntimeResizeHelper.Interpreter")
@Tags("Interpreter")
unittest {
    auto module_ = parseSnippet(q{
        struct OnlyInTheGuest { int value; }

        size_t grown() {
            OnlyInTheGuest[] a;
            a ~= OnlyInTheGuest(42);
            return a.length;
        }
    });
    auto function_ = findFunction(module_, "grown");

    size_t result;
    const thrown = interpreter(module_)
        .call(function_, &result, [])
        .shouldThrow;

    thrown.msg.startsWith("ffi cannot resolve the symbol").should == true;
    thrown.msg.canFind("_d_arrayappendcTX").should == true;
}
