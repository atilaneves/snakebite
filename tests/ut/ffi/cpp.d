module ut.ffi.cpp;


import ut;
import ut.backends;
import snakebite.backends.backend: Program;
import snakebite.dependencyimage: defaultCompiler, prepareImage;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;
import std.file: mkdirRecurse, tempDir;
import std.path: buildPath;


// The C++ test library for issue #336: free functions over integers,
// doubles and a struct; a class with a non-virtual method, a virtual
// method, and a derived class overriding it; a non-trivially-copyable
// type (a user-declared copy constructor) passed and returned by
// value; a function that throws; and a template the library never
// instantiates. Every test in this module reaches it through the
// dependency image (`prepareImage`'s own `cppSource` parameter), never
// through a build target of its own.
private enum cppSource = q"CPP
struct Point {
    int x;
    int y;
};

int add_ints(int a, int b) { return a + b; }
double add_doubles(double a, double b) { return a + b; }
int sum_point(Point p) { return p.x + p.y; }

// Neither class declares a destructor: an `extern(C++)` class in D
// mirrors the C++ side's own virtual function order to compute the
// right vtable slot (`ClassDeclaration.vtblIndex`), and a virtual
// destructor the D side never repeats would shift every slot after it.
//
// Every method is defined out of its class body, not inline: an
// unused inline definition is not guaranteed a symbol in the compiled
// object at all, and this library's whole point is to be called from
// outside its own translation unit.
class Base {
public:
    int non_virtual_value();
    virtual int virtual_value();
};

class Derived : public Base {
public:
    int virtual_value() override;
};

int Base::non_virtual_value() { return 10; }
int Base::virtual_value() { return 1; }
int Derived::virtual_value() { return 2; }

static Base baseInstance;
static Derived derivedInstance;

Base* get_base() { return &baseInstance; }
Base* get_derived_as_base() { return &derivedInstance; }

struct NonPod {
    int value;
    NonPod(int v);
    NonPod(const NonPod& other);
};

NonPod::NonPod(int v) : value(v) {}
NonPod::NonPod(const NonPod& other) : value(other.value) {}

int read_non_pod(NonPod n) { return n.value; }
NonPod make_non_pod(int v) { return NonPod(v); }

#include <stdexcept>
void throws_exception() { throw std::runtime_error("boom"); }

// Never instantiated anywhere in this file: its mangled name never
// reaches the compiled object.
template <typename T>
T uninstantiated_template(T value) { return value; }
CPP";


// The D side's own `extern(C++)` declarations for `cppSource`, shared
// by every guest snippet below.
private enum cppBindings = q{
    extern(C++) struct Point { int x; int y; }
    extern(C++) int add_ints(int a, int b);
    extern(C++) double add_doubles(double a, double b);
    extern(C++) int sum_point(Point p);

    // D class methods are virtual by default, unlike C++'s: `final`
    // here is what keeps `non_virtual_value` out of the vtable, so it
    // does not shift `virtual_value` off the real Itanium slot `0`.
    extern(C++) class Base {
        final int non_virtual_value();
        int virtual_value();
    }
    extern(C++) class Derived : Base {
        override int virtual_value();
    }
    extern(C++) Base get_base();
    extern(C++) Base get_derived_as_base();

    // A user-declared copy constructor is enough for dmd's own `isPOD`
    // to call this type non-trivially-copyable - the same fact the
    // Itanium ABI turns into "pass and return by hidden reference" -
    // whether or not guest code ever calls the constructor itself.
    extern(C++) struct NonPod {
        int value;
        this(ref const(NonPod) other);
    }
    extern(C++) int read_non_pod(NonPod n);
    extern(C++) NonPod make_non_pod(int v);

    extern(C++) void throws_exception();
    extern(C++) T uninstantiated_template(T)(T value);
};


// One cache directory, shared by every test in this module the same
// way `ut.ffi.symbol`'s `sharedImageCache` is: the image cache keys by
// content, so a repeat build of the same `cppSource` is free.
private string cppImageCache() {
    static string directory;
    if (directory is null) {
        directory = buildPath(tempDir(), "snakebite-cpp-image-test-cache");
        mkdirRecurse(directory);
    }
    return directory;
}

private auto cppImage() {
    return prepareImage(
        "", cppImageCache, defaultCompiler, null, null, null, null,
        null, null, cppSource,
    );
}


static foreach (backend; Matrix!(Omit!(Ctfe, Because.inexpressible,
    "CTFE cannot call a function in a loaded native image"))) {
    @("cpp.freeFunctions." ~ backend.stringof)
    @Serial
    unittest {
        static if (is(backend == Native)) {
            // The oracle: what the C++ library's own source computes.
            (3 + 4).should == 7;
            (1.5 + 2.5).should == 4.0;
            (5 + 6).should == 11;
        } else {
            auto image = cppImage;
            auto module_ = parseSnippet(cppBindings ~ q{
                int callAddInts(int a, int b) { return add_ints(a, b); }
                double callAddDoubles(double a, double b) {
                    return add_doubles(a, b);
                }
                int callSumPoint(int x, int y) {
                    auto p = Point(x, y);
                    return sum_point(p);
                }
            });
            auto program = Program([module_]);
            program.dependencyImage = &image;
            scope instance = new backend(program);

            int a = 3, b = 4;
            int intResult;
            instance.call(findFunction(module_, "callAddInts"), &intResult,
                [cast(void*) &a, cast(void*) &b]);
            intResult.should == 7;

            double x = 1.5, y = 2.5;
            double doubleResult;
            instance.call(findFunction(module_, "callAddDoubles"),
                &doubleResult, [cast(void*) &x, cast(void*) &y]);
            doubleResult.should == 4.0;

            int px = 5, py = 6;
            int pointResult;
            instance.call(findFunction(module_, "callSumPoint"),
                &pointResult, [cast(void*) &px, cast(void*) &py]);
            pointResult.should == 11;
        }
    }
}


static foreach (backend; Matrix!(Omit!(Ctfe, Because.inexpressible,
    "CTFE cannot call a function in a loaded native image"))) {
    @("cpp.methods." ~ backend.stringof)
    @Serial
    unittest {
        static if (is(backend == Native)) {
            // The oracle: a plain D class hierarchy shaped the same way,
            // proving what a non-virtual call and a virtual override
            // through a base reference must return.
            class Base {
                int nonVirtualValue() { return 10; }
                int virtualValue() { return 1; }
            }
            class Derived : Base {
                override int virtualValue() { return 2; }
            }
            Base base = new Base;
            Base derivedAsBase = new Derived;
            base.nonVirtualValue.should == 10;
            derivedAsBase.virtualValue.should == 2;
        } else {
            auto image = cppImage;
            auto module_ = parseSnippet(cppBindings ~ q{
                int callNonVirtual() { return get_base().non_virtual_value(); }
                int callBaseVirtual() { return get_base().virtual_value(); }
                int callDerivedVirtual() {
                    return get_derived_as_base().virtual_value();
                }
            });
            auto program = Program([module_]);
            program.dependencyImage = &image;
            scope instance = new backend(program);

            int result;
            instance.call(
                findFunction(module_, "callNonVirtual"), &result, []);
            result.should == 10;

            instance.call(
                findFunction(module_, "callBaseVirtual"), &result, []);
            result.should == 1;

            // The receiver's own dynamic type - `Derived`, read out of
            // its real Itanium vtable - decides which override runs, not
            // `get_derived_as_base`'s declared `Base` return type.
            instance.call(
                findFunction(module_, "callDerivedVirtual"), &result, []);
            result.should == 2;
        }
    }
}


static foreach (backend; Matrix!(Omit!(Ctfe, Because.inexpressible,
    "CTFE cannot call a function in a loaded native image"))) {
    @("cpp.nonPod.passedAndReturnedByValue." ~ backend.stringof)
    @Serial
    unittest {
        static if (is(backend == Native)) {
            17.should == 17;
        } else {
            auto image = cppImage;
            auto module_ = parseSnippet(cppBindings ~ q{
                // `make_non_pod(v)` is passed straight through, not
                // bound to a named local first: dmd only inserts an
                // extra copy-constructor call when copying a named
                // lvalue into a by-value parameter, never when an
                // rvalue already sits in exactly the storage the
                // parameter needs. This keeps the round trip to the
                // two ABI facts issue #336 asks for - a hidden-pointer
                // return and a hidden-reference parameter - without
                // also needing a guest-side copy constructor call,
                // which is a separate, general gap in both backends'
                // support for D's copy-constructor feature, not
                // specific to `extern(C++)` or the barrier.
                int roundTrip(int v) {
                    return read_non_pod(make_non_pod(v));
                }
            });
            auto program = Program([module_]);
            program.dependencyImage = &image;
            scope instance = new backend(program);

            int v = 17;
            int result;
            instance.call(findFunction(module_, "roundTrip"), &result,
                [cast(void*) &v]);
            result.should == 17;
        }
    }
}


static foreach (backend; Matrix!(Omit!(Ctfe, Because.inexpressible,
    "CTFE cannot call a function in a loaded native image"))) {
    @("cpp.uninstantiatedTemplate.refusedByName." ~ backend.stringof)
    @Serial
    unittest {
        static if (is(backend == Native)) {
            // Compiled D never reaches this call either: the linker
            // would refuse the same missing symbol.
            true.should == true;
        } else {
            auto image = cppImage;
            auto module_ = parseSnippet(cppBindings ~ q{
                int callUninstantiated() {
                    return uninstantiated_template!int(3);
                }
            });
            auto program = Program([module_]);
            program.dependencyImage = &image;
            scope instance = new backend(program);

            int result;
            try {
                instance.call(
                    findFunction(module_, "callUninstantiated"), &result, []);
                assert(false, "expected ffi to refuse the missing symbol");
            } catch (Exception exception) {
                "it is not in this process".shouldBeIn(exception.msg);
            }
        }
    }
}


// A C++ exception unwinding past every frame this project owns must
// end the process the same way it would in compiled D: nothing here
// catches or translates it (ADR-0004), and a D `catch (Throwable)`
// never matches a foreign exception's own type tag, so it is never
// caught either. Checking that means letting the exception actually
// run off the top of a process, which only a child process can survive
// checking - `cpp.exception.child` is that child's own body, never run
// by the suite directly; `cpp.exception.terminatesUncaught.*` spawns
// `bin/ut` filtered to it, with the backend named through an
// environment variable, and reads back how the child ended.
private enum childBackendVar = "SNAKEBITE_CPP_EXCEPTION_BACKEND";
private enum caughtMarker = "SNAKEBITE_CPP_EXCEPTION_CAUGHT";

@("cpp.exception.child")
unittest {
    import std.process: environment;

    const backendName = environment.get(childBackendVar);
    if (backendName is null)
        return;

    auto image = cppImage;
    auto module_ = parseSnippet(cppBindings ~ q{
        int callThrows() {
            try {
                throws_exception();
            } catch (Throwable) {
                return 999;
            }
            return 0;
        }
    });
    auto program = Program([module_]);
    program.dependencyImage = &image;

    int result;
    void runOn(BackendType)() {
        scope instance = new BackendType(program);
        instance.call(findFunction(module_, "callThrows"), &result, []);
    }

    if (backendName == "Interpreter")
        runOn!Interpreter;
    else if (backendName == "Bytecode")
        runOn!Bytecode;
    else
        assert(false, "cpp.exception.child: unknown backend " ~ backendName);

    // Only reached if the guest's own `catch (Throwable)` caught the
    // C++ exception - the outcome ADR-0004 rules out.
    import core.stdc.stdio: printf;
    printf(caughtMarker ~ " %d\n", result);
}

static foreach (backendName; ["Interpreter", "Bytecode"]) {
    @("cpp.exception.terminatesUncaught." ~ backendName)
    unittest {
        import std.algorithm: canFind;
        import std.file: thisExePath;
        import std.process: execute;

        string[string] env = [childBackendVar: backendName];
        const result = execute(
            [thisExePath, "ut.ffi.cpp.cpp.exception.child"], env);

        result.output.canFind(caughtMarker).should == false;
        // Either the process is killed by a signal (`std.process.wait`
        // reports that as a negative status) or it exits with a
        // non-zero code - either way, not the caught-and-returned
        // outcome above.
        (result.status != 0).should == true;
    }
}
