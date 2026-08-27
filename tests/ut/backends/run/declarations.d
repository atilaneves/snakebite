module ut.backends.run.declarations;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


// Every `shared static this` runs before any `static this`, and each group
// runs in declaration order.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("sharedStaticCtorsRunFirst." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            __gshared int trace;

            static this() {
                trace = trace * 10 + 3;
            }

            shared static this() {
                trace = trace * 10 + 1;
            }

            shared static this() {
                trace = trace * 10 + 2;
            }

            void main() {
                assert(trace == 123);
            }
        });
    }
}

// A failed assertion leaves `main` as a `Throwable` and the process fails,
// which is the contract `run` reports as a status.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
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

// `pragma(mangle)` binds a declaration to a symbol by name, so the call
// reaches druntime's definition without a D-visible declaration of it.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("pragmaMangleCallsBySymbolName." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C) pragma(mangle, "gc_getArrayUsed")
            void[] residentGetArrayUsed(void* pointer, bool atomic);

            void main() {
                const used = residentGetArrayUsed(null, false);

                assert(used.length == 0);
                assert(used.ptr is null);
            }
        });
    }
}

