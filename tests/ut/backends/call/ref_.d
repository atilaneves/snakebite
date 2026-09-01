module ut.backends.call.ref_;


import ut.backends;


// The simplest `ref` round trip: the callee mutates the parameter twice,
// and both mutations land on the caller's own local, not a copy of it.
static foreach (backend; Matrix!()) {
    @("ref.param.mutatedByCallee." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        3.shouldBeRetOf!(
            backend,
            q{
                void inc(ref int x) {
                    ++x;
                }

                int kindaMain() {
                    int a = 1;
                    inc(a);
                    inc(a);
                    return a;
                }
            },
            "kindaMain",
        );
    }
}

// A `ref` parameter forwarded into a nested call: `bump`'s own `x` is
// itself `ref`, and passing it on to `inc` must reach the same storage as
// the outer local, not a second indirection through `bump`'s frame.
static foreach (backend; Matrix!()) {
    @("ref.param.passesThroughNestedCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        3.shouldBeRetOf!(
            backend,
            q{
                void inc(ref int x) {
                    ++x;
                }

                void bump(ref int x) {
                    inc(x);
                }

                int kindaMain() {
                    int a = 1;
                    bump(a);
                    bump(a);
                    return a;
                }
            },
            "kindaMain",
        );
    }
}

// A `ref` return is an lvalue: assigning through the call itself changes
// whichever of the two arguments it picked, and the caller's own local -
// not a copy the call handed back - is what changed.
static foreach (backend; Matrix!()) {
    @("ref.return.assignableThroughCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        5.shouldBeRetOf!(
            backend,
            q{
                ref int pick(ref int a, ref int b, bool first) {
                    return first ? a : b;
                }

                int kindaMain() {
                    int a = 1;
                    int b = 2;
                    pick(a, b, true) = 5;
                    return a;
                }
            },
            "kindaMain",
        );
    }
}

// `writeln` initializes a scoped `File` temporary from the native
// `trustedStdout` value before it writes. This is the public library path
// used by the rt-simple runner's final summary.
@("temporary.nativeAggregateFeedsCommaLvalue.Interpreter")
@Tags("Interpreter")
unittest {
    0.shouldBeStatusOf!(Interpreter, q{
        import std.stdio: writeln;

        void main() {
            size_t total = 23;
            size_t failed;
            writeln(total, " test(s) run, ", failed, " failed.");
        }
    });
}

// Taking the address of a ref-returning call must evaluate the call once and
// keep the returned alias, not a copy of its value.
@("ref.return.addressEvaluatedOnce.Interpreter")
@Tags("Interpreter")
unittest {
    17.shouldBeRetOf!(
        Interpreter,
        q{
            int calls;
            int value;

            ref int cell() {
                ++calls;
                return value;
            }

            int takeAddress() {
                int* address = &cell();
                *address = 7;
                return calls * 10 + value;
            }
        },
        "takeAddress",
    );
}

// `static` storage lives outside any frame, so a `ref` parameter bound to
// it exercises the one address `slotOf` cannot reach through the frame -
// `FrameLayout.offsetOf` never reserved it a slot to indirect through in
// the first place.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE interpreter refuses to take the address of a " ~
        "thread-local variable at compile time"),
)) {
    @("ref.param.boundToStatic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        5.shouldBeRetOf!(
            backend,
            q{
                void bumpBy(ref int x, int amount) {
                    x += amount;
                }

                int bump() {
                    static int count = 1;
                    bumpBy(count, 4);
                    return count;
                }
            },
            "bump",
        );
    }
}

// A `ref` parameter of a slice type: the callee overwrites both words of
// the caller's slice - its length and its pointer - through the
// reference, not just the bytes the slice currently points at. Built out
// of string literals and a whole-slice assignment, the only slice
// operations the interpreter supports today; `ArrayLiteralExp` and
// `CatAssignExp` are out of scope here.
static foreach (backend; Matrix!()) {
    @("ref.param.wholeSliceThroughReference." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        size_t(5).shouldBeRetOf!(
            backend,
            q{
                void setGreeting(ref string s, string value) {
                    s = value;
                }

                size_t useSlice() {
                    string greeting = "hi";
                    setGreeting(greeting, "hello");
                    return greeting.length;
                }
            },
            "useSlice",
        );
    }
}

// `Evaluator.call` is the host entry point, not a guest `CallExp`: a
// `ref`-returning function called through it hands the host a scratch
// buffer sized for the callee's own return type - `int`, 4 bytes here -
// but `visit(ReturnStatement)` always writes `size_t.sizeof` (8) bytes
// for a `ref` return, regardless of `_facts.size`. Unrefused, this call
// would write 8 bytes into the host's 4-byte `int`.
@("ref.return.hostCall.refused.Interpreter")
@Tags("Interpreter")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        ref int identity() {
            static int x = 5;
            return x;
        }
    });
    auto function_ = findFunction(module_, "identity");

    int result;
    interpreter(module_).call(function_, &result, [])
        .shouldThrowWithMessage(
            "interpreter cannot call `identity` from the host: it " ~
                "returns by `ref`");
}
