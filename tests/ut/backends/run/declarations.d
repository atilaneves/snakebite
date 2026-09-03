module ut.backends.run.declarations;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


// Every `shared static this` runs before any `static this`, and each group
// runs in declaration order.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed),
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


// A module constructor must run even when it calls a native function with a
// guest function pointer. A backend that refuses that call makes `run` skip
// the constructor, so `initialized` stays false and `main` returns the wrong
// status.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed),
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("moduleConstructorRunsBeforeMain." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.runtime : Runtime;

            __gshared bool initialized;

            shared static this() {
                Runtime.moduleUnitTester = () => true;
                initialized = true;
            }

            int main() {
                return initialized ? 0 : 1;
            }
        });
    }
}


static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("rootTemplateStaticCtorRunsBeforeMain." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            __gshared int trace;

            template constructors() {
                shared static this() {
                    trace = trace * 10 + 1;
                }

                static this() {
                    trace = trace * 10 + 3;
                }
            }

            mixin constructors!();

            void main() {
                assert(trace == 13);
            }
        });
    }
}

// `pragma(mangle)` binds a declaration to a symbol by name, so the guest
// links against druntime's `gc_getArrayUsed` even though nothing in it
// declares that symbol directly; without `pragma(mangle)` the link fails
// rather than the assertions.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
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
