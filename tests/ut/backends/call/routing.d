module ut.backends.call.routing;


// A root-owned callee is interpreted. A non-root declaration uses native
// code, and a missing native symbol for it is an error. Names and packages
// do not decide how a call runs.


import ut.backends;
import snakebite.program: Program;
import snakebite.frontend.compiler: parseSnippet, parseSnippets;
import snakebite.frontend.dmd.functions: findFunction;
import std.algorithm.searching: canFind;


// A root-owned declaration whose name copies druntime's `_d_*` convention
// is still root-owned, so it is interpreted. No native symbol for it
// exists in this process, so answering 42 at all is only possible by
// walking its body - a name-based rule sending `_d_*` spellings to native
// execution could not.
static foreach (backend; Matrix!()) {
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

private enum importedLiteralModule = q{
    module routing_literal_helper;
    struct Helper {
        enum increment = function(int x) { return x + 1; };
    }
};

// A function literal stored in an enum inside an imported, non-template
// struct has a body but no native symbol. Both a direct call and a function
// pointer must use that body.
static foreach (backend; Matrix!()) {
    @("importedStructFunctionLiteral.directAndPointer."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        static if (is(backend == Native)) {
            struct Helper {
                enum increment = function(int x) { return x + 1; };
            }

            const direct = Helper.increment(41);
            int function(int) pointer = Helper.increment;
            (direct + pointer(0)).should == 43;
        } else {
            auto modules = parseSnippets([
                q{
                    module routing_literal_root;
                    import routing_literal_helper: Helper;

                    int answer() {
                        const direct = Helper.increment(41);
                        int function(int) pointer = Helper.increment;
                        return direct + pointer(0);
                    }
                },
                importedLiteralModule,
            ]);
            auto function_ = findFunction(modules[0], "answer");
            auto backend_ = ownedBackend!backend(Program([modules[0]]));

            int result;
            backend_.call(function_, &result, []);
            result.should == 43;
        }
    }
}


// ADR-0009, decision 3: a dependency function with no native symbol is an
// error for the missing symbol, with or without a body, as the link of a
// native build reports it. No archive holds `routing_helper`. A direct call
// and the address of the function each end with an error that names the
// symbol; the body, which would answer 42, does not run.
private enum missingHelperModule = q{
    module routing_helper;
    int fortyTwo() { return 42; }
    extern(C) int cFortyTwo() { return 42; }
};

static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "a missing symbol fails the native link before a test can run"),
    Omit!(Ctfe, Because.inexpressible,
        "CTFE runs each body from source and calls no native code"),
)) {
    @("nonRootOwned.missingNativeIsAnError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        auto modules = parseSnippets([
            q{
                module routing_root;
                import routing_helper;
                int direct() { return fortyTwo(); }
                int cDirect() { return cFortyTwo(); }
                int address() {
                    auto pointer = &fortyTwo;
                    return pointer();
                }
            },
            missingHelperModule,
        ]);
        auto program = Program([modules[0]]);
        auto backend_ = ownedBackend!backend(program);

        static foreach (entry; [
            ["direct", "_D14routing_helper8fortyTwoFZi"],
            ["cDirect", "`cFortyTwo`"],
            ["address", "_D14routing_helper8fortyTwoFZi"],
        ]) {{
            int result;
            const thrown = backend_
                .call(findFunction(modules[0], entry[0]), &result, [])
                .shouldThrow;
            entry[1].should.be in thrown.msg;
        }}
    }
}


// DMD's lowered append call uses the guest-only struct's synthesized TypeInfo
// and runs its body in the interpreter.
@("rootOwned.guestStructAppend.Interpreter")
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
    interpreter(module_).call(function_, &result, []);
    result.should == 1;
}


// A lowered append and its native argument call reuse resolved symbols on a
// second execution.
@("rootOwned.guestStructAppend.reusesResolvedSymbols.Interpreter")
@Tags("Interpreter")
unittest {
    auto module_ = parseSnippet(q{
        struct OnlyInTheGuest { int value; }

        size_t grown() {
            import core.stdc.stdlib: abs;
            OnlyInTheGuest[] a;
            a ~= OnlyInTheGuest(abs(-42));
            return a.length;
        }
    });
    auto function_ = findFunction(module_, "grown");
    auto backend = interpreter(module_);

    size_t result;
    backend.call(function_, &result, []);
    result.should == 1;
    const lookups = backend.symbolLookups;
    backend.call(function_, &result, []);
    result.should == 1;
    backend.symbolLookups.should == lookups;
    assert(lookups >= 1);
}
