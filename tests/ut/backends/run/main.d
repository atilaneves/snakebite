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
// `main`'s `string[]`: an integer, a pointer, a slice, a struct, a `ref`
// and an `out` parameter all reach the frame in native layout, whether
// the program runner's top-level `call` or a callback's re-entry is the
// caller (issue #367). This test drives `Backend.call` directly, on a
// plain function rather than `main`, since
// `shouldBeStatusOf`/`shouldBeRetOf` only ever pass literal guest-to-guest
// arguments, never real host ones - the callback case further below
// covers the same parameter classes reached the other way, through a
// guest function pointer host code calls.
private struct HostPair {
    int a;
    int b;
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed, "the CTFE backend takes no host " ~
        "arguments"),
)) {
    @("hostToGuestArguments.mixedParameterClasses." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        int number = 10;
        int target = 5;
        int* pointer = &target;
        string label = "hi";
        auto pair = HostPair(3, 4);
        int refValue = 6;
        int outValue = -1;

        static if (is(backend == Native)) {
            static int mix(int number, int* pointer, string label,
                HostPair pair, ref int refParam, out int outParam) {
                refParam += 1;
                outParam = 99;
                return number + *pointer
                    + cast(int) label.length + pair.a + pair.b + refParam;
            }

            mix(number, pointer, label, pair, refValue, outValue)
                .should == 31;
        } else {
            import snakebite.frontend.dmd.functions: findFunction;

            auto module_ = parseSnippet(q{
                module hostToGuestArgumentsMixedParameterClasses;

                struct Pair {
                    int a;
                    int b;
                }

                int mix(int number, int* pointer, string label, Pair pair,
                        ref int refParam, out int outParam) {
                    refParam += 1;
                    outParam = 99;
                    return number + *pointer
                        + cast(int) label.length + pair.a + pair.b
                        + refParam;
                }
            });
            auto backend_ = new backend(Program([module_]));

            // A `ref`/`out` parameter's own native bytes are the
            // target's address, one pointer wide (`Backend.call`'s own
            // contract) - so the argument here is the address of a
            // pointer variable that itself holds `&refValue`/`&outValue`,
            // the same shape the `int*` parameter above already uses.
            int* refValuePointer = &refValue;
            int* outValuePointer = &outValue;

            int result;
            backend_.call(
                findFunction(module_, "mix"), &result,
                [
                    cast(void*) &number, cast(void*) &pointer,
                    cast(void*) &label, cast(void*) &pair,
                    cast(void*) &refValuePointer,
                    cast(void*) &outValuePointer,
                ],
            );

            result.should == 31;
        }

        refValue.should == 7;
        outValue.should == 99;
    }
}

// The callback path binds the same `ref`/`out` parameter classes the same
// way, since a callback's re-entry shares one host-to-guest entry with
// the program runner's top-level `call` (issue #367): host code calls a
// guest `void function(ref int)`, `void function(out int)`, and
// `void function(ref Big24)`, where `Big24` is a 24-byte struct - too
// big to fit the register a small `ref` target would. `RefIntFn`,
// `OutIntFn` and `RefBigFn` are module-scope aliases, declared before
// any `extern(C)` block, rather than written inline in an `extern(C)`
// declaration's own parameter list - an inline declaration there would
// also give the function pointer *type* `C` linkage, but a guest
// function's own address is always `extern(D)`.
private alias RefIntFn = extern(D) void function(ref int);
private alias OutIntFn = extern(D) void function(out int);
private struct Big24 {
    long a;
    long b;
    long c;
}
private alias RefBigFn = extern(D) void function(ref Big24);

private extern(C) int snakebite_ut_hostCallsGuestRef(RefIntFn fn) {
    int value = 1;
    fn(value);
    return value;
}

private extern(C) int snakebite_ut_hostCallsGuestOut(OutIntFn fn) {
    int value = 999;
    fn(value);
    return value;
}

private extern(C) int snakebite_ut_hostCallsGuestRefBig(RefBigFn fn) {
    Big24 value;
    fn(value);
    return cast(int) (value.a + value.b + value.c);
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot call host code"),
)) {
    @("hostToGuestArguments.callback.refAndOutParameters."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // `static` on each guest function keeps `&bumpRef` and friends
        // plain function pointers rather than delegates: for `Native`,
        // `shouldBeRetOf` mixes `code` into a lambda's own body, where a
        // nested function that is not `static` closes over that scope
        // and its address is a delegate, not a function pointer, of the
        // wrong type for `RefIntFn`/`OutIntFn`/`RefBigFn`.
        enum code = q{
            static void bumpRef(ref int x) { x = 42; }
            static void bumpOut(out int x) { x = 43; }
            struct Big24 { long a; long b; long c; }
            static void bumpRefBig(ref Big24 s) { s.a = 1; s.b = 2; s.c = 3; }

            alias RefIntFn = void function(ref int);
            alias OutIntFn = void function(out int);
            alias RefBigFn = void function(ref Big24);

            pragma(mangle, "snakebite_ut_hostCallsGuestRef")
            extern(C) int callRef(RefIntFn fn);
            pragma(mangle, "snakebite_ut_hostCallsGuestOut")
            extern(C) int callOut(OutIntFn fn);
            pragma(mangle, "snakebite_ut_hostCallsGuestRefBig")
            extern(C) int callRefBig(RefBigFn fn);

            int answer() {
                return callRef(&bumpRef) + callOut(&bumpOut)
                    + callRefBig(&bumpRefBig);
            }
        };
        91.shouldBeRetOf!(backend, code, "answer");
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

static foreach (backend; Matrix!()) {
    @("ret.int.disabledMainWithoutElse." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeStatusOf!(
            backend,
            q{
                static if (false) {
                    int main() { return 1; }
                }
                int main() { return 42; }
            },
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
