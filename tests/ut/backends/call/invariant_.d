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

// A struct constructor writes through dmd's hidden result reference on its
// lowered return path. The result storage must be valid when that path and
// the invariant observe the completed value.
static foreach (backend; Matrix!()) {
    @("invariant_.structConstructor.referenceInitPreservesResult."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        123.shouldBeRetOf!(backend, q{
            struct S {
                int[4] data;

                this(int value) {
                    data[0] = value;
                }

                invariant {
                    assert(data[0] >= 0);
                }
            }

            int result() {
                auto value = S(123);
                assert(value.data[0] == 123);
                return value.data[0];
            }
        }, "result");
    }
}

// The same constructor invariant must execute, not only compile. A bad
// constructor value makes the invariant throw at the constructor boundary.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns the failing constructor invariant into a compile-time " ~
        "error, so it cannot be caught at run time"),
)) {
    @("invariant_.structConstructor.failureRunsInvariant."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(backend, q{
            import core.exception: AssertError;

            struct S {
                int[4] data;

                this(int value) {
                    data[0] = value;
                }

                invariant {
                    assert(data[0] >= 0);
                }
            }

            int result() {
                try {
                    auto value = S(-1);
                } catch (AssertError) {
                    return 42;
                }
                return 0;
            }
        }, "result");
    }
}

// A ref-returning function's `out(result)` contract uses dmd's hidden
// result reference. Both that contract and the caller's ref initializer
// must preserve the returned storage identity.
static foreach (backend; Matrix!()) {
    @("invariant_.refReturn.outReferenceInitPreservesIdentity."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(backend, q{
            ref int get(ref int value) out (result) {
                assert(&result == &value);
            } do {
                return value;
            }

            int result() {
                int value = 42;
                ref int refValue = get(value);
                assert(&refValue == &value);
                return refValue;
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

// `assert(structPtr)`/`assert(classRef)` run the pointed-to aggregate's own
// invariant too, not only a member function's entry/exit call proven above:
// dmd's own glue layer (`e2ir.d`'s `visitAssert`, gated on
// `useInvariants == CHECKENABLE.on`) evaluates the assert's condition once
// into a compiler temporary, and - only once that condition itself already
// held - calls the struct's own `inv` function on that same pointer before
// falling through. A struct whose invariant fails only when read through a
// bare `assert(&cell)`, with no member call anywhere in the snippet, proves
// this second call site runs on its own.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns a failing assertion into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
)) {
    @("invariant_.structPointerAssert.violationThrowsAssertError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(backend, q{
            import core.exception: AssertError;

            struct Cell {
                int value;
                invariant {
                    assert(value >= 0);
                }
            }

            int result() {
                Cell cell;
                cell.value = -1;
                try {
                    assert(&cell);
                } catch (AssertError) {
                    return 42;
                }
                return 0;
            }
        }, "result");
    }
}

// Same call site, invariant holding: `assert(&cell)` must still just pass,
// the same as a plain `assert` on a struct with no invariant at all would.
static foreach (backend; Matrix!()) {
    @("invariant_.structPointerAssert.passingInvariantDoesNotThrow." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(backend, q{
            struct Cell {
                int value;
                invariant {
                    assert(value >= 0);
                }
            }

            int result() {
                Cell cell;
                cell.value = 1;
                assert(&cell);
                return 42;
            }
        }, "result");
    }
}

// The class equivalent: `t1.ty == Tclass` in `e2ir.d`'s `visitAssert` calls
// druntime's own `_d_invariant` (`RTLSYM.DINVARIANT`) on the reference
// instead of a directly-named `inv` function, since a class invariant must
// walk every base class's own invariant too - druntime's own job, called
// through the FFI barrier here rather than reimplemented (this project's
// own druntime policy), exactly the way `_d_invariant`'s own druntime
// source (`rt.invariant_`) does it for a real compiled build.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns a failing assertion into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
)) {
    @("invariant_.classRefAssert.violationThrowsAssertError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(backend, q{
            import core.exception: AssertError;

            class Box {
                int value;
                invariant {
                    assert(value >= 0);
                }
            }

            int result() {
                auto box = new Box;
                box.value = -1;
                try {
                    assert(box);
                } catch (AssertError) {
                    return 42;
                }
                return 0;
            }
        }, "result");
    }
}

// Same call site, invariant holding: `assert(box)` must still just pass.
static foreach (backend; Matrix!()) {
    @("invariant_.classRefAssert.passingInvariantDoesNotThrow." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(backend, q{
            class Box {
                int value;
                invariant {
                    assert(value >= 0);
                }
            }

            int result() {
                auto box = new Box;
                box.value = 1;
                assert(box);
                return 42;
            }
        }, "result");
    }
}

// A null class reference still fails the assert's own condition first: dmd
// builds `(e1 || ModuleAssert(...))` ahead of `einv` in `visitAssert`, so a
// null reference never reaches the invariant call at all. Reaching it
// first would crash instead of throwing this guest-visible `AssertError`,
// since druntime's own `_d_invariant` starts with its own
// `assert(o !is null)`, at its own library source location rather than the
// guest's.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns a failing assertion into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
)) {
    @("invariant_.classRefAssert.nullReferenceFailsAssertFirst." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(backend, q{
            import core.exception: AssertError;

            class Box {
                int value;
                invariant {
                    assert(value >= 0);
                }
            }

            int result() {
                Box box;
                try {
                    assert(box);
                } catch (AssertError) {
                    return 42;
                }
                return 0;
            }
        }, "result");
    }
}
