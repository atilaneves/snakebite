module ut.ffi.cpp;


import ut;
import ut.backends;
import snakebite.backends.backend: Program;
import snakebite.dependencyimage: DependencyImage, loadImage;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;


// The C++ test library (tests/fixtures/native/cpp_image.cpp) is compiled
// into a shared object when `bin/ut` is built, and each test loads it.
// It has: free functions over integers, doubles and a struct; a class with
// a non-virtual method and two virtual methods, one of them overridden by a
// derived class; a method that returns a large struct through the hidden
// return pointer, non-virtual and virtual; a struct (not a class) with its
// own method; a non-trivially-copyable type (a user-declared copy
// constructor and a counting destructor) passed and returned by value; a
// callback that itself takes a non-trivially-copyable value; and a template
// the library never instantiates.


// The D side's own `extern(C++)` declarations for the C++ library, shared
// by every guest snippet below.
private enum cppBindings = q{
    extern(C++) struct Point { int x; int y; }
    extern(C++) int add_ints(int a, int b);
    extern(C++) double add_doubles(double a, double b);
    extern(C++) int sum_point(Point p);

    extern(C++) struct Big { size_t a; size_t b; size_t c; }

    // D class methods are virtual by default, unlike C++'s: `final`
    // here keeps `tag_value` and `big` out of the vtable, so they do
    // not shift `first`, `second` and `bigVirtual` off their real
    // Itanium slots `0`, `1` and `2`.
    extern(C++) class Base {
        final int tag_value();
        int first();
        int second();
        final Big big();
        Big bigVirtual();
    }
    extern(C++) class Derived : Base {
        override int first();
    }
    extern(C++) Base get_base();
    extern(C++) Base get_derived_as_base();
    extern(C++) int call_tag_value(Base b);
    extern(C++) int call_first(Base b);
    extern(C++) int call_second(Base b);
    extern(C++) Big call_big(Base b);
    extern(C++) Big call_big_virtual(Base b);

    extern(C++) struct Vector2 {
        int x;
        int y;
        int sum();
    }

    // A user-declared copy constructor is enough for dmd's own `isPOD`
    // to call this type non-trivially-copyable - the same fact the
    // Itanium ABI turns into "pass and return by hidden reference" -
    // whether or not guest code ever calls the constructor itself.
    // `~this()` must be declared too: D only calls a struct's
    // destructor - on a temporary or on a named local going out of
    // scope - when the D declaration itself says there is one. With
    // no `~this()` here, the real C++ destructor this type has never
    // runs at all, whatever the ABI says about who destroys a by-value
    // argument (issue #336 review, finding 5 - verified against a
    // real dmd-built and ldc-built program each linked to the same
    // compiled C++ object: the destructor's own counter stays `0`
    // without this declaration, and becomes exactly `1` with it).
    extern(C++) struct NonPod {
        int value;
        this(ref const(NonPod) other);
        ~this();
    }
    extern(C++) int read_non_pod(NonPod n);
    extern(C++) NonPod make_non_pod(int v);
    extern(C++) int destroyed_count();

    alias NonPodCallback = extern(C++) int function(NonPod);
    extern(C++) int call_non_pod_callback(NonPodCallback callback, int v);

    extern(C++) T uninstantiated_template(T)(T value);
};

// A second, smaller set of declarations, compiled for real rather
// than only parsed as a guest snippet: the `Native` row of every test
// below takes a function's mangled name from a real declaration here
// (`.mangleof`), resolves it out of the same image the other rows
// call through the barrier, and calls it directly - what compiled D
// itself would do. Never called
// directly itself, only named, so it needs nothing to link against -
// except a virtual method: dmd builds a real reference to one even
// with no call anywhere, the same as compiled D calling into an
// unlinked C++ library would (verified: a minimal extern(C++) class
// with one non-final, body-less method fails to link on its own,
// with no call to it anywhere). So `Base` and `Derived` stay bare
// here, and every method reaches this file only through its own
// free-function wrapper from the C++ library.
private enum nativeBindings = q{
    extern(C++) struct Point { int x; int y; }
    extern(C++) struct Big { size_t a; size_t b; size_t c; }
    // No `Derived` here: every function below that hands one back
    // declares its return type `Base`, matching the C++ side's own
    // `Base*` return - the receiver's dynamic type, not its declared
    // one, is what a virtual call dispatches on. `Derived` itself
    // never needs to be a real, compiled type in this file.
    extern(C++) class Base {}
    extern(C++) struct Vector2 { int x; int y; }
    // No `~this()` here: declaring one would make dmd insert a real,
    // linked call to it wherever this file's own compiled code (the
    // `Native` row below) holds a `NonPod` by value - including inside
    // `resolveNative`'s own callers - and this file never links the
    // compiled C++ object into `bin/ut` itself, only into the shared object
    // that the tests load at run time. See the comment on the
    // `Native` row of `cpp.nonPod.passedAndReturnedByValue` for what
    // this means for that one row.
    extern(C++) struct NonPod {
        int value;
        this(ref const(NonPod) other);
    }
    alias NonPodCallback = extern(C++) int function(NonPod);

    extern(C++) int add_ints(int a, int b);
    extern(C++) double add_doubles(double a, double b);
    extern(C++) int sum_point(Point p);
    extern(C++) Base get_base();
    extern(C++) Base get_derived_as_base();
    extern(C++) int call_tag_value(Base b);
    extern(C++) int call_first(Base b);
    extern(C++) int call_second(Base b);
    extern(C++) Big call_big(Base b);
    extern(C++) Big call_big_virtual(Base b);
    extern(C++) int call_vector_sum(Vector2* v);
    extern(C++) int read_non_pod(NonPod n);
    extern(C++) NonPod make_non_pod(int v);
    extern(C++) int destroyed_count();
    extern(C++) int call_non_pod_callback(NonPodCallback callback, int v);
};
mixin(nativeBindings);


private auto cppImage() {
    return loadImage(nativeFixture("cpp_image.so"));
}

// Resolves `mangledName` out of `image` and returns it as a native
// `Fn`. Every `Native` test row below uses this to call the compiled
// C++ code directly, the same way compiled D would.
private Fn resolveNative(Fn)(in DependencyImage image, string mangledName) {
    auto address = image.resolve(mangledName);
    assert(address !is null, "cpp.d: missing C++ symbol " ~ mangledName);
    return cast(Fn) address;
}

// Named ahead of use: `resolveNative!(extern(C++) ...)` does not parse
// - a template argument list cannot start with `extern` - so every
// `Native` row below names its function pointer type first.
private alias AddIntsFn = extern(C++) int function(int, int);
private alias AddDoublesFn = extern(C++) double function(double, double);
private alias SumPointFn = extern(C++) int function(Point);
private alias GetBaseFn = extern(C++) Base function();
private alias CallIntMethodFn = extern(C++) int function(Base);
private alias CallBigFn = extern(C++) Big function(Base);
private alias CallVectorSumFn = extern(C++) int function(Vector2*);
private alias MakeNonPodFn = extern(C++) NonPod function(int);
private alias ReadNonPodFn = extern(C++) int function(NonPod);
private alias CallWithNonPodCallbackFn =
    extern(C++) int function(NonPodCallback, int);


static foreach (backend; Matrix!(Omit!(Ctfe, Because.inexpressible,
    "CTFE cannot call a function in a loaded native image"))) {
    @("cpp.freeFunctions." ~ backend.stringof)
    @Serial
    unittest {
        static if (is(backend == Native)) {
            auto image = cppImage;
            auto callAddInts =
                resolveNative!AddIntsFn(
                    image, add_ints.mangleof);
            auto callAddDoubles =
                resolveNative!AddDoublesFn(
                    image, add_doubles.mangleof);
            auto callSumPoint =
                resolveNative!SumPointFn(
                    image, sum_point.mangleof);

            callAddInts(3, 4).should == 7;
            callAddDoubles(1.5, 2.5).should == 4.0;
            callSumPoint(Point(5, 6)).should == 11;
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
            auto instance = Owned!backend(program);

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


// A non-virtual method and two virtual ones, each reading a field
// through `this`, called on a `tag = 7` receiver - through a base
// pointer for the derived instance. Compiled-D oracle (a plain D class
// hierarchy shaped the same way, checked against dmd and ldc):
// `tagValue() == 7`, `first() + second() == 770` on the base instance,
// and, through a base pointer to the derived instance, an overridden
// `first()` that differs from the base's own, next to a `second()`
// that does not - so a swapped or off-by-one vtable slot shows up as
// a wrong value, not only a crash.
static foreach (backend; Matrix!(Omit!(Ctfe, Because.inexpressible,
    "CTFE cannot call a function in a loaded native image"))) {
    @("cpp.methods." ~ backend.stringof)
    @Serial
    unittest {
        static if (is(backend == Native)) {
            class DBase {
                private int tag_;
                this(int tag) { tag_ = tag; }
                int tagValue() { return tag_; }
                int first() { return tag_ * 10; }
                int second() { return tag_ * 100; }
            }
            class DDerived : DBase {
                this(int tag) { super(tag); }
                override int first() { return tag_ * 10 + 1; }
            }
            DBase base = new DBase(7);
            DBase derivedAsBase = new DDerived(7);
            base.tagValue.should == 7;
            (base.first + base.second).should == 770;
            derivedAsBase.first.should == 71;
            derivedAsBase.second.should == 700;

            // The same facts, but reached through the compiled C++
            // library itself, by resolved symbol - not a parallel D
            // implementation (issue #336 review, finding 8).
            auto image = cppImage;
            auto getBase =
                resolveNative!GetBaseFn(
                    image, get_base.mangleof);
            auto getDerivedAsBase =
                resolveNative!GetBaseFn(
                    image, get_derived_as_base.mangleof);
            auto callTagValue =
                resolveNative!CallIntMethodFn(
                    image, call_tag_value.mangleof);
            auto callFirst =
                resolveNative!CallIntMethodFn(
                    image, call_first.mangleof);
            auto callSecond =
                resolveNative!CallIntMethodFn(
                    image, call_second.mangleof);

            auto cppBase = getBase();
            auto cppDerivedAsBase = getDerivedAsBase();
            callTagValue(cppBase).should == 7;
            (callFirst(cppBase) + callSecond(cppBase)).should == 770;
            callFirst(cppDerivedAsBase).should == 71;
            callSecond(cppDerivedAsBase).should == 700;
        } else {
            auto image = cppImage;
            auto module_ = parseSnippet(cppBindings ~ q{
                int callTagValue() { return get_base().tag_value(); }
                int callFirstOnBase() { return get_base().first(); }
                int callSecondOnBase() { return get_base().second(); }
                int callFirstOnDerived() {
                    return get_derived_as_base().first();
                }
                int callSecondOnDerived() {
                    return get_derived_as_base().second();
                }
            });
            auto program = Program([module_]);
            program.dependencyImage = &image;
            auto instance = Owned!backend(program);

            int result;
            instance.call(
                findFunction(module_, "callTagValue"), &result, []);
            result.should == 7;

            int first, second;
            instance.call(
                findFunction(module_, "callFirstOnBase"), &first, []);
            instance.call(
                findFunction(module_, "callSecondOnBase"), &second, []);
            (first + second).should == 770;

            // The receiver's own dynamic type - `Derived`, read out of
            // its real Itanium vtable - decides which override runs,
            // not `get_derived_as_base`'s declared `Base` return type.
            // `second` is never overridden, so it must still reach
            // `Base::second` through the same vtable, at its own slot,
            // untouched by `first`'s override at a different slot.
            instance.call(
                findFunction(module_, "callFirstOnDerived"), &result, []);
            result.should == 71;
            instance.call(
                findFunction(module_, "callSecondOnDerived"), &result, []);
            result.should == 700;
        }
    }
}


// A method that returns a 24-byte struct through the hidden return
// pointer, non-virtual and virtual, on a `tag = 7` receiver reached
// through a base pointer. Compiled-D oracle (dmd and ldc): both give
// `{7, 8, 9}`, read back as `a*100 + b*10 + c == 789`. This is the one
// ABI decision `extern(C++)` changes from `extern(D)` on this branch:
// the hidden pointer comes before `this` here, not after
// (`abi.contextPrecedesHiddenReturnPointer`) - a swap would put the
// wrong value in the wrong words, not merely crash (issue #336
// review, finding 4).
static foreach (backend; Matrix!(Omit!(Ctfe, Because.inexpressible,
    "CTFE cannot call a function in a loaded native image"))) {
    @("cpp.methods.structReturnThroughHiddenPointer." ~ backend.stringof)
    @Serial
    unittest {
        static if (is(backend == Native)) {
            auto image = cppImage;
            auto getBase =
                resolveNative!GetBaseFn(
                    image, get_base.mangleof);
            auto callBig =
                resolveNative!CallBigFn(
                    image, call_big.mangleof);
            auto callBigVirtual =
                resolveNative!CallBigFn(
                    image, call_big_virtual.mangleof);

            auto cppBase = getBase();
            const big = callBig(cppBase);
            const bigVirtual = callBigVirtual(cppBase);
            (big.a * 100 + big.b * 10 + big.c).should == 789;
            (bigVirtual.a * 100 + bigVirtual.b * 10 + bigVirtual.c)
                .should == 789;
        } else {
            auto image = cppImage;
            auto module_ = parseSnippet(cppBindings ~ q{
                struct Reading { size_t a; size_t b; size_t c; }
                Reading readBig(Big big) {
                    return Reading(big.a, big.b, big.c);
                }
                Reading callBig() { return readBig(get_base().big()); }
                Reading callBigVirtual() {
                    return readBig(get_base().bigVirtual());
                }
            });
            auto program = Program([module_]);
            program.dependencyImage = &image;
            auto instance = Owned!backend(program);

            static struct Reading { size_t a; size_t b; size_t c; }
            Reading result;
            instance.call(findFunction(module_, "callBig"), &result, []);
            (result.a * 100 + result.b * 10 + result.c).should == 789;

            instance.call(
                findFunction(module_, "callBigVirtual"), &result, []);
            (result.a * 100 + result.b * 10 + result.c).should == 789;
        }
    }
}


// A struct (not a class) with its own method: `this` is a value
// type's address, not a class reference (issue #336 review, finding
// 13).
static foreach (backend; Matrix!(Omit!(Ctfe, Because.inexpressible,
    "CTFE cannot call a function in a loaded native image"))) {
    @("cpp.structMethod." ~ backend.stringof)
    @Serial
    unittest {
        static if (is(backend == Native)) {
            auto image = cppImage;
            auto callVectorSum = resolveNative!CallVectorSumFn(
                image, call_vector_sum.mangleof);
            Vector2 v = Vector2(3, 4);
            callVectorSum(&v).should == 7;
        } else {
            auto image = cppImage;
            auto module_ = parseSnippet(cppBindings ~ q{
                int callVectorSum() {
                    auto v = Vector2(3, 4);
                    return v.sum();
                }
            });
            auto program = Program([module_]);
            program.dependencyImage = &image;
            auto instance = Owned!backend(program);

            int result;
            instance.call(
                findFunction(module_, "callVectorSum"), &result, []);
            result.should == 7;
        }
    }
}


static foreach (backend; Matrix!(Omit!(Ctfe, Because.inexpressible,
    "CTFE cannot call a function in a loaded native image"))) {
    @("cpp.nonPod.passedAndReturnedByValue." ~ backend.stringof)
    @Serial
    unittest {
        static if (is(backend == Native)) {
            auto image = cppImage;
            auto makeNonPod =
                resolveNative!MakeNonPodFn(
                    image, make_non_pod.mangleof);
            auto readNonPod =
                resolveNative!ReadNonPodFn(
                    image, read_non_pod.mangleof);

            readNonPod(makeNonPod(17)).should == 17;
            // No destruction count here: making that observable to
            // this file's own compiled code needs `NonPod` to declare
            // `~this()` (see `nativeBindings`'s own comment on why it
            // does not), and that alone - with no call to it anywhere
            // - makes dmd insert a real, linked call to it in this very
            // function, for the temporary `makeNonPod(17)` builds. This
            // file never links the compiled C++ object into `bin/ut`
            // itself, so that fails to link.
            //
            // The fact this leaves untested on this one row is verified
            // by hand instead: a standalone dmd-built, and a standalone
            // ldc-built, program - each linked directly against a
            // g++-built object of this same `NonPod` and
            // `read_non_pod`/`make_non_pod`, `~this()` declared this
            // time - both count exactly `1` destruction for
            // `read_non_pod(make_non_pod(17))`, matching the oracle
            // the `Interpreter` and `Bytecode` rows below check for
            // real (issue #336 review, finding 5).
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
                int destructionCount(int v) {
                    auto before = destroyed_count();
                    read_non_pod(make_non_pod(v));
                    return destroyed_count() - before;
                }
            });
            auto program = Program([module_]);
            program.dependencyImage = &image;
            auto instance = Owned!backend(program);

            int v = 17;
            int result;
            instance.call(findFunction(module_, "roundTrip"), &result,
                [cast(void*) &v]);
            result.should == 17;

            // The frontend inserts a call to destroy the by-value
            // argument's own temporary into the call expression itself
            // (dmd's `target.isCalleeDestroyingArgs` is false for
            // `LINK.cpp`); a backend that skips it would leave this at
            // `0` (issue #336 review, finding 5).
            int destructionResult;
            instance.call(findFunction(module_, "destructionCount"),
                &destructionResult, [cast(void*) &v]);
            destructionResult.should == 1;
        }
    }
}


// A callback that itself takes a non-trivially-copyable value by
// hidden reference: the reverse plan must unpack that reference the
// same way a forward call's argument does (issue #336 review, finding
// 13).
static foreach (backend; Matrix!(Omit!(Ctfe, Because.inexpressible,
    "CTFE cannot call a function in a loaded native image"))) {
    @("cpp.callback.nonPodArgument." ~ backend.stringof)
    @Serial
    unittest {
        static if (is(backend == Native)) {
            extern(C++) int handler(NonPod n) { return n.value * 2; }
            auto image = cppImage;
            auto callWithCallback = resolveNative!CallWithNonPodCallbackFn(
                image, call_non_pod_callback.mangleof);
            callWithCallback(&handler, 9).should == 18;
        } else {
            auto image = cppImage;
            auto module_ = parseSnippet(cppBindings ~ q{
                extern(C++) int handler(NonPod n) { return n.value * 2; }
                int callWithCallback(int v) {
                    return call_non_pod_callback(&handler, v);
                }
            });
            auto program = Program([module_]);
            program.dependencyImage = &image;
            auto instance = Owned!backend(program);

            int v = 9;
            int result;
            instance.call(findFunction(module_, "callWithCallback"),
                &result, [cast(void*) &v]);
            result.should == 18;
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
            auto instance = Owned!backend(program);

            int result;
            try {
                instance.call(
                    findFunction(module_, "callUninstantiated"), &result, []);
                assert(false, "expected ffi to refuse the missing symbol");
            } catch (Exception exception) {
                "it is not in this process".shouldBeIn(exception.msg);
                // The mangled name itself must be in the message too,
                // so a mangling change breaks this test loudly instead
                // of the message quietly going stale (issue #336
                // review, finding 9). Verified against both dmd's own
                // mangling of the same template instance and `nm` on a
                // real g++-compiled translation unit that instantiates
                // it.
                "_Z23uninstantiated_templateIiET_S0_".shouldBeIn(
                    exception.msg);
            }
        }
    }
}



private extern(C++) class NativeMine {
    int tag_ = 3;
    int first() { return tag_ * 10 + 5; }
    int second() { return tag_ * 100 + 5; }
    Big bigVirtual() { return Big(tag_, tag_ + 1, tag_ + 2); }
}

// The C++ library calls the virtual methods of a class that D defines:
// the vtable slots of an `extern(C++)` class hold functions that C++
// code can call, and the hidden return pointer comes before `this`.
static foreach (backend; Matrix!(Omit!(Ctfe, Because.inexpressible,
    "CTFE cannot call a function in a loaded native image"))) {
    @("cpp.guestClass.hostCallsVirtuals." ~ backend.stringof)
    @Serial
    unittest {
        static if (is(backend == Native)) {
            auto image = cppImage;
            auto callFirst = resolveNative!CallIntMethodFn(
                image, call_first.mangleof);
            auto callSecond = resolveNative!CallIntMethodFn(
                image, call_second.mangleof);
            auto callBigVirtual = resolveNative!CallBigFn(
                image, call_big_virtual.mangleof);
            auto mine = cast(Base) cast(void*) new NativeMine;
            callFirst(mine).should == 35;
            callSecond(mine).should == 305;
            const big = callBigVirtual(mine);
            (big.a * 100 + big.b * 10 + big.c).should == 345;
        } else {
            auto image = cppImage;
            auto module_ = parseSnippet(cppBindings ~ q{
                extern(C++) class Mine {
                    int tag_ = 3;
                    int first() { return tag_ * 10 + 5; }
                    int second() { return tag_ * 100 + 5; }
                    Big bigVirtual() {
                        return Big(tag_, tag_ + 1, tag_ + 2);
                    }
                }
                Base mine() { return cast(Base) cast(void*) new Mine; }
                int callFirst() { return call_first(mine); }
                int callSecond() { return call_second(mine); }
                struct Reading { size_t a; size_t b; size_t c; }
                Reading callBigVirtual() {
                    auto big = call_big_virtual(mine);
                    return Reading(big.a, big.b, big.c);
                }
            });
            auto program = Program([module_]);
            program.dependencyImage = &image;
            auto instance = Owned!backend(program);

            int result;
            instance.call(findFunction(module_, "callFirst"), &result, []);
            result.should == 35;
            instance.call(findFunction(module_, "callSecond"), &result, []);
            result.should == 305;

            static struct Reading { size_t a; size_t b; size_t c; }
            Reading big;
            instance.call(
                findFunction(module_, "callBigVirtual"), &big, []);
            (big.a * 100 + big.b * 10 + big.c).should == 345;
        }
    }
}
