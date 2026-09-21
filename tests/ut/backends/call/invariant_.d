module ut.backends.call.invariant_;


import ut.backends;


// dmd's own semantic pass (`funcsem.addInvariant`) inserts an entry and an
// exit call to the enclosing aggregate's `invariant` block around every
// public, protected or exported non-static member function - built
// directly as `CallExp(DotVarExp(ThisExp, inv))`, with no
// `expressionSemantic` run over it, so `CallExp.f` stays null even though
// the callee is already known. A backend that only ever resolves a call
// through `expression.f` (or, for an indirect call, a stored function
// value) cannot compile or run this call at all. `bump` calling
// successfully, with the invariant holding both when it starts and when
// it returns, proves the call itself now runs.
static foreach (backend; Matrix!()) {
    @("invariant_.structMemberCall.entryAndExitChecksHold." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(backend, q{
            struct Counter {
                int value;
                invariant {
                    assert(value >= 0);
                }
                void bump() {
                    value += 1;
                }
            }

            int result() {
                Counter counter;
                counter.value = 41;
                counter.bump();
                return counter.value;
            }
        }, "result");
    }
}

// The invariant's own `assert` must actually run and fire, not merely
// compile: `counter.value` is set to a value that violates the invariant
// directly (a plain field write skips the invariant, exactly as compiled
// D does), so `bump`'s entry invariant call is the only thing left to
// notice it, throwing the real `AssertError` the guest observes.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns a failing assertion into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
)) {
    @("invariant_.structMemberCall.violationThrowsAssertError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(backend, q{
            import core.exception: AssertError;

            struct Counter {
                int value;
                invariant {
                    assert(value >= 0);
                }
                void bump() {
                    value += 1;
                }
            }

            int result() {
                Counter counter;
                counter.value = -1;
                try {
                    counter.bump();
                } catch (AssertError) {
                    return 42;
                }
                return 0;
            }
        }, "result");
    }
}

// The same hand-built call shape (`funcsem.addInvariant`) also fires for a
// class invariant: `ad.inv` there is a `ClassDeclaration`'s own
// `invariant`, and `addInvariant` builds the identical
// `CallExp(DotVarExp(ThisExp, inv))` regardless of which aggregate kind
// `ad` is.
static foreach (backend; Matrix!()) {
    @("invariant_.classMemberCall.entryAndExitChecksHold." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(backend, q{
            class Counter {
                int value;
                invariant {
                    assert(value >= 0);
                }
                void bump() {
                    value += 1;
                }
            }

            int result() {
                auto counter = new Counter;
                counter.value = 41;
                counter.bump();
                return counter.value;
            }
        }, "result");
    }
}

// `bump` is virtual here, the natural shape for a class member function -
// dmd gives a class method a vtable slot unless it is `final` or
// `private`. Reaching it goes through the interpreter's own virtual
// dispatch, which routes the call through its indirect-call FFI adapter
// (`_callIndirect`, `CallAdapter.invoke`): a thrown `AssertError` does not
// propagate back out of that adapter into the guest's own `try`/`catch`,
// crashing the process instead. That gap is pre-existing and unrelated to
// invariants - an ordinary `assert(false)` in a virtual method body
// crashes the same way, invariant or not - and is tracked separately as
// https://github.com/atilaneves/snakebite/issues/407. The `final` variant
// below proves the invariant fix itself still holds on the Interpreter,
// through a direct call that does not cross that adapter.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns a failing assertion into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
    Omit!(Interpreter, Because.unconfirmed,
        "crashes: a virtual call's thrown AssertError does not propagate " ~
        "out of the interpreter's indirect-call FFI adapter into the " ~
        "guest's own try/catch - pre-existing and unrelated to " ~
        "invariants, see https://github.com/atilaneves/snakebite/issues/407"),
)) {
    @("invariant_.classMemberCall.violationThrowsAssertError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(backend, q{
            import core.exception: AssertError;

            class Counter {
                int value;
                invariant {
                    assert(value >= 0);
                }
                void bump() {
                    value += 1;
                }
            }

            int result() {
                auto counter = new Counter;
                counter.value = -1;
                try {
                    counter.bump();
                } catch (AssertError) {
                    return 42;
                }
                return 0;
            }
        }, "result");
    }
}

// Same shape, but `final`: the call is bound directly rather than through
// the vtable, so it never crosses the indirect-call FFI adapter that
// swallows the exception above (issue #407). This is the sibling that
// keeps the invariant fix itself proven on the Interpreter even while the
// virtual case above is omitted for it.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns a failing assertion into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
)) {
    @("invariant_.classMemberCall.violationThrowsAssertError.nonVirtual." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(backend, q{
            import core.exception: AssertError;

            class Counter {
                int value;
                invariant {
                    assert(value >= 0);
                }
                final void bump() {
                    value += 1;
                }
            }

            int result() {
                auto counter = new Counter;
                counter.value = -1;
                try {
                    counter.bump();
                } catch (AssertError) {
                    return 42;
                }
                return 0;
            }
        }, "result");
    }
}
