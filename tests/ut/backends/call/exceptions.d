module ut.backends.call.exceptions;


import ut.backends;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;


static foreach (backend; Matrix!()) {
    @("assert.passes." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        5.shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int two() {
                    return 2;
                }

                int result() {
                    assert(one() < two());
                    return 5;
                }
            },
            "result",
        );
    }
}

// `enforce` is an available native template, but its message is a `lazy`
// parameter. The caller's expression must stay executable when `enforce`
// reads it.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "bytecode cannot compile `enforce`'s lazy message delegate"),
)) {
    @("exception.enforce.lazyMessage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        static if (is(backend == Interpreter)) {
            auto module_ = parseSnippet(q{
                void result() {
                    import std.exception: enforce;

                    enforce(false, "expected");
                }
            });
            auto function_ = findFunction(module_, "result");

            interpreter(module_).call(function_, null, [])
                .shouldThrowWithMessage("expected");
        } else {
            true.shouldBeRetOf!(backend, q{
                bool result() {
                    import std.exception: enforce;

                    try
                        enforce(false, "expected");
                    catch (Exception exception)
                        return exception.msg == "expected";

                    return false;
                }
            }, "result");
        }
    }
}

// An assertion failure the guest never catches keeps unwinding out of
// `Backend.call` as the very `AssertError` the backend built for it - no
// second, backend-owned exception type stands in for it, so a caller
// catching it sees the genuine object.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns a failing assertion into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
)) {
    @("assert.fails.unhandled.propagatesTheRealAssertError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        import core.exception: AssertError;

        enum code = q{
            bool fail() {
                return false;
            }

            int result() {
                assert(fail());
                return 1;
            }
        };

        AssertError caught;
        int value;

        static if (is(backend == Native)) {
            mixin(code);
            try
                value = result();
            catch (AssertError error)
                caught = error;
        } else {
            import snakebite.backends.backend: Program;
            import snakebite.frontend.compiler: parseSnippet;
            import snakebite.frontend.dmd.functions: findFunction;

            auto module_ = parseSnippet(code);
            auto function_ = findFunction(module_, "result");
            auto instance = new backend(Program([module_]));

            try
                instance.call(function_, &value, []);
            catch (AssertError error)
                caught = error;
        }

        (caught !is null).should == true;
    }
}

// A failure several guest activations deep must not corrupt calls that
// come after it. A later, unrelated call on the same backend instance is
// the observable proof: it must compute the right answer, as if the
// failing call had never run.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns a failing assertion into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
)) {
    @("assert.fails.unhandled.unwindsNestedActivationsCleanly." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        import core.exception: AssertError;

        enum code = q{
            bool fail() {
                return false;
            }

            int deepest() {
                assert(fail());
                return 0;
            }

            int middle() {
                return deepest() + 1;
            }

            int outermost() {
                return middle() + 1;
            }

            int tripleFour() {
                return 4 * 3;
            }
        };

        AssertError caught;
        int discarded;

        static if (is(backend == Native)) {
            mixin(code);

            try
                discarded = outermost();
            catch (AssertError error)
                caught = error;

            (caught !is null).should == true;

            const tripled = tripleFour();
            tripled.should == 12;
        } else {
            import snakebite.backends.backend: Program;
            import snakebite.frontend.compiler: parseSnippet;
            import snakebite.frontend.dmd.functions: findFunction;

            auto module_ = parseSnippet(code);
            auto outermost = findFunction(module_, "outermost");
            auto tripleFour = findFunction(module_, "tripleFour");
            auto instance = new backend(Program([module_]));

            try
                instance.call(outermost, &discarded, []);
            catch (AssertError error)
                caught = error;

            (caught !is null).should == true;

            int tripled;
            instance.call(tripleFour, &tripled, []);
            tripled.should == 12;
        }
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns a failing assertion into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
    Omit!(Interpreter, Because.unconfirmed, "guest try/catch not implemented"),
)) {
    @("assert.fails.reports.the.line.of.the.assertion." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        size_t(5).shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int two() {
                    return 2;
                }

                size_t result() {
                    import core.exception: AssertError;

                    size_t first;

                    try {
                        assert(two() < one());
                    } catch(AssertError e) {
                        first = e.line;
                    }

                    try { assert(two() < one()); }
                    catch(AssertError e) {
                        return e.line - first;
                    }

                    return 0;
                }
            },
            "result",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("tryCatchThrowable.passingTrySkipsCatch." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeRetOf!(
            backend,
            q{
                int result() {
                    int value;
                    try {
                        value = 1;
                    } catch(Throwable caught) {
                        value = 2;
                    }
                    return value;
                }
            },
            "result",
        );
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns a failing assertion into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
)) {
    @("tryCatchThrowable.catchesGuestAssertion." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        2.shouldBeRetOf!(
            backend,
            q{
                bool fail() {
                    return false;
                }

                int result() {
                    int value;
                    try {
                        assert(fail());
                        value = 1;
                    } catch(Throwable caught) {
                        value = 2;
                    }
                    return value;
                }
            },
            "result",
        );
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns a failing assertion into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
)) {
    @("failureMessage.fromClassField.survivesArrayAppend." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                bool fail() {
                    return false;
                }

                bool result() {
                    string[] messages;
                    try
                        assert(fail());
                    catch (Throwable throwable)
                        messages ~= throwable.msg;

                    return messages.length == 1 && messages[0].length != 0;
                }
            },
            "result",
        );
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns a failing assertion into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
)) {
    @("tryCatchThrowable.rethrowsCaughtGuestThrowable." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeRetOf!(
            backend,
            q{
                bool fail() {
                    return false;
                }

                int result() {
                    try {
                        try
                            assert(fail());
                        catch (Throwable caught)
                            throw caught;
                    } catch (Throwable) {
                        return 1;
                    }

                    return 0;
                }
            },
            "result",
        );
    }
}

// `AssertError` derives from `Error`, not from `Exception`, so a
// `catch(Exception)` never matches a failing assertion: the error keeps
// unwinding to the `catch(AssertError)` outside it.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns a failing assertion into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
    Omit!(Interpreter, Because.unconfirmed, "guest try/catch not implemented"),
)) {
    @("assert.fails.is.not.caught.by.catching.Exception." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        9.shouldBeRetOf!(
            backend,
            q{
                int one() {
                    return 1;
                }

                int two() {
                    return 2;
                }

                int result() {
                    import core.exception: AssertError;

                    try {
                        try {
                            assert(two() < one());
                        } catch(Exception) {
                            return 7;
                        }
                    } catch(AssertError) {
                        return 9;
                    }

                    return 5;
                }
            },
            "result",
        );
    }
}
