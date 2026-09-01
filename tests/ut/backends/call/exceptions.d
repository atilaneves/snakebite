module ut.backends.call.exceptions;


import ut.backends;


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

// An assertion failure the guest never catches keeps unwinding out of
// `Backend.call` as the very `AssertError` the VM built for it - no second,
// backend-owned exception type stands in for it, so a caller catching
// `Throwable` (the way `snakebite.backends.backend.run` does for an
// escaping guest failure) sees the genuine object.
@("assert.fails.unhandled.propagatesTheRealAssertError.Bytecode")
@Tags("Bytecode")
unittest {
    import core.exception: AssertError;
    import snakebite.backends.backend: Program;
    import snakebite.backends.bytecode: Bytecode;
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        bool fail() {
            return false;
        }

        int result() {
            assert(fail());
            return 1;
        }
    });
    auto function_ = findFunction(module_, "result");
    auto bytecode = new Bytecode(Program([module_]));

    AssertError caught;
    int value;
    try
        bytecode.call(function_, &value, []);
    catch (AssertError error)
        caught = error;

    (caught !is null).shouldBeTrue;
}

// A failure several guest activations deep must pop every one of them on
// its way out - each nested call's own `opCall` handler pushed one onto the
// VM's shared frame stack - so that stack is exactly as empty afterwards as
// if the failing call had never run. A later, unrelated call on the same
// `Bytecode`, reusing that same frame stack, is the observable proof: it
// only computes the right answer if nothing the failed call reserved is
// still sitting on it.
@("assert.fails.unhandled.unwindsNestedActivationsCleanly.Bytecode")
@Tags("Bytecode")
unittest {
    import core.exception: AssertError;
    import snakebite.backends.backend: Program;
    import snakebite.backends.bytecode: Bytecode;
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
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
    });
    auto outermost = findFunction(module_, "outermost");
    auto tripleFour = findFunction(module_, "tripleFour");
    auto bytecode = new Bytecode(Program([module_]));

    AssertError caught;
    int discarded;
    try
        bytecode.call(outermost, &discarded, []);
    catch (AssertError error)
        caught = error;

    (caught !is null).shouldBeTrue;

    int tripled;
    bytecode.call(tripleFour, &tripled, []);
    tripled.shouldEqual(12);
}

static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
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

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
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
    BytecodeUnconfirmed,
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

// Interpreter-only by nature: the behaviour under test is the interpreter's
// own refusal of a construct it does not support, which no other backend
// has. The `switch` runs fine everywhere else.
@("tryCatchThrowable.doesNotCatchInterpreterFailure.Interpreter")
@Tags("Interpreter")
unittest {
    void run() {
        2.shouldBeRetOf!(
            Interpreter,
            q{
                int result() {
                    try {
                        switch (1) {
                            case 1:
                                break;

                            default:
                                break;
                        }
                    } catch(Throwable) {
                        return 1;
                    }
                    return 2;
                }
            },
            "result",
        );
    }

    run.shouldThrow;
}

@("failureMessage.fromClassField.survivesArrayAppend.Interpreter")
@Tags("Interpreter")
unittest {
    true.shouldBeRetOf!(
        Interpreter,
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

@("tryCatchThrowable.rethrowsCaughtGuestThrowable.Interpreter")
@Tags("Interpreter")
unittest {
    1.shouldBeRetOf!(
        Interpreter,
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

// `AssertError` derives from `Error`, not from `Exception`, so a
// `catch(Exception)` never matches a failing assertion: the error keeps
// unwinding to the `catch(AssertError)` outside it.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
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
