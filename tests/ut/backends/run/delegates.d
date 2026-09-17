module ut.backends.run.delegates;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read callable TypeInfo fields"),
)) {
    @("callableTypeInfo." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Result { int value; }
            Result operation(int value) { return Result(value); }
            alias Callback = Result delegate(int);
            void main() {
                auto functionInfo = cast(TypeInfo_Function) typeid(typeof(operation));
                assert(functionInfo !is null);
                assert(functionInfo.next is typeid(Result));
                assert(functionInfo.deco == typeof(operation).mangleof);
                assert(functionInfo.tsize == 0);
                auto pointerInfo = cast(TypeInfo_Pointer) typeid(typeof(&operation));
                assert(pointerInfo.m_next is functionInfo);
                auto delegateInfo = cast(TypeInfo_Delegate) typeid(Callback);
                assert(delegateInfo !is null);
                assert(delegateInfo.next is typeid(Result));
                assert(delegateInfo.deco == Callback.mangleof);
                assert(delegateInfo.tsize == Callback.sizeof);
                assert(typeid(Callback) is delegateInfo);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("pointerToVariadicDelegateCaller." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.stdc.stdarg;
            struct Counter {
                int value;
                extern(C) void add(int amount, ...) { value += amount; }
            }
            void invoke(Counter* counter) {
                auto add = &counter.add;
                add(17);
            }
            void main() {
                auto invokePointer = &invoke;
                assert(invokePointer !is null);
            }
        });
    }
}


// A function literal that reads no enclosing local needs no context, so
// binding it to a delegate variable makes a (null, function) pair. Each
// call binds the parameter afresh, so repeated calls see their own
// argument, not a stale one.
static foreach (backend; Matrix!()) {
    @("nonCapturingDelegateBindsItsParameterEachCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                int delegate(int) increment = (int value) => value + 1;

                assert(increment(0) == 1);
                assert(increment(41) == 42);
                assert(increment(-3) == -2);

                return 0;
            }
        });
    }
}


// Delegate equality compares both the function and context pointers. A
// copied delegate is equal, while two closures from separate calls are not,
// even when they produce the same result.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("delegateEqualityComparesFunctionAndContext." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int delegate(int) make(int seed) {
                int add(int value) {
                    return seed + value;
                }

                return &add;
            }

            void main() {
                auto first = make(10);
                auto copy = first;
                auto second = make(10);

                assert(first == copy);
                assert(first != second);
                assert(first(2) == second(2));
            }
        });
    }
}


// The alias-template form `check!F` hands the literal itself to the
// template, so `F(value)` is a direct call of the literal - each
// invocation must see the argument of that invocation.
static foreach (backend; Matrix!()) {
    @("nonCapturingLambdaThroughAliasTemplate." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void check(alias F)() {
                foreach (value; 0 .. 5)
                    assert(F(value) == value + 1);
            }

            int main() {
                check!((int value) => value + 1);
                return 0;
            }
        });
    }
}


// A delegate to a nested function is a (context, function) pair whose
// context is the enclosing frame, so calling it reaches the same locals.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("nestedFunctionDelegateCarriesItsFrame." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int runtimeSeed(int seed) {
                return seed + 1;
            }

            void main() {
                int captured = runtimeSeed(3);

                int nested() {
                    captured += 2;
                    return captured;
                }

                int delegate() dg = &nested;

                assert(dg.ptr !is null);
                assert(dg.funcptr !is null);

                assert(dg() == 6);
                assert(captured == 6);
            }
        });
    }
}
