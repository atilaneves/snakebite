module ut.backends.run.declarations;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;
import snakebite.gc: finalizerSearches;
import snakebite.backends.backend: Program, run;
import snakebite.frontend.compiler: parseSnippet;


static foreach (backend; Matrix!()) {
    @("floatVectorDeclaration." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            version (D_SIMD) {} else static assert(0);

            alias float4 = __vector(float[4]);

            static assert(float4.sizeof == 16);
            static assert(float4.alignof == 16);

            void main() {}
        });
    }
}


// A shared module constructor and, with `withTls`, a thread-local one run
// before a thread's callback does.
private enum threadConstructorsGuest(bool withTls) = "enum withTls = "
    ~ (withTls ? "true;" : "false;") ~ q{
    import core.thread: Thread;

    __gshared int sharedCalls;
    shared static this() {
        ++sharedCalls;
    }

    static if (withTls) {
        int value;
        int calls;
        static this() {
            value = 42;
            ++calls;
        }
    }

    void worker() {
        assert(sharedCalls == 1);
        static if (withTls) {
            assert(value == 42);
            assert(calls == 1);
            value = 99;
        }
    }

    void main() {
        assert(sharedCalls == 1);
        static if (withTls) {
            assert(value == 42);
            assert(calls == 1);
            value = 7;
        }
        foreach (i; 0 .. 2) {
            auto thread = new Thread(&worker);
            thread.start;
            thread.join;
        }
        assert(sharedCalls == 1);
        static if (withTls) {
            assert(value == 7);
            assert(calls == 1);
        }
    }
};


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot run thread-local module initialization"),
)) {
    @("threadModuleConstructorBeforeCallback." ~ backend.stringof
        ~ ".sharedOnly")
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, threadConstructorsGuest!false);
    }
}


static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the mixin runs a thread-local constructor on one thread only"),
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot run thread-local module initialization"),
)) {
    @("threadModuleConstructorBeforeCallback." ~ backend.stringof
        ~ ".withTls")
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, threadConstructorsGuest!true);
    }
}


// A trace function for the functions of `pragma(crt_constructor)` and
// `pragma(crt_destructor)`. Compiled D runs them with no druntime, so they
// cannot call `trace`, which uses the GC.
private enum crtTrace = q{
    void crtTrace(string text) {
        import core.stdc.stdio: fclose, fopen, fwrite;
        auto file = fopen(traceFile.ptr, "a");
        fwrite(text.ptr, 1, text.length, file);
        fclose(file);
    }
};


// Runs `code` as a whole program the way compiled D runs it, module
// constructors and destructors included, and returns the exit status. The
// guest finds `traceFile`, a path in `sandbox`, and writes what it observed
// there. The tests below state the trace of compiled D as a literal. The
// constructors and destructors of a mixin run when `bin/ut` starts and ends,
// not around `main`, so the `Native` arm cannot make a trace of their order
// with `main`.
private int programStatus(Backend)(in Sandbox sandbox, in string code) {
    const source = "enum traceFile = `" ~ sandbox.inSandboxPath("trace")
        ~ "`;\nvoid trace(string text) {"
        ~ " import std.file: append; traceFile.append(text); }\n"
        ~ crtTrace ~ code;
    auto program = Program([parseSnippet(source)]);
    auto instance = Owned!Backend(program);
    return run(instance, program);
}


static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the mixin runs module constructors and destructors when `bin/ut` starts and ends, not around the guest `main`"),
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot write files"),
)) {
    @("moduleDestructorRunsAfterMain." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const sandbox = Sandbox();
        programStatus!backend(sandbox, q{
            shared static ~this() { trace("dtor;"); }
            void main() { trace("main;"); }
        }).should == 0;
        sandbox.shouldEqualContent("trace", "main;dtor;");
    }
}


// Destructors run in the reverse of declaration order. The main thread's
// `static ~this` run before every `shared static ~this`.
static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the mixin runs module constructors and destructors when `bin/ut` starts and ends, not around the guest `main`"),
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot write files"),
)) {
    @("moduleDestructorsRunInReverseOrder." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const sandbox = Sandbox();
        programStatus!backend(sandbox, q{
            shared static ~this() { trace("s1;"); }
            static ~this() { trace("t1;"); }
            shared static ~this() { trace("s2;"); }
            static ~this() { trace("t2;"); }
            void main() { trace("main;"); }
        }).should == 0;
        sandbox.shouldEqualContent("trace", "main;t2;t1;s2;s1;");
    }
}


static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the mixin runs module constructors and destructors when `bin/ut` starts and ends, not around the guest `main`"),
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot write files"),
)) {
    @("moduleDestructorRunsAfterMainThrows." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const sandbox = Sandbox();
        programStatus!backend(sandbox, q{
            shared static ~this() { trace("dtor;"); }
            void main() {
                trace("main;");
                throw new Exception("main failed");
            }
        }).should == 1;
        sandbox.shouldEqualContent("trace", "main;dtor;");
    }
}


// An exception from a destructor ends the destructor phase: the destructors
// that would run after it do not, and a program that succeeded now fails.
static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the mixin runs module constructors and destructors when `bin/ut` starts and ends, not around the guest `main`"),
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot write files"),
)) {
    @("moduleDestructorThatThrowsFailsTheProgram." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const sandbox = Sandbox();
        programStatus!backend(sandbox, q{
            shared static ~this() { trace("first declared;"); }
            shared static ~this() {
                trace("last declared;");
                throw new Exception("dtor failed");
            }
            void main() { trace("main;"); }
        }).should == 1;
        sandbox.shouldEqualContent("trace", "main;last declared;");
    }
}


// druntime searches for finalizers when a registration ends, and the search
// is not safe while another thread makes objects. A program that ends has
// no finalizer to find in what it registered, so no search is made.
static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the mixin runs module constructors and destructors when `bin/ut` starts and ends, not around the guest `main`"),
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot run module destructors"),
)) {
    @("programWithModuleDestructorEndsWithoutFinalizerSearch." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const before = finalizerSearches;

        0.shouldBeStatusOf!(backend, q{
            shared static ~this() {}
            void main() {}
        });

        finalizerSearches.should == before;
    }
}


// A program whose startup failed never ran its module destructors.
static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the mixin runs module constructors and destructors when `bin/ut` starts and ends, not around the guest `main`"),
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot write files"),
)) {
    @("moduleDestructorDoesNotRunAfterFailedConstructor." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const sandbox = Sandbox();
        programStatus!backend(sandbox, q{
            shared static this() { trace("ctor1;"); }
            shared static this() { throw new Exception("ctor failed"); }
            shared static ~this() { trace("dtor;"); }
            void main() { trace("main;"); }
        }).should == 1;
        sandbox.shouldEqualContent("trace", "ctor1;");
    }
}


// `pragma(crt_constructor)` functions run before every module constructor,
// and `pragma(crt_destructor)` functions run after every module destructor.
static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the mixin runs module constructors and destructors when `bin/ut` starts and ends, not around the guest `main`"),
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot write files"),
)) {
    @("crtFunctionsSurroundTheModulePhases." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const sandbox = Sandbox();
        programStatus!backend(sandbox, q{
            pragma(crt_destructor) void crtDestructor() { crtTrace("crt-dtor;"); }
            shared static ~this() { trace("dtor;"); }
            shared static this() { trace("ctor;"); }
            pragma(crt_constructor) void crtConstructor() { crtTrace("crt-ctor;"); }
            void main() { trace("main;"); }
        }).should == 0;
        sandbox.shouldEqualContent(
            "trace", "crt-ctor;ctor;main;dtor;crt-dtor;");
    }
}


// The `crt_constructor` functions run in declaration order and the
// `crt_destructor` functions in the reverse order.
static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the mixin runs module constructors and destructors when `bin/ut` starts and ends, not around the guest `main`"),
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot write files"),
)) {
    @("crtFunctionsRunInDeclarationOrder." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const sandbox = Sandbox();
        programStatus!backend(sandbox, q{
            pragma(crt_constructor) void first() { crtTrace("c1;"); }
            pragma(crt_destructor) void third() { crtTrace("d1;"); }
            pragma(crt_constructor) void second() { crtTrace("c2;"); }
            pragma(crt_destructor) void fourth() { crtTrace("d2;"); }
            void main() { trace("main;"); }
        }).should == 0;
        sandbox.shouldEqualContent("trace", "c1;c2;main;d2;d1;");
    }
}


static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the mixin runs module constructors and destructors when `bin/ut` starts and ends, not around the guest `main`"),
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot write files"),
)) {
    @("crtDestructorRunsAfterMainThrows." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const sandbox = Sandbox();
        programStatus!backend(sandbox, q{
            pragma(crt_destructor) void crtDestructor() { crtTrace("crt-dtor;"); }
            shared static ~this() { trace("dtor;"); }
            void main() {
                trace("main;");
                throw new Exception("main failed");
            }
        }).should == 1;
        sandbox.shouldEqualContent("trace", "main;dtor;crt-dtor;");
    }
}


// A failed module constructor skips the module destructors but not the
// `crt_destructor` functions.
static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the mixin runs module constructors and destructors when `bin/ut` starts and ends, not around the guest `main`"),
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot write files"),
)) {
    @("crtDestructorRunsAfterFailedConstructor." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const sandbox = Sandbox();
        programStatus!backend(sandbox, q{
            pragma(crt_constructor) void crtConstructor() { crtTrace("crt-ctor;"); }
            pragma(crt_destructor) void crtDestructor() { crtTrace("crt-dtor;"); }
            shared static this() { throw new Exception("ctor failed"); }
            shared static ~this() { trace("dtor;"); }
            void main() { trace("main;"); }
        }).should == 1;
        sandbox.shouldEqualContent("trace", "crt-ctor;crt-dtor;");
    }
}


// A process that runs a program twice runs the `crt_constructor` and
// `crt_destructor` functions once for each run.
static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the mixin runs module constructors and destructors when `bin/ut` starts and ends, not around the guest `main`"),
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot write files"),
)) {
    @("crtFunctionsRunOnceForEachProgramRun." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const sandbox = Sandbox();
        const code = q{
            pragma(crt_constructor) void crtConstructor() { crtTrace("crt-ctor;"); }
            pragma(crt_destructor) void crtDestructor() { crtTrace("crt-dtor;"); }
            void main() { trace("main;"); }
        };
        programStatus!backend(sandbox, code).should == 0;
        programStatus!backend(sandbox, code).should == 0;
        sandbox.shouldEqualContent("trace",
            "crt-ctor;main;crt-dtor;crt-ctor;main;crt-dtor;");
    }
}


// A thread's `static ~this` runs when that thread ends, before a `join` on
// it returns.
static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the mixin runs module constructors and destructors when `bin/ut` starts and ends, not around the guest `main`"),
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot write files"),
)) {
    @("threadDestructorRunsWhenThreadEnds." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const sandbox = Sandbox();
        programStatus!backend(sandbox, q{
            import core.thread: Thread;

            static ~this() { trace("dtor;"); }

            void main() {
                auto thread = new Thread({ trace("worker;"); });
                thread.start;
                thread.join;
                trace("main;");
            }
        }).should == 0;
        sandbox.shouldEqualContent("trace", "worker;dtor;main;dtor;");
    }
}


// dmd guards a module destructor of a template instance with a gate: more
// than one module can emit the same instance. The module's constructor phase
// increments the gate (dmd glue, `callFuncsAndGates`), and the destructor
// runs its body only when it decrements the gate to zero.
static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the mixin runs module constructors and destructors when `bin/ut` starts and ends, not around the guest `main`"),
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot write files"),
)) {
    @("moduleDestructorOfTemplateInstanceRuns." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const sandbox = Sandbox();
        programStatus!backend(sandbox, q{
            struct Holder(T) {
                shared static ~this() { trace("shared;"); }
                static ~this() { trace("thread;"); }
            }

            void main() {
                Holder!int holder;
                trace("main;");
            }
        }).should == 0;
        sandbox.shouldEqualContent("trace", "main;thread;shared;");
    }
}


// dmd emits the gate of a thread-local destructor as one variable for the
// process, not one for each thread. Thus the destructor body runs only on
// the last thread that ends.
static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the mixin runs module constructors and destructors when `bin/ut` starts and ends, not around the guest `main`"),
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot write files"),
)) {
    @("threadDestructorOfTemplateInstanceRunsWhenThreadEnds." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const sandbox = Sandbox();
        programStatus!backend(sandbox, q{
            import core.thread: Thread;

            struct Holder(T) {
                static ~this() { trace("dtor;"); }
            }

            void main() {
                Holder!int holder;
                auto thread = new Thread({ trace("worker;"); });
                thread.start;
                thread.join;
                trace("main;");
            }
        }).should == 0;
        sandbox.shouldEqualContent("trace", "worker;main;dtor;");
    }
}


// druntime runs the thread-local constructors and destructors on every thread
// it starts, also on one that calls no function of the program.
static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the mixin runs module constructors and destructors when `bin/ut` starts and ends, not around the guest `main`"),
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot write files"),
)) {
    @("threadConstructorRunsOnThreadThatCallsNoProgramCode." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const sandbox = Sandbox();
        programStatus!backend(sandbox, q{
            import std.parallelism: TaskPool;

            static this() { trace("ctor;"); }
            static ~this() { trace("dtor;"); }

            void main() {
                auto pool = new TaskPool(1);
                pool.finish(true);
                trace("main;");
            }
        }).should == 0;
        sandbox.shouldEqualContent("trace", "ctor;ctor;dtor;main;dtor;");
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

// dmd's glue layer visits struct and class members looking for static
// constructors ("There might be static ctors in the members"), because a
// `static this()` / `shared static this()` declared inside an aggregate is
// still a module constructor, run by druntime before `main`, not a per-type
// constructor like the aggregate's own `this()`.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "static variable cannot be read at compile time"),
)) {
    @("staticCtorInsideAggregateRuns." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            __gshared int trace;

            struct StructWithCtor {
                shared static this() {
                    trace = trace * 10 + 1;
                }

                static this() {
                    trace = trace * 10 + 2;
                }
            }

            class ClassWithCtor {
                static this() {
                    trace = trace * 10 + 3;
                }
            }

            void main() {
                assert(trace == 123);
            }
        });
    }
}

// dmd's glue layer also visits an `Nspace` (`extern(C++, ns) { ... }`) for
// exactly the same reason as an aggregate: a `static this()` / `shared
// static this()` declared inside one is still a module constructor. dmd
// deprecates giving a static constructor non-D linkage this way, but still
// runs it, so this must too.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "static variable cannot be read at compile time"),
)) {
    @("staticCtorInsideNamespaceRuns." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            __gshared int trace;

            extern(C++, ns) {
                shared static this() {
                    trace = trace * 10 + 1;
                }

                static this() {
                    trace = trace * 10 + 2;
                }
            }

            void main() {
                assert(trace == 12);
            }
        });
    }
}

// unit-threaded's `Gen!T` shape: a `shared static this()` inside a struct
// template, initialising a `static const` field the template's own members
// read. `main` instantiates `Gen!dchar` only inside a nested function, but
// dmd still appends the instance to the module's own members, not to
// `main`'s body (templatesem.d, `appendToModuleMember`). The instance's
// `StructDeclaration` is only reachable through `TemplateInstance.members`.
// The test above, for a plain struct, never crosses a template instance to
// reach its aggregate; this one pins the instance-then-aggregate descent
// that the plain struct test cannot.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "static variable cannot be read at compile time"),
)) {
    @("staticCtorInsideStructTemplateRuns." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Gen(T) {
                static const dchar[] charset;
                shared static this() {
                    charset = [cast(dchar) 'a', 'b', 'c'];
                }
            }

            void main() {
                auto use() {
                    Gen!dchar g;
                    return Gen!dchar.charset.length;
                }
                assert(use() == 3);
            }
        });
    }
}

// A function literal passed as a template alias argument makes the
// instance nested in the function that names it. The constructor has no
// locals, so its frame is empty. Its address must still be a real
// context, as it is in compiled D.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("staticCtorWithFunctionLiteralRuns." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Wrapper(alias f) {
                int value;
                int get() { return f(value); }
            }
            auto wrap(alias f)(int value) { return Wrapper!f(value); }
            __gshared int trace;
            shared static this() {
                trace = wrap!(a => a + 1)(2).get;
            }
            void main() {
                assert(trace == 3);
            }
        });
    }
}

// unit-threaded's `Gen!string` shape: the same literal in a
// `shared static this()` inside a struct template.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "static variable cannot be read at compile time"),
)) {
    @("staticCtorInsideStructTemplateWithFunctionLiteralRuns."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Wrapper(alias f) {
                int value;
                int get() { return f(value); }
            }
            auto wrap(alias f)(int value) { return Wrapper!f(value); }
            struct Gen(T) {
                static const int answer;
                shared static this() {
                    answer = wrap!(a => a + 1)(2).get;
                }
            }
            void main() {
                Gen!int g;
                assert(Gen!int.answer == 3);
            }
        });
    }
}

// The same nested instance from an ordinary function with an empty
// frame. Nothing here is specific to module constructors.
static foreach (backend; Matrix!()) {
    @("nestedInstanceFromEmptyFrameRuns." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Wrapper(alias f) {
                int value;
                int get() { return f(value); }
            }
            auto wrap(alias f)(int value) { return Wrapper!f(value); }
            int compute() { return wrap!(a => a + 1)(2).get; }
            void main() {
                assert(compute() == 3);
            }
        });
    }
}

// dmd appends every template instance to the root module's members, even
// one it will not emit, so that `needsCodegen()` can make that call later
// (templatesem.d, `appendToModuleMember`). dmd's glue layer checks
// `needsCodegen()` before it descends into an instance (glue/toobj.d,
// `visit(TemplateInstance)`), and skips this one: `__traits(compiles)`
// instantiates `NeverInstantiated!int` only to check that it compiles, so
// dmd never emits it or runs its `static this()`. The walk here must make
// the same check, or it runs a static ctor dmd never does.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "static variable cannot be read at compile time"),
)) {
    @("staticCtorInsideSpeculativeTemplateDoesNotRun." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            __gshared int trace;

            struct NeverInstantiated(T) {
                static if (is(T == int)) {
                    static this() { trace = 999; }
                }
                int dummy;
            }

            enum bool compiles = __traits(compiles, {
                NeverInstantiated!int x;
            });

            void main() {
                assert(trace == 0);
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

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read a runtime-initialized immutable variable"),
)) {
    @("importedRuntimeInitializedImmutable." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.memory: pageSize;
            void main() {
                assert(pageSize > 0);
                assert((pageSize & (pageSize - 1)) == 0);
            }
        });
    }
}


// A thread that a module destructor starts can stay alive after its program
// ends. When it ends later, it must not run the thread-local destructors of
// a different program that runs at that time.
static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the mixin runs module constructors and destructors when `bin/ut` starts and ends, not around the guest `main`"),
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot write files"),
)) {
    @("threadOfEndedProgramDoesNotRunDestructorsOfLaterProgram."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const sandbox = Sandbox();
        programStatus!backend(sandbox, q{
            import core.thread: Thread;
            import core.time: msecs;
            static ~this() {}
            shared static ~this() {
                new Thread({ Thread.sleep(100.msecs); }).start;
            }
            void main() {}
        }).should == 0;
        programStatus!backend(sandbox, q{
            import core.thread: Thread;
            import core.time: msecs;
            static ~this() { trace("second program;"); }
            void main() { Thread.sleep(300.msecs); }
        }).should == 0;
        sandbox.shouldEqualContent("trace", "second program;");
    }
}
