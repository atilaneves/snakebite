module ut.backends.call.routing;


// A root-owned callee is interpreted. A non-root declaration uses native
// code, and a missing native symbol for it is an error. Names and packages
// do not decide how a call runs.


import ut.backends;
import snakebite.program: Program;
import snakebite.frontend.compiler: parseSnippet, parseSnippets;
import snakebite.frontend.dmd.functions: findFunction;
import snakebite.language.definition: Definition;
import std.algorithm.searching: canFind;


// A root-owned declaration whose name copies druntime's `_d_*` convention
// is still root-owned, so it is interpreted. No native symbol for it
// exists in this process, so answering 42 at all is only possible by
// walking its body - a name-based rule sending `_d_*` spellings to native
// execution could not.
static foreach (backend; Matrix!()) {
    @("rootOwned.underscoreDName." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                int _d_rootPretender() { return 42; }
                int answer() { return _d_rootPretender(); }
            },
            "answer",
        );
    }
}

private enum importedLiteralModule = q{
    module routing_literal_helper;
    struct Helper {
        enum increment = function(int x) { return x + 1; };
    }
};

// A function literal stored in an enum inside an imported, non-template
// struct has a body but no native symbol. Both a direct call and a function
// pointer must use that body.
static foreach (backend; Matrix!()) {
    @("importedStructFunctionLiteral.directAndPointer."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        static if (is(backend == Native)) {
            struct Helper {
                enum increment = function(int x) { return x + 1; };
            }

            const direct = Helper.increment(41);
            int function(int) pointer = Helper.increment;
            (direct + pointer(0)).should == 43;
        } else {
            auto modules = parseSnippets([
                q{
                    module routing_literal_root;
                    import routing_literal_helper: Helper;

                    int answer() {
                        const direct = Helper.increment(41);
                        int function(int) pointer = Helper.increment;
                        return direct + pointer(0);
                    }
                },
                importedLiteralModule,
            ]);
            auto function_ = findFunction(modules[0], "answer");
            auto backend_ = ownedBackend!backend(Program([modules[0]]));

            int result;
            backend_.call(function_, &result, []);
            result.should == 43;
        }
    }
}


// ADR-0009, decision 3: a dependency function with no native symbol is an
// error for the missing symbol, with or without a body, as the link of a
// native build reports it. No archive holds `routing_helper`. A direct call
// and the address of the function each end with an error that names the
// symbol; the body, which would answer 42, does not run.
private enum missingHelperModule = q{
    module routing_helper;
    int fortyTwo() { return 42; }
    extern(C) int cFortyTwo() { return 42; }
};

static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "a missing symbol fails the native link before a test can run"),
    Omit!(Ctfe, Because.inexpressible,
        "CTFE runs each body from source and calls no native code"),
    Omit!(LoadedBytecode, Because.inexpressible,
        "a save compiles every function, so the missing symbol ends the "
        ~ "save, before the call that the test expects to fail"),
)) {
    @("nonRootOwned.missingNativeIsAnError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        auto modules = parseSnippets([
            q{
                module routing_root;
                import routing_helper;
                int direct() { return fortyTwo(); }
                int cDirect() { return cFortyTwo(); }
                int address() {
                    auto pointer = &fortyTwo;
                    return pointer();
                }
            },
            missingHelperModule,
        ]);
        auto program = Program([modules[0]]);
        auto backend_ = ownedBackend!backend(program);

        // On the bytecode backend a call through the address of a function
        // with no definition is a memory fault that ends the process with a
        // line that names the symbol. A test process cannot survive it, so
        // `call_through_address` of
        // `test_saved_program_that_uses_an_absent_symbol_fails_when_the_use_runs`
        // in `tests/run_cli.py` states that use.
        static if (is(backend == Bytecode))
            enum entries = [
                ["direct", "_D14routing_helper8fortyTwoFZi"],
                ["cDirect", "`cFortyTwo`"],
            ];
        else
            enum entries = [
                ["direct", "_D14routing_helper8fortyTwoFZi"],
                ["cDirect", "`cFortyTwo`"],
                ["address", "_D14routing_helper8fortyTwoFZi"],
            ];
        static foreach (entry; entries) {{
            int result;
            const thrown = backend_
                .call(findFunction(modules[0], entry[0]), &result, [])
                .shouldThrow;
            entry[1].should.be in thrown.msg;
        }}
    }
}


// ADR-0009, decision 3 holds for data and class information too: a variable
// or a class of a dependency that the process does not have is an error that
// names the symbol, not a reason to use the program's own copy. No archive
// holds `routing_data`.
private enum missingDataModule = q{
    module routing_data;
    __gshared int sharedValue = 3;
    int threadValue = 4;
    class Missing { int field; }
};

static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "a missing symbol fails the native link before a test can run"),
    Omit!(Ctfe, Because.inexpressible,
        "CTFE runs each body from source and reads no native data"),
    Omit!(LoadedBytecode, Because.inexpressible,
        "a save compiles every function, so the missing symbol ends the "
        ~ "save, before the call that the test expects to fail"),
)) {
    @("nonRootOwned.missingNativeDataIsAnError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        auto modules = parseSnippets([
            q{
                module routing_data_root;
                import routing_data;
                int readShared() { return sharedValue; }
                int readThread() { return threadValue; }
                int makeClass() { return (new Missing).field; }
            },
            missingDataModule,
        ]);
        auto backend_ = ownedBackend!backend(Program([modules[0]]));

        // On the bytecode backend a use of a `__gshared` variable or of a
        // class with no definition is a memory fault that ends the process
        // with a line that names the symbol. A test process cannot survive
        // it, so `test_saved_program_that_uses_an_absent_symbol_fails_when_the_use_runs`
        // in `tests/run_cli.py` states those two uses.
        static if (is(backend == Bytecode))
            enum entries = [["readThread", "threadValue"]];
        else
            enum entries = [
                ["readShared", "sharedValue"],
                ["readThread", "threadValue"],
                ["makeClass", "7Missing6__initZ"],
            ];
        static foreach (entry; entries) {{
            int result;
            const thrown = backend_
                .call(findFunction(modules[0], entry[0]), &result, [])
                .shouldThrow;
            entry[1].should.be in thrown.msg;
            "it is not in this process".should.be in thrown.msg;
        }}
    }
}


// What is nested in a function is defined where that function is: another
// object defines the static locals of a dependency function that is not in a
// template instance. The program defines those of a function of its own.
@("whereDefined.nestedInAFunction")
unittest {
    import snakebite.frontend.ast: Identifier;

    auto modules = parseSnippets([
        q{
            module nested_root;
            int own() { static int counter; return ++counter; }
        },
        q{
            module nested_dep;
            int plain() { static int counter; return ++counter; }
        },
    ]);
    auto program = Program([modules[0]]);

    auto local(typeof(findFunction(modules[0], "own")) function_) {
        return function_.localsymtab.lookup(Identifier.idPool("counter"));
    }
    auto plain = findFunction(modules[1], "plain");

    program.whereDefined(local(findFunction(modules[0], "own")))
        .should == Definition.rootOwned;
    program.whereDefined(local(plain)).should == Definition.definedElsewhere;
}


// The native copy of `variadicInstanceModule`'s template instance below. The
// process has it, and its answer differs from the body's, so a call that
// reaches it is told apart from one that runs the body.
private extern(C) int snakebite_ut_variadic_instance_sum(int first, ...) {
    return first + 5000;
}

private enum variadicInstanceModule = q{
    module variadic_instance_dep;
    struct Holder(T) {
        pragma(mangle, "snakebite_ut_variadic_instance_sum")
        extern(C) static int sum(int first, ...) {
            return first + 1000;
        }
    }
};

// A C-variadic function of a dependency template instance has one meaning,
// whether it is called directly or through its address: the body runs
// (ADR-0009, decision 1), even when the process holds a copy of the instance.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE does not run C-style variadic functions"),
)) {
    @("instanceVariadic.directAndAddressAgree." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        static if (is(backend == Native)) {
            extern(C) int sum(T)(T first, ...) { return first + 1000; }

            const direct = sum!int(1, 2);
            extern(C) int function(int, ...) pointer = &sum!int;
            direct.should == 1001;
            pointer(1, 2).should == 1001;
        } else {
            auto modules = parseSnippets([
                q{
                    module variadic_instance_root;
                    import variadic_instance_dep: Holder;

                    int direct() {
                        return Holder!int.sum(1, 2);
                    }
                    int address() {
                        extern(C) int function(int, ...) pointer =
                            &Holder!int.sum;
                        return pointer(1, 2);
                    }
                },
                variadicInstanceModule,
            ]);
            auto backend_ = ownedBackend!backend(Program([modules[0]]));

            foreach (name; ["direct", "address"]) {
                int result;
                backend_.call(findFunction(modules[0], name), &result, []);
                result.should == 1001;
            }
        }
    }
}


// DMD's lowered append call uses the guest-only struct's synthesized TypeInfo
// and runs its body in the interpreter.
@("rootOwned.guestStructAppend.Interpreter")
@Tags("Interpreter")
unittest {
    auto module_ = parseSnippet(q{
        struct OnlyInTheGuest { int value; }

        size_t grown() {
            OnlyInTheGuest[] a;
            a ~= OnlyInTheGuest(42);
            return a.length;
        }
    });
    auto function_ = findFunction(module_, "grown");

    size_t result;
    interpreter(module_).call(function_, &result, []);
    result.should == 1;
}


// A lowered append and its native argument call reuse resolved symbols on a
// second execution.
@("rootOwned.guestStructAppend.reusesResolvedSymbols.Interpreter")
@Tags("Interpreter")
unittest {
    auto module_ = parseSnippet(q{
        struct OnlyInTheGuest { int value; }

        size_t grown() {
            import core.stdc.stdlib: abs;
            OnlyInTheGuest[] a;
            a ~= OnlyInTheGuest(abs(-42));
            return a.length;
        }
    });
    auto function_ = findFunction(module_, "grown");
    auto backend = interpreter(module_);

    size_t result;
    backend.call(function_, &result, []);
    result.should == 1;
    const lookups = backend.symbolLookups;
    backend.call(function_, &result, []);
    result.should == 1;
    backend.symbolLookups.should == lookups;
    assert(lookups >= 1);
}


// Data of a dependency that this process holds. Guest code and native code
// read and write one copy of each variable.
public __gshared int routingSharedCount = 10;
public int routingThreadCount = 20;

public void routingBump() {
    routingSharedCount += 1;
    routingThreadCount += 2;
}

// The declarations of this module that guest code sees. One text for each
// test of this module: two texts for one module name would conflict.
private enum dependencyDataModule = q{
    module ut.backends.call.routing;
    __gshared int routingSharedCount;
    int routingThreadCount;
    void routingBump();

    struct RoutingCounter(T) {
        static int perThread;
        __gshared int everyThread;
    }
    struct RoutingPoint { int x; }
    enum RoutingColour { red, green }
    class RoutingBox(T) { T value; }
    int routingCountNative();
    TypeInfo routingPointInfo();
    TypeInfo routingColourInfo();
    TypeInfo_Class routingBoxInfo();
    bool routingIsBox(Object object);
};

private enum dependencyDataCode = q{
    int answer() {
        routingSharedCount = 100;
        routingThreadCount = 200;
        routingBump();
        routingSharedCount += 10;
        routingThreadCount += 20;
        routingBump();
        return routingSharedCount + routingThreadCount;
    }
};

// The arms of the test below run in parallel and share one variable.
private __gshared Object routingDataLock = new Object;

// A shared and a thread-local variable of a dependency, written and read by
// guest code and by native code.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot call native code"),
)) {
    @("dependencyData.sharedAndThreadLocal.bothSides." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        synchronized (routingDataLock) {
            const sharedBefore = routingSharedCount;
            const threadBefore = routingThreadCount;
            scope(exit) {
                routingSharedCount = sharedBefore;
                routingThreadCount = threadBefore;
            }

            int result;
            static if (is(backend == Native)) {
                mixin(dependencyDataCode);
                result = answer();
            } else {
                auto modules = parseSnippets([
                    "module routing_data_both_root;\n"
                        ~ "import ut.backends.call.routing;\n"
                        ~ dependencyDataCode,
                    dependencyDataModule,
                ]);
                auto backend_ = ownedBackend!backend(Program([modules[0]]));
                backend_.call(findFunction(modules[0], "answer"), &result, []);
            }
            result.should == 112 + 224;
            routingSharedCount.should == 112;
            routingThreadCount.should == 224;
        }
    }
}


// Data that the program and a dependency can both define: a static variable
// of a template instance, the type information of a dependency struct or
// enum, and the class information of an instance of a dependency class
// template. A native build keeps one copy of each, so guest code and native
// code see one copy.
public struct RoutingCounter(T) {
    static int perThread;
    __gshared int everyThread;
}

public struct RoutingPoint { int x; }

public enum RoutingColour { red, green }

public class RoutingBox(T) { T value; }

public int routingCountNative() {
    return ++RoutingCounter!int.perThread * 1000
        + ++RoutingCounter!int.everyThread;
}

public TypeInfo routingPointInfo() { return typeid(RoutingPoint); }

public TypeInfo routingColourInfo() { return typeid(RoutingColour); }

public TypeInfo_Class routingBoxInfo() { return typeid(RoutingBox!int); }

public bool routingIsBox(Object object) {
    return cast(RoutingBox!int) object !is null;
}

private enum sharedDefinitionCode = q{
    // Each side adds one to each variable: with one copy of each, the native
    // side sees the guest side's addition.
    int counters() {
        const before = routingCountNative();
        ++RoutingCounter!int.perThread;
        ++RoutingCounter!int.everyThread;
        return routingCountNative() - before;
    }
    bool sameTypeInfo() {
        return typeid(RoutingPoint) is routingPointInfo()
            && typeid(RoutingColour) is routingColourInfo();
    }
    bool sameClassInfo() {
        auto box = new RoutingBox!int;
        return typeid(RoutingBox!int) is routingBoxInfo()
            && typeid(box) is routingBoxInfo()
            && routingIsBox(box);
    }
};

// The arms of the test below run in parallel and share `everyThread`.
private __gshared Object sharedDefinitionLock = new Object;

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot call native code"),
)) {
    @("sharedDefinition.templateInstanceStatics.oneCopy." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        synchronized (sharedDefinitionLock)
            sharedDefinitionResult!(backend, "counters", int)
                .should == 2002;
    }

    @("sharedDefinition.dependencyTypeInfo.sameObject." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        sharedDefinitionResult!(backend, "sameTypeInfo", bool)
            .should == true;
    }

    @("sharedDefinition.instanceClassInfo.sameObject." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        sharedDefinitionResult!(backend, "sameClassInfo", bool)
            .should == true;
    }
}

// What the function `name` of `sharedDefinitionCode` returns on `backend`.
private Result sharedDefinitionResult(backend, string name, Result)() {
    Result result;
    static if (is(backend == Native)) {
        mixin(sharedDefinitionCode);
        result = mixin(name ~ "()");
    } else {
        auto modules = parseSnippets([
            "module routing_shared_definition_" ~ name ~ ";\n"
                ~ "import ut.backends.call.routing;\n"
                ~ sharedDefinitionCode,
            dependencyDataModule,
        ]);
        auto backend_ = ownedBackend!backend(Program([modules[0]]));
        backend_.call(findFunction(modules[0], name), &result, []);
    }
    return result;
}


// An instance of a dependency class template that the process does not have:
// the program uses its own copy of the class information, and a root class
// over it reaches the interface of that copy, from RAM and after a load.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE does not build class information"),
)) {
    @("sharedDefinition.ownInstanceClassInterface." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        static if (is(backend == Native)) {
            interface Speaker(T) { int speak(); }
            class Talker(T) : Speaker!T { int speak() { return 7; } }
            class Loud : Talker!int {}
            Speaker!int speaker = new Loud;
            const result = speaker.speak() * 10
                + (typeid(Loud).base is typeid(Talker!int));
        } else {
            auto modules = parseSnippets([
                q{
                    module routing_own_instance_root;
                    import routing_own_instance_dep;
                    class Loud : Talker!int {}
                    int answer() {
                        Speaker!int speaker = new Loud;
                        return speaker.speak() * 10
                            + (typeid(Loud).base is typeid(Talker!int));
                    }
                },
                q{
                    module routing_own_instance_dep;
                    interface Speaker(T) { int speak(); }
                    class Talker(T) : Speaker!T { int speak() { return 7; } }
                },
            ]);
            auto backend_ = ownedBackend!backend(Program([modules[0]]));
            int result;
            backend_.call(findFunction(modules[0], "answer"), &result, []);
        }
        result.should == 71;
    }
}


// The native copy of the shared and the thread-local variable of
// `nestedInstanceModule` below. Their values differ from the initial values
// of the instance, so the result tells the copy that is used.
public extern(C) shared int snakebite_ut_nested_shared = 5000;
public extern(C) int snakebite_ut_nested_thread = 7000;

private enum nestedInstanceModule = q{
    module nested_instance_dep;
    int variables(alias f)() {
        pragma(mangle, "snakebite_ut_nested_shared")
        shared static int shared_ = 1000;
        pragma(mangle, "snakebite_ut_nested_thread")
        static int thread = 2000;
        return shared_ + thread + f(1);
    }
    class Box(alias f) { int value; this() { value = f(1); } }
    int made(alias f)() { return (new Box!f).value; }
};

// A template instance of a dependency that holds a function of the root
// module (a lambda that captures a local) is a dependency instance whose
// static variables the process can define too: a native build keeps one copy
// of each.
static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "a native build has one definition of each variable"),
    Omit!(Ctfe, Because.inexpressible,
        "CTFE reads no native data"),
)) {
    @("sharedDefinition.instanceNestedInRootFunction." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        auto modules = parseSnippets([
            q{
                module nested_instance_root;
                import nested_instance_dep;
                int answer() {
                    int local = 10;
                    return variables!(a => a + local)
                        + made!(a => a + local);
                }
            },
            nestedInstanceModule,
        ]);
        auto backend_ = ownedBackend!backend(Program([modules[0]]));

        int result;
        backend_.call(findFunction(modules[0], "answer"), &result, []);
        result.should == 12000 + 11 + 11;
    }
}


// A function of a root module with a body and `extern` storage is declared
// there and defined elsewhere: a call reaches the native function.
public extern(C) int snakebite_ut_extern_body() { return 9; }

static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "a native build has one definition of the function"),
    Omit!(Ctfe, Because.inexpressible,
        "CTFE runs each body from source and calls no native code"),
)) {
    @("rootOwned.externWithBody." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        auto modules = parseSnippets([
            q{
                module extern_body_root;
                pragma(mangle, "snakebite_ut_extern_body")
                extern(C) extern int declared() { return 1; }
                int answer() { return declared(); }
            },
        ]);
        auto backend_ = ownedBackend!backend(Program([modules[0]]));

        int result;
        backend_.call(findFunction(modules[0], "answer"), &result, []);
        result.should == 9;
    }
}
