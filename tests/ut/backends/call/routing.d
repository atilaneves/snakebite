module ut.backends.call.routing;


// A root-owned callee is interpreted. A non-root declaration uses native
// code when that code exists; a synthesized template instance with no native
// symbol uses the exact body DMD produced for it. Names and packages do not
// decide how a call runs.


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


// The guest-only element type means no native `_d_arrayappendcTX` instance
// can exist. DMD did synthesize its body, so the interpreter enters it and
// reaches the guest struct's TypeInfo. That TypeInfo has no native symbol
// either. The later refusal proves the missing template did not fail at the
// FFI boundary, without requiring this test to expand TypeInfo support.
@("nonRootOwned.missingTemplateBodyIsWalked.Interpreter")
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

    thrown.msg.startsWith("interpreter cannot resolve the symbol").should
        == true;
    thrown.msg.canFind("TypeInfo_S").should == true;
}
