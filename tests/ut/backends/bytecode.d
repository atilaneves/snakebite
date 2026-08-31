module ut.backends.bytecode;


import ut.backends;
import snakebite.backends.backend: Program, run;
import snakebite.frontend.compiler: parseSnippet;
import std.algorithm.searching: canFind;


// `dub_test_root` is dub's name for the generated test root, so `Program`
// resolves this module's `main` (there isn't one) to
// `Program.Main.Kind.dubTestRunner` and its execution roots become every
// unittest in the module, not a single `main`.
@("Bytecode.roots.everyUnittestRuns")
unittest {
    auto module_ = parseSnippet(q{
        module dub_test_root;

        unittest {
        }

        unittest {
            return;
        }
    });
    auto program = Program([module_]);

    run(new Bytecode(program), program).should == 0;
}

// An application program's execution roots are its module constructors,
// then its `main` - not a single function picked in isolation.
@("Bytecode.roots.moduleConstructorsThenMain")
unittest {
    auto module_ = parseSnippet(q{
        static this() {
        }

        int main() {
            return 42;
        }
    });
    auto program = Program([module_]);

    run(new Bytecode(program), program).should == 42;
}

// The second module constructor cannot compile; `compile` walks every
// root - both module constructors, then `main` - before any of them
// executes, so the rejection surfaces from `compile` itself, with no call
// into the VM ever made for either constructor or for `main`.
@("Bytecode.eagerCompile.rejectsTheWholeGraphBeforeRunning")
unittest {
    auto module_ = parseSnippet(q{
        static this() {
        }

        static this() {
            int x = 1;
        }

        int main() {
            return 42;
        }
    });
    auto program = Program([module_]);
    auto backend = new Bytecode(program);

    const thrown = backend.compile(program).shouldThrow;

    thrown.msg.canFind("int x = 1").should == true;
    thrown.msg.canFind("(").should == true;
}
