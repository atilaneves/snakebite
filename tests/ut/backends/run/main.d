module ut.backends.run.main;


import ut.backends;
import snakebite.backends.backend: Program, run;
import snakebite.frontend.compiler: parseSnippet;
import std.meta: AliasSeq;


static foreach (backend; Matrix!()) {
    @("ret.int.42." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeStatusOf!(
             backend,
             q{
                 int main() {
                     return 42;
                 }
             }
        );
    }
}

// The runner passes the program name as the sole argument when no user
// arguments exist. The entry point must receive its native dynamic-array
// layout.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("ret.int.arguments." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeStatusOf!(
            backend,
            q{
                int main(string[] args) {
                    if (args.length != 1)
                        return 1;
                    return args[0] == "snakebite" ? 42 : 2;
                }
            },
        );
    }
}

static foreach (backend; AliasSeq!(Interpreter, Bytecode)) {
    @("ret.int.hostArguments." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        auto program = Program([parseSnippet(q{
            int main(string[] args) {
                if (args.length != 3)
                    return 1;
                return args[0] == "sb"
                    && args[1] == "first"
                    && args[2] == "second" ? 42 : 2;
            }
        })], "snakebite");
        string[] hostArguments = ["sb", "first", "second"];

        run(new backend(program), program, hostArguments).should == 42;
    }
}

// One host-to-guest entry binds every argument class, not just a
// `main`'s `string[]`: an integer, a pointer, a slice, and a struct all
// reach the frame in native layout, whether the program runner's
// top-level `call` or a callback's re-entry is the caller (issue #367).
// This drives `Backend.call` directly, on a plain function rather than
// `main`, since `shouldBeStatusOf`/`shouldBeRetOf` only ever pass
// literal guest-to-guest arguments, never real host ones.
private struct HostPair {
    int a;
    int b;
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("hostToGuestArguments.mixedParameterClasses." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        int number = 10;
        int target = 5;
        int* pointer = &target;
        string label = "hi";
        auto pair = HostPair(3, 4);

        static if (is(backend == Native)) {
            static int mix(int number, int* pointer, string label,
                HostPair pair) {
                return number + *pointer
                    + cast(int) label.length + pair.a + pair.b;
            }

            mix(number, pointer, label, pair).should == 24;
        } else {
            import snakebite.frontend.dmd.functions: findFunction;

            auto module_ = parseSnippet(q{
                module hostToGuestArgumentsMixedParameterClasses;

                struct Pair {
                    int a;
                    int b;
                }

                int mix(int number, int* pointer, string label, Pair pair) {
                    return number + *pointer
                        + cast(int) label.length + pair.a + pair.b;
                }
            });
            auto backend_ = new backend(Program([module_]));

            int result;
            backend_.call(
                findFunction(module_, "mix"), &result,
                [
                    cast(void*) &number, cast(void*) &pointer,
                    cast(void*) &label, cast(void*) &pair,
                ],
            );

            result.should == 24;
        }
    }
}

static foreach (backend; Matrix!()) {
    @("ret.int.77." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        77.shouldBeStatusOf!(
             backend,
             q{
                 int main() {
                     return 77;
                 }
             }
        );
    }
}

static foreach (backend; Matrix!()) {
    @("ret.void." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(
             backend,
             q{
                 void main() {
                 }
             }
        );
    }
}

// `version (D_BetterC)` is not predefined by the frontend, so a real build
// picks the `else` branch's `main`, same as `dmd -unittest` would for dub's
// generated `dub_test_root.d` (its D_BetterC branch is dead code here). This
// pins that `findFunction` resolves the condition instead of always
// descending into a version declaration's syntactic first branch.
static foreach (backend; Matrix!()) {
    @("ret.int.betterCBranchNotTaken." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeStatusOf!(
             backend,
             q{
                 version (D_BetterC) {
                     int main() {
                         return 1;
                     }
                 } else {
                     int main() {
                         return 42;
                     }
                 }
             }
        );
    }
}

// A template instance contributes its expanded declarations to the module.
// `main` must therefore be found there, as a compiled program finds it.
static foreach (backend; Matrix!()) {
    @("ret.int.templateMixin." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeStatusOf!(
            backend,
            q{
                template Main() {
                    int main() {
                        return 42;
                    }
                }

                mixin Main!();
            },
        );
    }
}

// A failed assertion leaves `main` as a `Throwable` and the process fails,
// which is the contract `run` reports as a status.
static foreach (backend; Matrix!()) {
    @("failedAssertExitsNonZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeStatusOf!(backend, q{
            void main() {
                assert(1 == 2);
            }
        });
    }
}

// No `main` at all is not an error: the status is 0.
static foreach (backend; Matrix!()) {
    @("noMain." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(
             backend,
             q{
                 int notMain() {
                     return 42;
                 }
             }
        );
    }
}
