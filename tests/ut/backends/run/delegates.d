module ut.backends.run.delegates;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot access delegate function pointers"),
)) {
    @("assignDelegateFieldsBeforeNestedCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Counter {
                int value;
                int read() { return value; }
            }
            int invoke(Counter* counter) {
                int delegate() callback;
                callback.funcptr = &Counter.read;
                callback.ptr = counter;
                int helper() { return callback(); }
                return helper();
            }
            void main() {
                Counter counter = Counter(42);
                assert(invoke(&counter) == 42);
            }
        });
    }
}


// A delegate is true when either of its two words (`ptr`, `funcptr`) is
// nonzero: `null` leaves both zero, and assigning a method delegate sets
// both, so the assignment alone flips the condition.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot evaluate a method delegate as a compile-time "
            ~ "boolean condition"),
)) {
    @("delegateTruthyAfterAssignment." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Counter {
                int value;
                int read() { return value; }
            }
            void main() {
                int delegate() callback;
                assert(!callback);

                Counter counter = Counter(42);
                callback = &counter.read;
                assert(callback);
            }
        });
    }
}


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


// `key in aa` gives a pointer to the matched value, not the value
// itself, so calling through it is a call through a delegate pointer,
// not a call on a delegate. dmd's own `(*handler)(...)` syntax for that
// dereference looks exactly like a function-pointer call's own lowered
// shape (issue: bytecode/interpreter must pick the callee kind from
// `e1`'s type, `Tdelegate`, never from `e1` being a `PtrExp`).
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot access delegate function pointers"),
)) {
    @("callDelegateThroughPointerFromAssociativeArrayIn." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            alias Handler = int delegate(int);
            void main() {
                int total;
                Handler[string] handlers;
                handlers["a"] = (int x) { total += x; return x * 2; };
                auto handler = "a" in handlers;
                assert(handler !is null);
                assert((*handler)(5) == 10);
                assert(total == 5);
            }
        });
    }
}


// The address-of a delegate variable is a pointer to a delegate, so
// calling through it dereferences to the two-word delegate value first -
// the same `(*p)(...)` syntax a function pointer's own call lowers to,
// but `p`'s pointee type is `Tdelegate`, not `Tfunction`.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot access delegate function pointers"),
)) {
    @("callDelegateThroughPlainPointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            alias Handler = int delegate(int);
            void main() {
                int total;
                Handler h = (int x) { total += x; return x * 2; };
                Handler* p = &h;
                assert((*p)(5) == 10);
                assert(total == 5);
            }
        });
    }
}
