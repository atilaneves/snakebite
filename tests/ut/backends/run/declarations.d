module ut.backends.run.declarations;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;
import snakebite.backends.backend: Program, run;
import snakebite.dependencyimage: defaultCompiler;
import snakebite.frontend.compiler: parseSnippet;
import std.process: execute;


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot run thread-local module initialization"),
)) {
    @("threadModuleConstructorBeforeCallback." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        enum code = q{
            module thread_constructors;
            import core.thread: Thread;

            int value;
            int calls;
            static this() {
                value = 42;
                ++calls;
            }

            void worker() {
                assert(value == 42);
                assert(calls == 1);
                value = 99;
            }

            void main() {
                assert(value == 42);
                assert(calls == 1);
                value = 7;
                foreach (i; 0 .. 2) {
                    auto thread = new Thread(&worker);
                    thread.start;
                    thread.join;
                }
                assert(value == 7);
                assert(calls == 1);
            }
        };
        static if (is(backend == Native)) {
            const sandbox = Sandbox();
            sandbox.writeFile("thread_constructors.d", code);
            const executable = sandbox.inSandboxPath("test");
            const result = execute([defaultCompiler,
                sandbox.inSandboxPath("thread_constructors.d"),
                "-of=" ~ executable]);
            result.status.shouldEqual(0, result.output);
            execute([executable]).status.should == 0;
        } else {
            auto program = Program([parseSnippet(code)]);
            run(new backend(program), program).should == 0;
        }
    }
}


static foreach (backend; Matrix!()) {
    @("tupleLocalsInitializeEveryMember." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(backend, q{
            import std.meta: AliasSeq;

            struct First { int value = 17; }
            struct Second { int value = 25; }

            int result() {
                AliasSeq!(First, Second) values;
                return values[0].value + values[1].value;
            }
        }, "result");
    }
}


static foreach (backend; Matrix!()) {
    @("localTemplateMixinInitializesInOrder." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(backend, q{
            mixin template Values() {
                int first = seed;
                int second = first + 2;
            }

            int result() {
                int seed = 20;
                mixin Values;
                return first + second;
            }
        }, "result");
    }
}


// Every `shared static this` runs before any `static this`, and each group
// runs in declaration order.
static foreach (backend; Matrix!(
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


// A root module can declare a native `extern(C)` function without providing
// its body. Its module constructor must call the host symbol through the FFI,
// then make that result visible to `main`.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe cannot call native functions"),
)) {
    @("rootExternCModuleConstructor." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C) pragma(mangle, "abs") int abs(int);

            __gshared bool initialized;

            shared static this() {
                initialized = abs(-42) == 42;
            }

            int main() {
                return initialized ? 0 : 1;
            }
        });
    }
}


static foreach (backend; Matrix!(
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
    Omit!(Ctfe, Because.unconfirmed),
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

// The same CTFE-folded shape as `staticImmutableStringFromCtfeCall` with
// two-byte code units: the static's pointer and length must describe
// `wchar`s, not bytes.
static foreach (backend; Matrix!()) {
    @("staticImmutableWstringFromCtfeCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            wstring build() {
                wstring result;
                result ~= "ab"w;
                result ~= "c"w;
                return result;
            }

            static immutable wstring text = build();

            void main() {
                assert(text.length == 3);
                assert(text == "abc"w);
                assert(text[2] == 'c');
            }
        });
    }
}

// The same CTFE-folded shape with four-byte code units.
static foreach (backend; Matrix!()) {
    @("staticImmutableDstringFromCtfeCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            dstring build() {
                dstring result;
                result ~= "ab"d;
                result ~= "c"d;
                return result;
            }

            static immutable dstring text = build();

            void main() {
                assert(text.length == 3);
                assert(text == "abc"d);
                assert(text[2] == 'c');
            }
        });
    }
}
