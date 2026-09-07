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

// A module-scope `static immutable string` initialised by a call dmd's
// CTFE can fold: the call builds its answer with `~=` rather than
// returning a slice of source text, so the fold is this `ArrayLiteralExp`
// of individual code units, not a `StringExp`.
static foreach (backend; Matrix!()) {
    @("staticImmutableStringFromCtfeCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            string greeting() {
                string result;
                result ~= "hel";
                result ~= "lo";
                return result;
            }

            static immutable string greetingText = greeting();

            void main() {
                assert(greetingText == "hello");
            }
        });
    }
}

// A `static int` initialised by a CTFE-able call: dmd's CTFE folds the
// call straight to an `IntegerExp`, the same shape a literal initialiser
// already has.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "confirmed: dmd's CTFE refuses `tripled` with \"static variable " ~
        "`tripled` cannot be read at compile time\" - the initialiser " ~
        "runs in the compiler's own CTFE session while compiling the " ~
        "snippet, and `main()`'s later, separate `ctfeInterpret` call " ~
        "cannot read a `static` mutated by a prior session"),
)) {
    @("staticIntFromCtfeCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int triple(int x) {
                return x * 3;
            }

            static int tripled = triple(14);

            void main() {
                assert(tripled == 42);
            }
        });
    }
}

// A template-instance `static` (the same shape as `std.conv`'s own
// `enumRep`) is one storage location shared by every call to that
// instance: reading it twice must see the same address, not a fresh
// fold each time.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "confirmed: dmd's CTFE refuses `value` with \"static variable " ~
        "`value` cannot be read at compile time\" - the same confirmed " ~
        "gap `staticIntFromCtfeCall` above hits"),
)) {
    @("templateInstanceStaticIsOneStorageLocation." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            string build() {
                string result;
                result ~= "ab";
                result ~= "c";
                return result;
            }

            immutable(char)[] cached(T)() {
                static immutable(char)[] value = build();
                return value;
            }

            void main() {
                auto first = cached!int();
                auto second = cached!int();
                assert(first == "abc");
                assert(first.ptr == second.ptr);
            }
        });
    }
}
