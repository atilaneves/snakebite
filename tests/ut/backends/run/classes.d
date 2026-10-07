module ut.backends.run.classes;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;
import snakebite.backends.backend: Program;
import snakebite.frontend.compiler: parseSnippet, parseSnippets;
import snakebite.frontend.dmd.functions: findFunction;
import std.string: endsWith;

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot read runtime TypeInfo"),
)) {
    @("classTypeInfoReportsNativeMetadata." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            abstract class Abstract { }
            class PointerClass { int* field; }
            enum pointerMap = __traits(getPointerBitmap, PointerClass);
            class Disabled {
                @disable this();
                this(int) { }
            }
            void main() {
                assert(typeid(Abstract).m_flags
                    & TypeInfo_Class.ClassFlags.isAbstract);
                assert(typeid(Abstract).depth == 2);
                assert(typeid(Abstract).rtInfo is null);
                assert(typeid(PointerClass).rtInfo !is null);
                auto runtimePointerMap = cast(size_t*)
                    typeid(PointerClass).rtInfo;
                foreach (i; 0 .. pointerMap.length)
                    assert(runtimePointerMap[i] == pointerMap[i]);
                assert(typeid(Disabled).defaultConstructor is null);
                assert(typeid(Disabled).m_flags
                    & TypeInfo_Class.ClassFlags.hasCtor);
            }
        });
    }

    @("classTypeInfoCreatesWithDefaultConstructor." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Value {
                int value = 7;
                this() { value = 42; }
            }
            void main() {
                auto value = cast(Value) typeid(Value).create();
                assert(value !is null);
                assert(value.value == 42);
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot access class destructors through TypeInfo"),
)) {
    @("firstDestructorCallFromGc." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.memory: GC;
            class Resource {
                int* count;
                this(int* count) { this.count = count; }
                ~this() { ++*count; }
            }
            void main() {
                int count;
                auto resource = new Resource(&count);
                const address = cast(const void*) typeid(Resource).destructor;
                GC.runFinalizers(address[0 .. 1]);
                assert(count == 1);
            }
        });
    }

    // A destructor runs from GC finalization, where the GC must not
    // allocate. Its first call to another function therefore has to reach
    // code that was already prepared before the finalizer started.
    @("firstDestructorHelperCallFromGc." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.memory: GC;
            class Resource {
                int* count;
                this(int* count) { this.count = count; }
                void increment() { ++*count; }
                ~this() { increment(); }
            }
            void main() {
                int count;
                auto resource = new Resource(&count);
                const address = cast(const void*) typeid(Resource).destructor;
                GC.runFinalizers(address[0 .. 1]);
                assert(count == 1);
            }
        });
    }
    // Force the first call through finalization, not an earlier guest call or
    // a collection whose conservative roots can keep the object alive.
    @("firstDestructorCompoundFieldsFromGc." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.memory: GC;
            struct Owner {
                byte pad = 9;
                double d = 1.5;
                long l = 20;
                double run() {
                    d += 0.5;
                    l <<= 1;
                    return d + l;
                }
            }
            class Resource {
                int* count;
                Owner owner;
                this(int* count) { this.count = count; }
                ~this() { if (owner.run == 42.0) ++*count; }
            }
            void main() {
                int count;
                auto resource = new Resource(&count);
                const address = cast(const void*) typeid(Resource).destructor;
                GC.runFinalizers(address[0 .. 1]);
                assert(count == 1);
            }
        });
    }

    @("firstDestructorInheritedClassContractsFromGc." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.memory: GC;
            class Base {
                int limit = 7;
                int* checks;
                int f(int x)
                in { ++*checks; assert(x < limit); }
                out (r) { ++*checks; assert(r == x * limit); }
                do { return x * limit; }
            }
            class Derived: Base {
                override int f(int x)
                in (x > 0)
                do { return x * limit; }
            }
            class Resource {
                Base target;
                int* result;
                this(int* checks, int* result) {
                    target = new Derived;
                    target.checks = checks;
                    this.result = result;
                }
                ~this() { *result = target.f(3); }
            }
            void main() {
                int checks, result;
                auto resource = new Resource(&checks, &result);
                const address = cast(const void*) typeid(Resource).destructor;
                GC.runFinalizers(address[0 .. 1]);
                assert(result == 21);
                assert(checks == 2);
            }
        });
    }

    @("firstDestructorInheritedInterfaceContractsFromGc." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.memory: GC;
            interface First { int a(); }
            interface Second {
                int f(int x)
                in { record(); assert(x == g()); }
                out (r) { record(); assert(r == g() * 2); }
                int g();
                void record();
            }
            class Impl: First, Second {
                int value = 7;
                int* checks;
                int a() { return 1; }
                int g() { return value; }
                void record() { ++*checks; }
                int f(int x)
                in (x > 0)
                do { return x * 2; }
            }
            class Resource {
                Second target;
                int* result;
                this(int* checks, int* result) {
                    auto impl = new Impl;
                    impl.checks = checks;
                    target = impl;
                    this.result = result;
                }
                ~this() { *result = target.f(7); }
            }
            void main() {
                int checks, result;
                auto resource = new Resource(&checks, &result);
                const address = cast(const void*) typeid(Resource).destructor;
                GC.runFinalizers(address[0 .. 1]);
                assert(result == 14);
                assert(checks == 2);
            }
        });
    }
}


// A callback is prepared before native code can call it, and the preparation
// follows the functions that its body calls. A function that only the guest
// calls needs no entry, whatever its return type.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot call the native `qsort` with a guest callback"),
)) {
    @("callbackBodyCallsFunctionReturningFiveBytes." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.stdc.stdlib: qsort;
            struct Odd {
                ubyte[5] bytes;
            }
            Odd make() {
                Odd odd;
                odd.bytes[0] = 7;
                return odd;
            }
            extern(C) int compare(const void* a, const void* b) {
                return make.bytes[0] == 7 ? 0 : 1;
            }
            void main() {
                int[2] values = [2, 1];
                qsort(values.ptr, 2, int.sizeof, &compare);
            }
        });
    }
}


// A destructor runs when the collection at the end of the program finalizes
// its object, after `main` returned. The collection here stands for the one
// that the process makes when it ends. Compiled D leaves no trace of a
// destructor that the guest can read after `main`, so the destructor
// writes a file, with C functions that do not allocate, and the test reads
// it. The path is in the text of the program, and belongs to this checkout
// and backend, and the test creates the file before the program runs and
// removes it at the end: a destructor that another test's collection runs
// later finds no file to open, and makes none. 2000 dead objects are the
// deterministic form that a conservative GC allows: a stale stack word keeps
// at most a few alive.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot run `GC.collect`: it has no source code"),
)) {
    @("gcFinalizerRunsGuestDestructorAfterMain." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        import core.memory: GC;
        import std.array: replace;
        import std.conv: text;
        import std.file: exists, readText, remove, write;
        import std.process: thisProcessID;

        enum prefix = "/tmp/snakebite-gc-finalizer-after-main-"
            ~ __FILE_FULL_PATH__.replace("/", "_") ~ "-" ~ backend.stringof
            ~ "-";
        const marker = prefix ~ thisProcessID.text;
        enum code = "enum prefix = \"" ~ prefix ~ "\\0\";" ~ q{
            class B {
                ~this() {
                    import core.stdc.stdio:
                        fclose, fopen, fputs, snprintf;
                    import core.sys.posix.unistd: getpid;

                    char[512] path;
                    snprintf(path.ptr, path.length, "%s%d", prefix.ptr,
                        cast(int) getpid);
                    auto file = fopen(path.ptr, "r+");
                    if (file is null)
                        return;
                    fputs("finalized", file);
                    fclose(file);
                }
            }
            pragma(inline, false) void make() {
                foreach (n; 0 .. 2000)
                    new B;
            }
            void main() {
                make;
            }
        };
        marker.write("armed");
        scope(exit) if (exists(marker))
            remove(marker);

        0.shouldBeStatusOf!(backend, code);
        GC.collect;

        marker.readText.should == "finalized";
    }
}


// Compiled D compiles a call that it never makes, so a branch that does
// not execute must not reject the program because of the callee's
// signature either. The extern(C) function returns an aggregate that holds
// a `real`, which the native call barrier cannot classify. A destructor
// reaches the function that calls it through another function, behind a
// branch that does not execute.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot convert a class reference to void** in `destroy`"),
)) {
    @("destructorUnexecutedBranchWithUnclassifiableNativeCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Wide {
                real value;
            }

            pragma(mangle, "labs")
            extern(C) Wide labs(long);

            void nativeBody() {
                labs(-1);
            }

            void helper(bool execute) {
                if (execute)
                    nativeBody();
            }

            class Resource {
                int* count;
                this(int* count) { this.count = count; }
                ~this() {
                    helper(false);
                    ++*count;
                }
            }

            void main() {
                int count;
                auto resource = new Resource(&count);
                destroy(resource);
                assert(count == 1);
            }
        });
    }
}


// The same shape as the sibling test above, but the branch executes.
// `Wide`'s only field is `real`, which the SysV ABI classifies as nothing
// but the X87/X87UP eightbyte pair a bare `real` return already crosses
// in `%st0` (`ffi.abi.classify`'s `Tfloat80` case, `ffi.abi.
// isX87OnlyAggregate`), so the native call barrier plans it like any
// other call now, and compiled D's own answer for it is the real ABI
// result, not a rejection. A destructor reaches that native call through
// another function, behind a branch it does take, and must read back the
// same value compiled D would.
private struct Wide {
    real value;
}

private extern(C) Wide snakebite_ut_destructor_real_only_return() {
    return Wide(2.5L);
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot convert a class reference to void** in `destroy`"),
)) {
    @("destructorExecutedBranchWithRealAggregateNativeCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Wide {
                real value;
            }

            pragma(mangle, "snakebite_ut_destructor_real_only_return")
            extern(C) Wide nativeCall();

            real nativeBody() {
                return nativeCall().value;
            }

            real helper(bool execute) {
                return execute ? nativeBody() : 0.0L;
            }

            class Resource {
                int* count;
                real* result;
                this(int* count, real* result) {
                    this.count = count;
                    this.result = result;
                }
                ~this() {
                    *result = helper(true);
                    ++*count;
                }
            }

            void main() {
                int count;
                real result;
                auto resource = new Resource(&count, &result);
                destroy(resource);
                assert(count == 1);
                assert(result == 2.5L);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("abstractBaseWithBodylessMethod." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            abstract class Base {
                int value();
            }
            class Derived: Base {
                override int value() { return 17; }
            }
            void main() {
                Base value = new Derived;
                assert(value.value() == 17);
            }
        });
    }
}


public final class HostDispatchObject: Object {
    public override size_t toHash() @trusted nothrow {
        return 42;
    }
}


public Object hostDispatchObject() {
    return new HostDispatchObject;
}


public scope class LinkedScopeResource {
    int* trace;
    this(int* value) { trace = value; }
    ~this() { ++*trace; }
}


private enum linkedClassesModule = q{
    module ut.backends.run.classes;
    Object hostDispatchObject();
    scope class LinkedScopeResource {
        int* trace;
        this(int* value) { trace = value; }
        ~this() { ++*trace; }
    }
};


static foreach (BackendType; Matrix!()) {
    @("linkedScopeClassRunsDestructorAtScopeExit." ~ BackendType.stringof)
    @Tags(BackendType.stringof)
    unittest {
        int result;
        static if (is(BackendType == Native)) {
            {
                scope LinkedScopeResource value = new LinkedScopeResource(&result);
            }
        } else {
            auto modules = parseSnippets([
                q{
                    module linked_scope_root;
                    import ut.backends.run.classes: LinkedScopeResource;
                    int answer() {
                        int trace;
                        {
                            scope LinkedScopeResource value =
                                new LinkedScopeResource(&trace);
                        }
                        return trace;
                    }
                },
                linkedClassesModule,
            ]);
            auto function_ = findFunction(modules[0], "answer");
            auto backend_ = Owned!BackendType(Program([modules[0]]));
            backend_.call(function_, &result, []);
        }
        result.should == 1;
    }
}


@("hostCreatedObjectUsesVirtualGuestDispatch.Interpreter")
@Tags(Interpreter.stringof)
unittest {
    auto modules = parseSnippets([
        q{
            module host_dispatch_root;
            import ut.backends.run.classes: hostDispatchObject;

            size_t answer() {
                return hostDispatchObject().toHash;
            }
        },
        linkedClassesModule,
    ]);
    auto function_ = findFunction(modules[0], "answer");
    auto backend = Owned!Interpreter(Program([modules[0]]));

    size_t result;
    backend.call(function_, &result, []);

    result.should == 42;
}


// `shared` is a qualifier, not a distinct class: the shared type's
// `TypeInfo` names the unshared one as its base.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("sharedClassSharesItsUnsharedTypeInfo." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Scalars {
                int value;
            }

            void main() {
                auto base = typeid(shared Scalars).base;

                assert(base is typeid(Scalars));
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("classConstructionInitializesFieldsAndRunsConstructor."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Base {
                int base = 7;

                int describe() {
                    return base;
                }
            }

            class Derived : Base {
                int value = 2;

                this(int value_) {
                    value = value_;
                }

                override int describe() {
                    return base + value;
                }
            }

            void main() {
                auto derived = new Derived(42);
                assert(derived.base == 7);
                assert(derived.value == 42);

                Base base = derived;
                assert(derived.describe == 49);
                assert(base.describe == 49);
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot inspect host class metadata"),
)) {
    @("hostClassTypeInfoIsClassMetadata." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                assert(typeid(Exception).name == "object.Exception");
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("interfaceDispatchFindsCovariantOverride." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            interface Factory {
                Object make();
            }

            class Product: Object {
            }

            class ProductFactory: Factory {
                override Product make() {
                    return new Product;
                }
            }

            void main() {
                Factory factory = new ProductFactory;
                assert(factory.make !is null);
            }
        });
    }
}

@("ordinaryClassStorageHasNativeVptr.Interpreter")
@Tags(Interpreter.stringof)
unittest {
    auto module_ = parseSnippet(q{
        class Plain {
        }

        Plain make() {
            return new Plain;
        }

        TypeInfo info() {
            return typeid(Plain);
        }
    });
    auto function_ = findFunction(module_, "make");
    auto infoFunction = findFunction(module_, "info");

    Object value;
    auto backend = interpreter(module_);
    backend.call(function_, &value, []);

    assert(value !is null);
    assert(
        *cast(void**) cast(void*) value !is null,
        "ordinary guest class storage must have a native vptr",
    );

    auto classInfo = value.classinfo;
    assert(classInfo !is null);
    TypeInfo info;
    backend.call(infoFunction, &info, []);
    assert(classInfo is info, classInfo.name);
    assert(classInfo.name.endsWith(".Plain"), classInfo.name);
    assert(value.toString.endsWith(".Plain"));
}

static foreach (backend; Matrix!()) {
    @("classConstructionBindsThisForDependentFieldAssignments."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Base {
                int first = 7;
            }

            class Values : Base {
                int second;
                int third;

                this() {
                    this.second = this.first + 1;
                    third = second + 1;
                }
            }

            void main() {
                auto values = new Values;
                assert(values.first == 7);
                assert(values.second == 8);
                assert(values.third == 9);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("classConstructionCallsGuestBaseConstructor." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Base {
                int value;

                this(int value_) {
                    value = value_;
                }
            }

            class Derived : Base {
                this() {
                    super(42);
                }
            }

            void main() {
                auto derived = new Derived;
                assert(derived.value == 42);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("classCastUsesGuestClassHierarchy." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Base {
            }

            class Derived : Base {
            }

            class Other {
            }

            void main() {
                Base base = new Derived;
                assert(cast(Derived) base !is null);
                assert(cast(Other) base is null);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot dereference classinfo"),
)) {
    @("classValueClassInfo." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Dummy {
            }

            bool info(ref Dummy value) {
                bool[string] names;
                assert((value.classinfo.name in names) is null);
                return true;
            }

            bool forward(Dummy value) {
                return info(value);
            }

            void main() {
                assert(forward(new Dummy));
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot execute associative arrays of delegates"),
)) {
    @("classValueClassInfoCanBeUsedAsAssociativeArrayKey."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Base {
            }

            class Derived: Base {
            }

            void main() {
                void delegate()[string] handlers;
                Base value = new Derived;

                handlers[value.classinfo.name] = () {};
                assert(value.classinfo.name in handlers);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot dereference classinfo"),
)) {
    @("genericClassInfoNameWorks." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Dummy {
            }

            bool info(T)() {
                bool[string] names;
                const name = T.classinfo.name;
                assert(name.length > 6);
                assert(name[$ - 6 .. $] == ".Dummy", name);
                assert((name in names) is null);
                return true;
            }

            void main() {
                assert(info!Dummy);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read the mutable static destruction counter"),
)) {
    @("scopeClassRunsDestructorAtScopeExit." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int destructions;

            scope class Resource {
                ~this() {
                    ++destructions;
                }
            }

            scope class Derived : Resource {
                ~this() { destructions += 10; }
            }

            void main() {
                {
                    scope Resource resource = new Resource;
                }

                assert(destructions == 1);
                {
                    scope Resource resource = new Derived;
                }
                assert(destructions == 12);
            }
        });
    }
}


// Class placement construction writes the class init image into the
// supplied bytes before it runs the constructor, then returns a reference
// to those same bytes.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "DMD CTFE cannot evaluate placement `NewExp` expressions"),
)) {
    @("placementNew.classInitializesCallerStorage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class DefaultValue {
                int value = 41;
            }

            class ConstructedValue {
                int value;
                this(int value) { this.value = value; }
            }

            void main() {
                void*[4] defaultStorage;
                void*[4] constructedStorage;
                auto defaultValue = new (defaultStorage) DefaultValue;
                auto constructedValue =
                    new (constructedStorage) ConstructedValue(73);

                assert(cast(void*) defaultValue == defaultStorage.ptr);
                assert(defaultValue.value == 41);
                assert(cast(void*) constructedValue == constructedStorage.ptr);
                assert(constructedValue.value == 73);
            }
        });
    }
}


// D lowers an anonymous class expression to its declaration followed by
// the same class construction as a named type. Placement keeps that
// generated class object in the supplied bytes.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "DMD CTFE cannot evaluate placement `NewExp` expressions"),
)) {
    @("placementNew.anonymousClassUsesCallerStorage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                void*[4] storage;
                auto value = new (storage) class {
                    int number = 41;
                };

                assert(cast(void*) value == storage.ptr);
                assert(value.number == 41);
            }
        });
    }
}


// Placement does not remove the explicit outer object from a nested class
// allocation. The constructor and later method must both use that same
// outer object, while the class itself stays in caller storage.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "DMD CTFE cannot evaluate placement `NewExp` expressions"),
)) {
    @("placementNew.nestedClassUsesExplicitOuter." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Outer {
                int value = 7;

                final class Inner {
                    this(int increment) { value += increment; }
                    int get() { return value; }
                }
            }

            void main() {
                auto outer = new Outer;
                void*[4] storage;
                auto inner = outer.new (storage) Inner(5);

                assert(cast(void*) inner == storage.ptr);
                assert(inner.get() == 12);
                assert(outer.value == 12);
            }
        });
    }
}


// The on-stack route must also initialize the explicit outer context before
// it calls a nested class constructor.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE leaves a nested class's `this.this` null"),
)) {
    @("scopeNestedClassUsesExplicitOuter." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Outer {
                int value = 7;

                final class Inner {
                    this(int increment) { value += increment; }
                    int get() { return value; }
                }
            }

            void main() {
                auto outer = new Outer;
                {
                    scope inner = outer.new Inner(5);
                    assert(inner.get() == 12);
                }
                assert(outer.value == 12);
            }
        });
    }
}


// A nested class in a function has no explicit outer-object expression.
// Its constructor must receive the captured function context for both
// placement and stack allocation.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "DMD CTFE cannot evaluate placement `NewExp` expressions"),
)) {
    @("nestedClassConstructorUsesCapturedContext." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int value = 7;

                final class Inner {
                    this(int increment) { value += increment; }
                    int get() { return value; }
                }

                void*[4] storage;
                auto placed = new (storage) Inner(5);
                assert(cast(void*) placed == storage.ptr);
                assert(placed.get() == 12);

                {
                    scope stacked = new Inner(3);
                    assert(stacked.get() == 15);
                }
                assert(value == 15);
            }
        });
    }
}

// `scope` on the variable, not the class, still runs the destructor at
// scope exit and allocates off the GC heap. `resource`'s type is inferred
// (dmd's dsymbolsem.d runs a full expressionSemantic on the initialiser
// early to work out the type, which attaches `NewExp.lowering` - the
// `_d_newclassT` GC allocation call - while `NewExp.onstack` is still
// unset); only afterwards does dsymbolsem set `NewExp.onstack` for the
// `scope` variable's initialiser, on that same already-lowered node,
// without clearing `lowering`. The ordinary (non-`scope`) class here ends
// up with a `NewExp` that has both a non-null `lowering` and `onstack`
// set, unlike `scope class Resource` above where the class declaration
// itself, not just the variable, drives allocation. A backend that
// dispatches on `lowering !is null` alone runs the heap-allocating
// lowering and never takes the on-stack path.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read the mutable static destruction counter"),
)) {
    @("scopeVariableOfOrdinaryClassRunsDestructorAtScopeExit." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int destructions;

            class Resource {
                int value;
                this(int value) { this.value = value; }
                ~this() {
                    ++destructions;
                }
            }

            void main() {
                {
                    scope resource = new Resource(42);
                    assert(resource.value == 42);
                }
                assert(destructions == 1);
            }
        });
    }
}

// A `scope` variable of interface type holds a class instance on the
// stack. Its scope-exit `DeleteExp` runs through `_d_callinterfacefinalizer`,
// which finds the object from the interface pointer's own offset.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read the mutable static destruction counter"),
)) {
    @("scopeVariableOfInterfaceTypeRunsDestructorAtScopeExit." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int destructions;

            interface Marker { }
            class Padding {
                long padding;
            }
            class Resource : Padding, Marker {
                ~this() {
                    ++destructions;
                }
            }

            void main() {
                {
                    scope Marker marker = new Resource;
                }
                assert(destructions == 1);
            }
        });
    }
}

// A call through an interface reference finds the class's override, which
// needs the interface's own offset rather than the class vtable.
static foreach (backend; Matrix!()) {
    @("interfaceDispatchFindsOverride." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            interface Allocator {
                void deallocate();
            }

            class Implementation: Allocator {
                int calls;

                override void deallocate() {
                    ++calls;
                }
            }

            void main() {
                auto implementation = new Implementation;
                Allocator allocator = implementation;

                allocator.deallocate;

                assert(implementation.calls == 1);
            }
        });
    }
}

// As `structLambdaReadsFieldThroughEnclosingThis` (`ut.backends.run.
// structs`), for a class method's own `this` instead of a struct's: dmd
// resolves the bare field the same way regardless of which kind of
// aggregate declares it, but a class's hidden `this` is already the
// receiver reference rather than a `ref` to it, so the two are worth
// covering separately even though the guest source differs only in one
// keyword.
static foreach (backend; Matrix!()) {
    @("classLambdaReadsFieldThroughEnclosingThis." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Tag {
                int code;

                this(int code) {
                    this.code = code;
                }

                int readCode() {
                    return (() => code)();
                }
            }

            void main() {
                auto tag = new Tag(9);
                assert(tag.readCode() == 9);
            }
        });
    }
}

// `with (obj)` on a class reference: `wthis` holds the reference, so a
// field write reaches the object and an unqualified virtual call in the
// body dispatches on the object's dynamic type.
static foreach (backend; Matrix!()) {
    @("withClassReferenceWritesFieldAndDispatchesVirtually." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Base {
                int x;
                int get() { return x; }
            }
            class Derived: Base {
                override int get() { return x * 2; }
            }

            void main() {
                Base b = new Derived;
                int r;
                with (b) {
                    x = 21;
                    r = get();
                }
                assert(b.x == 21);
                assert(r == 42);
            }
        });
    }
}

// `with (new C)` on a class rvalue: `wthis` is initialised once with the
// new reference and the body's members resolve through it.
static foreach (backend; Matrix!()) {
    @("withClassRvalue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C {
                int x;
                this() { x = 1; }
            }

            void main() {
                int r;
                with (new C) {
                    x += 1;
                    r = x;
                }
                assert(r == 2);
            }
        });
    }
}

// `Type.classinfo` names the same `TypeInfo_Class` an instance of that
// type carries in its vtable, so `is` between the two agrees with native D.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot dereference a class reference's classinfo"),
)) {
    @("staticClassInfoIsInstanceClassInfo." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class B {}
            class D: B {}

            void main() {
                Object o = new D;
                assert(o.classinfo is D.classinfo);
                assert(typeid(D) is D.classinfo);
                assert(const(D).classinfo is D.classinfo);
                assert(o.classinfo !is B.classinfo);
                B b = new B;
                assert(b.classinfo is B.classinfo);
            }
        });
    }
}

// `super.classinfo` is the instance's own dynamic classinfo (dmd lowers it
// to `**super`), not the base type's static one.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot dereference a class reference's classinfo"),
)) {
    @("superClassInfoIsDynamic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class B {}
            class D: B {
                string viaSuper() { return super.classinfo.name; }
                string viaThis() { return this.classinfo.name; }
                string viaCast() { return (cast(B) this).classinfo.name; }
                bool isD() { return super.classinfo is D.classinfo; }
            }

            void main() {
                auto d = new D;
                assert(d.viaThis[$ - 2 .. $] == ".D");
                assert(d.viaCast[$ - 2 .. $] == ".D");
                assert(d.viaSuper[$ - 2 .. $] == ".D");
                assert(d.isD);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot dereference classinfo"),
)) {
    @("staticNestedClassClassInfo." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Outer {
                static class Inner {}
            }

            void main() {
                assert(Outer.Inner.classinfo.name[$ - 11 .. $] == "Outer.Inner");
                Object o = new Outer.Inner;
                assert(o.classinfo is Outer.Inner.classinfo);
                assert(o.classinfo !is Outer.classinfo);
            }
        });
    }
}

// An implicit `new Inner()` written inside an `Outer` method has dmd
// synthesize `NewExp.thisexp` as `this` (`expressionsem.d`, `NewExp`
// semantic) - the guest never writes `this.new Inner()` itself, but the
// allocation still needs `Inner`'s hidden `vthis` field filled with that
// `Outer` instance for `value` to resolve inside `Inner`'s own methods.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed,
        "dmd's own CTFE engine reports `class `this.this` is `null` and " ~
        "cannot be dereferenced` for this snippet, independently of " ~
        "either LoweringVisitor backend - not yet investigated"),
)) {
    @("nestedClassImplicitContextReadsAndWritesOuterField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Outer {
                int value = 7;
                final class Inner {
                    int get() { return value; }
                    void set(int v) { value = v; }
                }
                int make() {
                    auto inner = new Inner();
                    inner.set(inner.get() + 1);
                    return value;
                }
            }
            void main() {
                assert(new Outer().make() == 8);
            }
        });
    }
}

// `outer.new Inner()`, the explicit form of the same allocation: dmd sets
// `NewExp.thisexp` to `outer` directly instead of synthesizing it from
// `this`, so `Inner`'s `vthis` must resolve to that same expression's
// value from outside `Outer` entirely, with no enclosing `Outer` method on
// the call stack to read a context from.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed,
        "dmd's own CTFE engine reports `class `this.this` is `null` and " ~
        "cannot be dereferenced` for this snippet, independently of " ~
        "either LoweringVisitor backend - not yet investigated"),
)) {
    @("nestedClassExplicitOuterContextReadsAndWritesOuterField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Outer {
                int value = 7;
                final class Inner {
                    int get() { return value; }
                    void set(int v) { value = v; }
                }
            }
            void main() {
                auto outer = new Outer();
                auto inner = outer.new Inner();
                inner.set(inner.get() + 1);
                assert(outer.value == 8);
            }
        });
    }
}

// A class nested in a *function* rather than in another class never gets
// `NewExp.thisexp` (dmd only synthesizes or accepts `thisexp` for a class
// nested in a class) - `Inner`'s `vthis` must instead resolve to `main`'s
// own frame, the same way a nested *struct* already reads its enclosing
// function's context.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed,
        "dmd's own CTFE engine reports `class `this.this` is `null` and " ~
        "cannot be dereferenced` for this snippet, independently of " ~
        "either LoweringVisitor backend - not yet investigated"),
)) {
    @("functionLocalNestedClassReadsAndWritesOuterLocal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int value = 7;
                final class Inner {
                    int get() { return value; }
                    void set(int v) { value = v; }
                }
                auto inner = new Inner();
                inner.set(inner.get() + 1);
                assert(value == 8);
            }
        });
    }
}

// As above, but allocated on the stack with `scope`: the on-stack `NewExp`
// path (`visitUnloweredNew`) must fill the same `vthis` the heap path
// does, not just skip straight to the constructor call.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed,
        "dmd's own CTFE engine reports `class `this.this` is `null` and " ~
        "cannot be dereferenced` for this snippet, independently of " ~
        "either LoweringVisitor backend - not yet investigated"),
)) {
    @("functionLocalNestedScopeClassReadsAndWritesOuterLocal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int value = 7;
                final class Inner {
                    int get() { return value; }
                    void set(int v) { value = v; }
                }
                scope inner = new Inner();
                inner.set(inner.get() + 1);
                assert(value == 8);
            }
        });
    }
}

// `Exception.classinfo` on a native class is the real linked
// `TypeInfo_Class`: the one a native instance's vtable names, the one
// `typeid(Exception)` yields, and the one whose `base` is `Throwable`'s.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot dereference classinfo"),
)) {
    @("nativeClassStaticClassInfo." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                auto e = new Exception("x");
                assert(Exception.classinfo.name == "object.Exception");
                assert(e.classinfo is Exception.classinfo);
                assert(typeid(Exception) is Exception.classinfo);
                assert(Exception.classinfo.base is Throwable.classinfo);
                Throwable t = e;
                assert(t.classinfo is Exception.classinfo);
            }
        });
    }
}

// A guest subclass of a native class has the native class's real linked
// `TypeInfo_Class` as `base`, both from the static type and from an
// instance.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot dereference classinfo"),
)) {
    @("guestSubclassOfNativeClassStaticClassInfo." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class MyException: Exception {
                this() { super("x"); }
            }

            void main() {
                Throwable t = new MyException;
                assert(t.classinfo is MyException.classinfo);
                assert(MyException.classinfo.base is Exception.classinfo);
                assert(t.classinfo.base is Exception.classinfo);
            }
        });
    }
}

// A native `Exception` that went through `throw`/`catch` still carries the
// real linked `TypeInfo_Class` that `Exception.classinfo`, `typeid` and a
// dynamic cast all agree on.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot dereference classinfo"),
)) {
    @("caughtNativeExceptionClassInfoIdentity." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                Throwable caught;
                try {
                    throw new Exception("x");
                } catch (Throwable t) {
                    caught = t;
                }
                assert(caught.classinfo is Exception.classinfo);
                assert(caught.classinfo is typeid(Exception));
                assert(cast(Exception) caught !is null);
            }
        });
    }
}

// A native template class instantiated with a guest type: the host binary
// links no metadata for this instance, so the backend builds it. Every
// reference to the instance's class must still resolve to one run-time
// object.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot dereference classinfo"),
)) {
    @("nativeTemplateClassOverGuestTypeClassInfoIdentity." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import std.range.interfaces: inputRangeObject, InputRangeObject;

            struct S { int x; }

            void main() {
                S[] a = [S(1)];
                Object o = inputRangeObject(a);
                assert(o.classinfo is typeid(InputRangeObject!(S[])));
                assert(cast(InputRangeObject!(S[])) o !is null);
            }
        });
    }
}


// A class-to-interface cast dmd proves safe at compile time (`Object.
// Monitor` is a base of `Mutex`) stays an explicit `CastExp` with no
// lowering: it is the backend's own job to keep the reference, whether
// the object's class is a guest one or, as here, a native one the guest
// only instantiated.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot allocate a native class"),
)) {
    @("nativeClassCastToInterfaceKeepsTheObject." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.sync.mutex: Mutex;

            void main() {
                auto mutex = new Mutex;
                Object.Monitor monitor = cast(Object.Monitor) mutex;
                assert(monitor !is null);
                assert(cast(void*) monitor != cast(void*) mutex);
                Mutex empty;
                Object.Monitor absent = empty;
                assert(absent is null);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("multipleInterfacesKeepIdentityAndOverrides." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            interface Reader { int read(); }
            interface Writer { void write(int value); }
            interface Access : Reader, Writer {}
            class Base : Access {
                int value;
                int read() { return value; }
                void write(int next) { value = next; }
            }
            class Derived : Base {
                override int read() { return value + 1; }
            }
            void main() {
                auto object = new Derived;
                Access access = object;
                Reader reader = access;
                Writer writer = access;
                writer.write(41);
                assert(reader.read() == 42);
                assert(cast(Object) reader is object);
                assert(cast(Object) writer is object);
                assert(cast(Writer) reader is writer);
                auto read = &reader.read;
                writer.write(49);
                assert(read() == 50);
            }
        });
    }

    @("virtualReferenceReturnAliasesField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            interface Access { ref int get(); }
            class Cell : Access {
                int value;
                ref int get() { return value; }
            }
            void main() {
                auto cell = new Cell;
                Access access = cell;
                access.get() = 40;
                auto get = &access.get;
                get() += 2;
                assert(cell.value == 42);
                assert(access.get() == 42);
            }
        });
    }
}

// A call through an interface reference uses its native vtable entry.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot allocate a native class"),
)) {
    @("nativeClassInterfaceCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.sync.mutex: Mutex;

            void main() {
                auto mutex = new Mutex;
                Object.Monitor monitor = mutex;
                monitor.lock();
                monitor.unlock();
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot take the address of an initializer symbol"),
)) {
    @("classMethodReadsInstanceInitializer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Node {
                int value = 42;
                size_t initializerSize() {
                    return __traits(initSymbol, Node).length;
                }
            }
            void main() {
                auto node = new Node;
                assert(node.initializerSize() == __traits(classInstanceSize, Node));
            }
        });
    }
}

// A struct field default `new C(1)` is evaluated by the frontend once; every `W()` holds the address of that one static object.
static foreach (backend; Matrix!()) {
    @("compileTimeClassInStructFieldDefault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C { int v; this(int x) { v = x; } }
            struct W { C c = new C(1); }
            void main() { assert(W().c.v == 1); }
        });
    }
}

// Both `W()` values hold the same static object.
static foreach (backend; Matrix!()) {
    @("compileTimeClassInStructFieldDefaultIsShared." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C { int v; this(int x) { v = x; } }
            struct W { C c = new C(1); }
            void main() {
                auto a = W();
                auto b = W();
                assert(a.c is b.c);
            }
        });
    }
}

// `W.init` holds the same static object as `W()`.
static foreach (backend; Matrix!()) {
    @("compileTimeClassInStructFieldDefaultSharedByWInit." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C { int v; this(int x) { v = x; } }
            struct W { C c = new C(1); }
            void main() {
                assert(W.init.c is W().c);
            }
        });
    }
}

// A default-initialised `W` holds the same static object as `W()`.
static foreach (backend; Matrix!()) {
    @("compileTimeClassInStructFieldDefaultSharedByDefaultVariable." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C { int v; this(int x) { v = x; } }
            struct W { C c = new C(1); }
            void main() {
                W v;
                assert(v.c is W().c);
            }
        });
    }
}

// The elements of a default-initialised `W[2]` hold the same static object as `W()`.
static foreach (backend; Matrix!()) {
    @("compileTimeClassInStructFieldDefaultSharedByStaticArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C { int v; this(int x) { v = x; } }
            struct W { C c = new C(1); }
            void main() {
                W[2] ws;
                assert(ws[1].c is W().c);
            }
        });
    }
}

// A `W` made with `new` holds the same static object as `W()`.
static foreach (backend; Matrix!()) {
    @("compileTimeClassInStructFieldDefaultSharedByNew." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C { int v; this(int x) { v = x; } }
            struct W { C c = new C(1); }
            void main() {
                assert((new W).c is W().c);
            }
        });
    }
}

// A write through one `W` is seen through another, since both use the one static object.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE treats a compile-time object as a read-only constant"),
)) {
    @("compileTimeClassMutationIsSharedThroughStructs." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C { int v; this(int x) { v = x; } }
            struct W { C c = new C(1); }
            void main() {
                auto a = W();
                auto b = W();
                a.c.v = 7;
                assert(b.c.v == 7);
                assert(W().c.v == 7);
            }
        });
    }
}

// A class field default is also evaluated once by the frontend, so all instances share the object.
static foreach (backend; Matrix!()) {
    @("compileTimeClassInClassFieldDefault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C { int v; this(int x) { v = x; } }
            class D { C c = new C(3); }
            void main() {
                assert((new D).c.v == 3);
            }
        });
    }
}

// All instances of a class share the object made for a class field default.
static foreach (backend; Matrix!()) {
    @("compileTimeClassInClassFieldDefaultIsShared." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C { int v; this(int x) { v = x; } }
            class D { C c = new C(3); }
            void main() {
                auto a = new D;
                auto b = new D;
                assert(a.c is b.c);
            }
        });
    }
}

// A `static immutable` class instance is built at compile time and used by address.
static foreach (backend; Matrix!()) {
    @("compileTimeClassInStaticImmutable." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C { int v; this(int x) immutable { v = x; } }
            struct W { static immutable C c = new immutable C(4); }
            int get() { return W.c.v; }
            void main() {
                assert(get() == 4);
            }
        });
    }
}

// Two reads of a `static immutable` class instance give the same object.
static foreach (backend; Matrix!()) {
    @("compileTimeClassInStaticImmutableIsShared." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C { int v; this(int x) immutable { v = x; } }
            struct W { static immutable C c = new immutable C(4); }
            void main() {
                assert(W.c is W.c);
            }
        });
    }
}

// A `__gshared` class reference initialised with `new`.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read a static variable"),
)) {
    @("compileTimeClassInGshared." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C { int v; this(int x) { v = x; } }
            __gshared C global = new C(5);
            void main() {
                assert(global.v == 5);
            }
        });
    }
}

// A static array of class references in a struct initialiser holds the shared objects.
static foreach (backend; Matrix!()) {
    @("compileTimeClassInStaticArrayField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C { int v; this(int x) { v = x; } }
            struct W { C[2] cs = [new C(1), new C(2)]; }
            void main() {
                auto w = W();
                assert(w.cs[0].v == 1);
                assert(w.cs[1].v == 2);
            }
        });
    }
}

// Every `W()` holds the same objects in its static array of class references.
static foreach (backend; Matrix!()) {
    @("compileTimeClassInStaticArrayFieldIsShared." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C { int v; this(int x) { v = x; } }
            struct W { C[2] cs = [new C(1), new C(2)]; }
            void main() {
                assert(W().cs[0] is W().cs[0]);
            }
        });
    }
}

// A dynamic array field default of class references.
static foreach (backend; Matrix!()) {
    @("compileTimeClassInArrayLiteralField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C { int v; this(int x) { v = x; } }
            struct W { C[] cs = [new C(1), new C(2)]; }
            void main() {
                auto w = W();
                assert(w.cs.length == 2);
                assert(w.cs[1].v == 2);
            }
        });
    }
}

// The static object has its dynamic type's vtable, so virtual calls reach the override.
static foreach (backend; Matrix!()) {
    @("compileTimeClassWithBaseClassAndVirtualDispatch." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Base { int v; this(int x) { v = x; } int get() { return v; } }
            class Derived : Base {
                int w;
                this(int x, int y) { super(x); w = y; }
                override int get() { return v + w; }
            }
            struct W { Base b = new Derived(1, 2); }
            void main() {
                assert(W().b.get() == 3);
            }
        });
    }
}

// The static object has its dynamic type, so a downcast succeeds.
static foreach (backend; Matrix!()) {
    @("compileTimeClassWithBaseClassAndDowncast." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Base { }
            class Derived : Base { }
            struct W { Base b = new Derived; }
            void main() {
                assert(cast(Derived) W().b !is null);
            }
        });
    }
}

// `typeid` of the object finds the dynamic type.
static foreach (backend; Matrix!()) {
    @("compileTimeClassTypeid." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Base { }
            class Derived : Base { }
            struct W { Base b = new Derived; }
            void main() {
                assert(typeid(W().b) is typeid(Derived));
            }
        });
    }
}

// Fields of struct and array type are laid out natively inside the static object.
static foreach (backend; Matrix!()) {
    @("compileTimeClassWithStructAndArrayFields." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct P { int x; int y; }
            class C {
                P p;
                int[3] a;
                string s;
                this() { p = P(1, 2); a = [3, 4, 5]; s = "hi"; }
            }
            struct W { C c = new C; }
            void main() {
                auto c = W().c;
                assert(c.p.y == 2);
                assert(c.a[2] == 5);
                assert(c.s == "hi");
            }
        });
    }
}

// Two fields that refer to one compile-time object refer to one object at
// run time.
static foreach (backend; Matrix!()) {
    @("compileTimeClassObjectGraphKeepsIdentity." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Leaf { int v; this(int x) { v = x; } }
            class Node {
                Leaf a;
                Leaf b;
                this(Leaf l) { a = l; b = l; }
            }
            struct W { Node n = new Node(new Leaf(9)); }
            void main() {
                auto n = W().n;
                assert(n.a is n.b);
                assert(n.a.v == 9);
            }
        });
    }
}

// A write through one field of a shared compile-time object is seen through
// the other field that refers to it.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE treats a compile-time object as a read-only constant"),
)) {
    @("compileTimeClassObjectGraphMutationIsShared." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Leaf { int v; this(int x) { v = x; } }
            class Node {
                Leaf a;
                Leaf b;
                this(Leaf l) { a = l; b = l; }
            }
            struct W { Node n = new Node(new Leaf(9)); }
            void main() {
                auto n = W().n;
                n.a.v = 10;
                assert(n.b.v == 10);
            }
        });
    }
}

// A compile-time object graph with a cycle keeps the cycle.
static foreach (backend; Matrix!()) {
    @("compileTimeClassCycle." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Node {
                Node next;
                int v;
                this(int x) { v = x; }
            }
            Node make() {
                auto a = new Node(1);
                auto b = new Node(2);
                a.next = b;
                b.next = a;
                return a;
            }
            struct W { Node n = make(); }
            void main() {
                auto n = W().n;
                assert(n.next.v == 2);
                assert(n.next.next is n);
            }
        });
    }
}

// A `__gshared` interface reference initialised with `new` holds the address
// of the interface part inside the static object, not of the object itself.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read a static variable"),
)) {
    @("compileTimeClassInterfaceGlobal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            interface I { int get(); }
            class C : I { int v; this(int x) { v = x; } int get() { return v; } }
            __gshared I global = new C(11);
            void main() {
                assert(global.get() == 11);
            }
        });
    }
}

// A downcast of a `__gshared` interface reference finds the object.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read a static variable"),
)) {
    @("compileTimeClassInterfaceGlobalDowncast." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            interface I { int get(); }
            class C : I { int v; this(int x) { v = x; } int get() { return v; } }
            __gshared I global = new C(11);
            void main() {
                assert(cast(C) global !is null);
            }
        });
    }
}

// Converting the object back to the interface gives the address in the `__gshared` reference.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read a static variable"),
)) {
    @("compileTimeClassInterfaceGlobalIdentity." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            interface I { int get(); }
            class C : I { int v; this(int x) { v = x; } int get() { return v; } }
            __gshared I global = new C(11);
            void main() {
                auto c = cast(C) global;
                assert(cast(I) c is global);
            }
        });
    }
}

// A struct holding a class reference, in a `static immutable`.
static foreach (backend; Matrix!()) {
    @("compileTimeClassInStructInStaticVariable." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C { int v; this(int x) immutable { v = x; } }
            struct W { immutable(C) c; }
            static immutable W w = W(new immutable C(12));
            void main() {
                assert(w.c.v == 12);
            }
        });
    }
}

// A default argument `new C` is evaluated at each call, so each call gets a fresh object.
static foreach (backend; Matrix!()) {
    @("newInDefaultArgumentIsPerCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C { int v; this(int x) { v = x; } }
            C f(C c = new C(1)) { return c; }
            void main() {
                assert(f().v == 1);
                assert(f() !is f());
            }
        });
    }
}

// An interface has no vtable of its own in its `TypeInfo_Class`: the
// method tables live in the `Interface` entries of the classes that
// implement it.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE does not implement `typeid(Derived).info`"),
)) {
    @("interfaceTypeInfoHasNoVtbl." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            interface Base {
                int first();
            }
            interface Derived: Base {
                int second();
            }
            void main() {
                auto info = typeid(Derived).info;
                assert(info.vtbl.length == 0);
                assert(info.base is null);
                assert(info.depth == 0);
                assert(info.interfaces.length == 1);
                assert(info.interfaces[0].classinfo is typeid(Base).info);
                assert(info.interfaces[0].vtbl.length == 0);
            }
        });
    }
}

// A `new` of a `scope class` that is not the initialiser of a `scope`
// variable is a temporary. dmd gives that `NewExp` no `lowering` (a scope
// class never uses the GC) and no `onstack` (only a `scope` variable sets
// it).
static foreach (backend; Matrix!(
    Omit!(Native, Because.diverges,
        "dmd 2.113.0's code generator crashes on this `NewExp`; ldc "
            ~ "compiles it and the program exits with status 0"),
)) {
    @("scopeClassTemporaryIsConstructed." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            scope class Resource {
                int value;
                this(int value) { this.value = value; }
                int next() { return value + 1; }
            }

            int run() {
                return (new Resource(2)).next();
            }

            void main() {
                assert(run() == 3);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE does not implement `typeid(Pointerless).info`"),
)) {
    @("interfaceTypeInfoFlags." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            interface Pointerless {
                int first();
            }
            void main() {
                with (TypeInfo_Class.ClassFlags)
                    assert(typeid(Pointerless).info.m_flags
                        == (hasOffTi | hasTypeInfo | hasNameSig));
            }
        });
    }
}

// `&C.f` without an instance is a plain function pointer to the method.
// A call through it passes no receiver, so a method that does not read
// `this` runs like a free function.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE refuses a member function call that has no `this`"),
)) {
    @("memberFunctionCalledThroughFunctionPointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C {
                final int f() { return 42; }
            }

            void main() {
                auto fp = &C.f;
                assert(fp() == 42);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE rejects a field access through a class qualifier"),
)) {
    @("dotTypeReadsBaseField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class A { int v = 4; }
            class B : A { int g() { return this.A.v; } }
            void main() { assert((new B).g() == 4); }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE rejects a field access through a class qualifier"),
)) {
    @("dotTypeWritesBaseField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class A { int v = 4; }
            class B : A { void g() { this.A.v = 1; } }
            void main() {
                auto b = new B;
                b.g();
                assert(b.v == 1);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE rejects a field access through a class qualifier"),
)) {
    @("dotTypeCompoundAssignsBaseField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class A { int v = 4; }
            class B : A { void g() { this.A.v += 3; } }
            void main() {
                auto b = new B;
                b.g();
                assert(b.v == 7);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE rejects a field access through a class qualifier"),
)) {
    @("dotTypeIncrementsBaseField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class A { int v = 4; }
            class B : A { int g() { return ++this.A.v; } }
            void main() {
                auto b = new B;
                assert(b.g() == 5);
                assert(b.v == 5);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dotTypeCallsBaseMethodNonVirtually." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class A { int f() { return 1; } }
            class B : A {
                override int f() { return 2; }
                int g() { return this.A.f(); }
            }
            void main() {
                auto b = new B;
                assert(b.g() == 1);
                assert(b.f() == 2);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE rejects a field access through a class qualifier"),
)) {
    @("dotTypeOnVariableReadsBaseField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class A { int v = 4; }
            class B : A { }
            void main() {
                auto b = new B;
                assert(b.A.v == 4);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE rejects a field access through a class qualifier"),
)) {
    @("dotTypeOnVariableWritesBaseField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class A { int v = 4; }
            class B : A { }
            void main() {
                auto b = new B;
                b.A.v = 9;
                assert(b.v == 9);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dotTypeOnVariableCallsBaseMethodNonVirtually." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class A { int f() { return 1; } }
            class B : A { override int f() { return 2; } }
            void main() {
                auto b = new B;
                assert(b.A.f() == 1);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE rejects a field access through a class qualifier"),
)) {
    @("dotTypeReachesBaseTwoLevelsUp." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class A { int v = 4; }
            class B : A { }
            class C : B { int g() { return this.A.v; } }
            void main() {
                auto c = new C;
                assert(c.g() == 4);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE rejects a field access through a class qualifier"),
)) {
    @("dotTypeWritesBaseTwoLevelsUpThroughVariable." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class A { int v = 4; }
            class B : A { }
            class C : B { }
            void main() {
                auto c = new C;
                c.A.v = 6;
                assert(c.v == 6);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE rejects a field access through a class qualifier"),
)) {
    @("dotTypeNamesOwnClass." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class A { int v = 4; int g() { return this.A.v; } }
            void main() { assert((new A).g() == 4); }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE rejects a field access through a class qualifier"),
)) {
    @("dotTypeTakesAddressOfBaseField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class A { int v = 4; }
            class B : A {
                int* g() { return &this.A.v; }
            }
            void main() {
                auto b = new B;
                *b.g() = 8;
                assert(b.v == 8);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE rejects a field access through a class qualifier"),
)) {
    @("dotTypePassesBaseFieldByRef." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class A { int v = 4; }
            class B : A {
                void g() { set(this.A.v); }
            }
            void set(ref int x) { x = 11; }
            void main() {
                auto b = new B;
                b.g();
                assert(b.v == 11);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE rejects a field access through a class qualifier"),
)) {
    @("dotTypeQualifiesImplicitThisField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class A { int v = 4; }
            class B : A { int g() { return A.v; } }
            void main() { assert((new B).g() == 4); }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dotTypeQualifiesImplicitThisMethod." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class A { int f() { return 1; } }
            class B : A {
                override int f() { return 2; }
                int g() { return A.f(); }
            }
            void main() { assert((new B).g() == 1); }
        });
    }
}

// An interface base makes a CastExp, not a DotTypeExp: the qualifier names
// the interface and the call dispatches through its vtable.
static foreach (backend; Matrix!()) {
    @("dotTypeNamesInterfaceBase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            interface I { int f(); }
            class C : I {
                int f() { return 3; }
                int g() { return this.I.f(); }
            }
            void main() { assert((new C).g() == 3); }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE fails an internal assertion on a call of a delegate made through a class qualifier"),
)) {
    @("dotTypeMakesDelegateToBaseMethodNonVirtually." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class A { int f() { return 1; } }
            class B : A {
                override int f() { return 2; }
                int delegate() g() { return &this.A.f; }
            }
            void main() { assert((new B).g()() == 1); }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE fails an internal assertion on a delegate made through a class qualifier"),
)) {
    @("dotTypeOnVariableMakesDelegateToBaseMethodNonVirtually." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class A { int f() { return 1; } }
            class B : A { override int f() { return 2; } }
            void main() {
                auto b = new B;
                auto dg = &b.A.f;
                assert(dg() == 1);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE fails an internal assertion on a call of a delegate made through a class qualifier"),
)) {
    @("dotTypeQualifiesImplicitThisDelegate." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class A { int f() { return 1; } }
            class B : A {
                override int f() { return 2; }
                int delegate() g() { return &A.f; }
            }
            void main() { assert((new B).g()() == 1); }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE rejects a field access through a class qualifier"),
)) {
    @("dotTypeEvaluatesOperandOnce." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class A { int v = 4; }
            class B : A { }
            void main() {
                int calls;
                B make() { ++calls; return new B; }
                assert(make().A.v == 4);
                assert(calls == 1);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE cannot compare a class qualifier at compile time"),
)) {
    @("dotTypeIsAValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class A { int v = 4; }
            class B : A { }
            void main() {
                auto b = new B;
                A a = b.A;
                assert(a is b);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("dotTypeDiscardedAsVoidCastEvaluatesOperand." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class A { }
            class B : A { }
            void main() {
                int calls;
                B make() { ++calls; return new B; }
                cast(void) make().A;
                assert(calls == 1);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("inheritedInContractPasses." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Base {
                int f(int x) in (x > 0) { return x; }
            }
            class Derived: Base {
                override int f(int x) { return x + 1; }
            }
            void main() {
                Base b = new Derived;
                assert(b.f(3) == 4);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("inheritedInContractOrRuleBasePasses." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Base {
                int f(int x) in (x > 0) { return x; }
            }
            class Derived: Base {
                override int f(int x) in (x < 0) { return -x; }
            }
            void main() {
                Base b = new Derived;
                assert(b.f(3) == -3);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE does not accept an in contract that any one of the override chain satisfies"),
)) {
    @("inheritedInContractOrRuleOverridePasses." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Base {
                int f(int x) in (x > 0) { return x; }
            }
            class Derived: Base {
                override int f(int x) in (x < 0) { return -x; }
            }
            void main() {
                Base b = new Derived;
                assert(b.f(-3) == 3);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE does not catch this assertion failure"),
)) {
    @("inheritedInContractsBothFail." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: AssertError;

            class Base {
                int f(int x) in (x > 0, "base in") { return x; }
            }
            class Derived: Base {
                override int f(int x) in (x < -5, "derived in") { return -x; }
            }
            void main() {
                Base b = new Derived;
                string message;
                try {
                    b.f(0);
                } catch (AssertError error) {
                    message = error.msg;
                }
                assert(message == "derived in");
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("inheritedOutContractAndRule." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Base {
                int f(int x) out (r) { assert(r > 0); } do { return x; }
            }
            class Derived: Base {
                override int f(int x) out (r) { assert(r < 100); } do { return x; }
            }
            void main() {
                Base b = new Derived;
                assert(b.f(5) == 5);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE does not catch this assertion failure"),
)) {
    @("inheritedOutContractBaseFails." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: AssertError;

            class Base {
                int f(int x) out (r) { assert(r > 0, "base out"); } do { return x; }
            }
            class Derived: Base {
                override int f(int x) out (r) { assert(r < 100, "derived out"); } do { return x; }
            }
            void main() {
                Base b = new Derived;
                string message;
                try {
                    b.f(-1);
                } catch (AssertError error) {
                    message = error.msg;
                }
                assert(message == "base out");
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE does not catch this assertion failure"),
)) {
    @("inheritedOutContractOverrideFails." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: AssertError;

            class Base {
                int f(int x) out (r) { assert(r > 0, "base out"); } do { return x; }
            }
            class Derived: Base {
                override int f(int x) out (r) { assert(r < 100, "derived out"); } do { return x; }
            }
            void main() {
                Base b = new Derived;
                string message;
                try {
                    b.f(500);
                } catch (AssertError error) {
                    message = error.msg;
                }
                assert(message == "derived out");
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("inheritedContractsReadParametersFieldsAndResult." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Base {
                int limit = 10;
                int f(int x)
                in (x < limit)
                out (r; r == x * limit)
                do { return x * limit; }
            }
            class Derived: Base {
                this() { limit = 7; }
                override int f(int x) { return x * limit; }
            }
            void main() {
                Base b = new Derived;
                assert(b.f(3) == 21);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE does not accept an in contract that any one of the override chain satisfies"),
)) {
    @("inheritedContractsThreeLevelsInOfBasePasses." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class A {
                int f(int x)
                in (x != 0, "A in")
                out (r) { assert(r != 100, "A out"); }
                do { return x; }
            }
            class B: A {
                override int f(int x)
                in (x > 10, "B in")
                out (r) { assert(r != 200, "B out"); }
                do { return x; }
            }
            class C: B {
                override int f(int x)
                in (x < -10, "C in")
                out (r) { assert(r != 300, "C out"); }
                do { return x; }
            }
            void main() {
                A a = new C;
                assert(a.f(5) == 5);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE does not accept an in contract that any one of the override chain satisfies"),
)) {
    @("inheritedContractsThreeLevelsInOfLeafPasses." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class A {
                int f(int x)
                in (x != 0, "A in")
                out (r) { assert(r != 100, "A out"); }
                do { return x; }
            }
            class B: A {
                override int f(int x)
                in (x > 10, "B in")
                out (r) { assert(r != 200, "B out"); }
                do { return x; }
            }
            class C: B {
                override int f(int x)
                in (x < -10, "C in")
                out (r) { assert(r != 300, "C out"); }
                do { return x; }
            }
            void main() {
                A a = new C;
                assert(a.f(-20) == -20);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE does not catch this assertion failure"),
)) {
    @("inheritedContractsThreeLevelsOutFails." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: AssertError;

            class A {
                int f(int x)
                in (x != 0, "A in")
                out (r) { assert(r != 100, "A out"); }
                do { return x; }
            }
            class B: A {
                override int f(int x)
                in (x > 10, "B in")
                out (r) { assert(r != 200, "B out"); }
                do { return x; }
            }
            class C: B {
                override int f(int x)
                in (x < -10, "C in")
                out (r) { assert(r != 300, "C out"); }
                do { return x; }
            }
            void main() {
                A a = new C;
                string message;
                try {
                    a.f(100);
                } catch (AssertError error) {
                    message = error.msg;
                }
                assert(message == "A out");
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE does not catch this assertion failure"),
)) {
    @("inheritedContractsThreeLevelsAllInFail." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: AssertError;

            class A {
                int f(int x)
                in (x != 0, "A in")
                out (r) { assert(r != 100, "A out"); }
                do { return x; }
            }
            class B: A {
                override int f(int x)
                in (x > 10, "B in")
                out (r) { assert(r != 200, "B out"); }
                do { return x; }
            }
            class C: B {
                override int f(int x)
                in (x < -10, "C in")
                out (r) { assert(r != 300, "C out"); }
                do { return x; }
            }
            void main() {
                A a = new C;
                string message;
                try {
                    a.f(0);
                } catch (AssertError error) {
                    message = error.msg;
                }
                assert(message == "C in");
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE does not catch this assertion failure"),
)) {
    @("inheritedInterfaceContractPasses." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            interface I {
                int f(int x) in (x > 0, "I in") out (r) { assert(r > x, "I out"); };
            }
            class C: I {
                int f(int x) in (x > 0, "C in") { return x + 1; }
            }
            class D: I {
                int f(int x) { return x; }
            }
            void main() {
                I i = new C;
                assert(i.f(1) == 2);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE does not catch this assertion failure"),
)) {
    @("inheritedInterfaceContractInFails." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: AssertError;

            interface I {
                int f(int x) in (x > 0, "I in") out (r) { assert(r > x, "I out"); };
            }
            class C: I {
                int f(int x) in (x > 0, "C in") { return x + 1; }
            }
            class D: I {
                int f(int x) { return x; }
            }
            void main() {
                I i = new C;
                string message;
                try {
                    i.f(0);
                } catch (AssertError error) {
                    message = error.msg;
                }
                assert(message == "C in");
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE does not catch this assertion failure"),
)) {
    @("inheritedInterfaceContractOutFails." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: AssertError;

            interface I {
                int f(int x) in (x > 0, "I in") out (r) { assert(r > x, "I out"); };
            }
            class C: I {
                int f(int x) in (x > 0, "C in") { return x + 1; }
            }
            class D: I {
                int f(int x) { return x; }
            }
            void main() {
                I i = new D;
                string message;
                try {
                    i.f(1);
                } catch (AssertError error) {
                    message = error.msg;
                }
                assert(message == "I out");
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("inheritedContractWithSuperCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Base {
                int f(int x) in (x > 0) out (r) { assert(r >= x); } do { return x; }
            }
            class Derived: Base {
                override int f(int x) in (x > 0) out (r) { assert(r >= x); } do {
                    return super.f(x) + 1;
                }
            }
            void main() {
                Base b = new Derived;
                assert(b.f(4) == 5);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("inheritedContractsReadAggregateRefAndOutParameters." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S { int a; int b; }
            class Base {
                void f(S s, ref int r, out int o)
                in (s.a == 1 && r == 10)
                out (; s.b == 2 && r == 11 && o == 12)
                do { r = 11; o = 12; }
            }
            class Derived: Base {
                override void f(S s, ref int r, out int o) {
                    r = 11;
                    o = 12;
                }
            }
            void main() {
                Base b = new Derived;
                int r = 10;
                int o;
                b.f(S(1, 2), r, o);
                assert(r == 11 && o == 12);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("inheritedContractsOverrideWithoutOwnContractPasses." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Base {
                int f(int x) in (x > 0) out (r) { assert(r == x, "base out"); } do { return x; }
            }
            class Derived: Base {
                override int f(int x) { return x; }
            }
            class Bad: Base {
                override int f(int x) { return x + 1; }
            }
            void main() {
                
                assert(new Derived().f(2) == 2);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE does not catch this assertion failure"),
)) {
    @("inheritedContractsOverrideWithoutOwnContractFails." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: AssertError;

            class Base {
                int f(int x) in (x > 0) out (r) { assert(r == x, "base out"); } do { return x; }
            }
            class Derived: Base {
                override int f(int x) { return x; }
            }
            class Bad: Base {
                override int f(int x) { return x + 1; }
            }
            void main() {
                Base b = new Bad;
                string message;
                try {
                    b.f(2);
                } catch (AssertError error) {
                    message = error.msg;
                }
                assert(message == "base out");
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("inheritedInterfaceContractCallsThroughThis." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            interface Named { int id(); }
            interface Checked: Named {
                int f(int x) in (x > id()) out (r) { assert(r == id() + x); };
            }
            class Impl: Checked {
                int base = 10;
                int id() { return base; }
                int f(int x) in (x > 0) { return x + base; }
            }
            void main() {
                Checked c = new Impl;
                assert(c.f(11) == 21);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("inheritedContractOfSecondInterfaceReadsThis." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            interface First { int a(); }
            interface Second {
                int f(int x) in (x == g()) out (r) { assert(r == g() * 2); };
                int g();
            }
            class Impl: First, Second {
                int value = 7;
                int a() { return 1; }
                int g() { return value; }
                int f(int x) in (x > 0) { return x * 2; }
            }
            void main() {
                Second s = new Impl;
                assert(s.f(7) == 14);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("inheritedContractsWithClosureInOverride." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Base {
                int scale = 3;
                int f(int x) in (x > 0) out (r) { assert(r == x * scale); }
                do { return x * scale; }
            }
            class Derived: Base {
                override int f(int x) {
                    int delegate() get = () => x * scale;
                    return get();
                }
            }
            void main() {
                Base b = new Derived;
                assert(b.f(4) == 12);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("inheritedContractsWithClosureInBase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Base {
                int scale = 3;
                int f(int x) in (x > 0) out (r) { assert(r == x * scale); }
                do {
                    int delegate() get = () => x * scale;
                    return get();
                }
            }
            class Derived: Base {
                override int f(int x) out (r) { assert(r > 0); } do {
                    return super.f(x);
                }
            }
            void main() {
                Base b = new Derived;
                assert(b.f(4) == 12);
            }
        });
    }
}


// A class gets its vtable when the program first makes an object, and compiled
// D gives each virtual method its code then. A method that only passes a
// pointer to an opaque struct needs no size for the struct.
static foreach (backend; Matrix!()) {
    @("virtualMethodTakesPointerToOpaqueStruct." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Opaque;
            class C {
                int f(Opaque* handle) { return handle is null ? 1 : 2; }
            }
            void main() {
                auto c = new C;
                assert(c.f(null) == 1);
            }
        });
    }
}


// `void[4]` has a size and no default value: a virtual method can pass a
// pointer to one.
static foreach (backend; Matrix!()) {
    @("virtualMethodTakesPointerToStaticArrayOfVoid." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C {
                int f(const(void)[4]* bytes) { return bytes is null ? 1 : 2; }
            }
            void main() {
                auto c = new C;
                assert(c.f(null) == 1);
            }
        });
    }
}


// A branch that the program never takes cannot stop it. The branch takes the
// address of a function that returns five bytes.
static foreach (backend; Matrix!()) {
    @("virtualMethodNeverTakesAddressOfFunctionReturningFiveBytes." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Odd {
                ubyte[5] bytes;
            }
            Odd make() {
                Odd odd;
                odd.bytes[0] = 7;
                return odd;
            }
            class C {
                int f(bool take) {
                    if (take) {
                        auto pointer = &make;
                        return pointer().bytes[0];
                    }
                    return 1;
                }
            }
            void main() {
                auto c = new C;
                assert(c.f(false) == 1);
            }
        });
    }
}


// The thread that collects never ran code of the program: its function is a
// function of druntime. Compiled D ran the thread-local module constructor
// when the thread started, so the finalizer on that thread allocates nothing.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot run `GC.collect`: it has no source code"),
)) {
    @("gcFinalizerRunsDestructorOnThreadThatRanNoProgramCode." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            __gshared int dead;
            int threadLocal;
            static this() { ++threadLocal; }
            class B {
                ~this() { ++dead; }
            }
            pragma(inline, false) void make() {
                foreach (n; 0 .. 2000)
                    new B;
            }
            void main() {
                import core.memory: GC;
                import core.thread: Thread;
                make;
                auto collector = new Thread(cast(void function()) &GC.collect);
                collector.start;
                collector.join;
                assert(dead > 1000);
            }
        });
    }
}


// A destructor that a collection runs on a thread that ran no program code
// calls a function pointer and a delegate: the call through a value needs no
// first-use allocation there.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot run `GC.collect`: it has no source code"),
)) {
    @("gcFinalizerCallsFunctionPointerAndDelegate." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            __gshared int dead;
            void bump() { ++dead; }
            class B {
                ~this() {
                    void function() pointer = &bump;
                    pointer();
                    void delegate() delegate_ = () { ++dead; };
                    delegate_();
                }
            }
            pragma(inline, false) void make() {
                foreach (n; 0 .. 2000)
                    new B;
            }
            void main() {
                import core.memory: GC;
                import core.thread: Thread;
                make;
                auto collector = new Thread(cast(void function()) &GC.collect);
                collector.start;
                collector.join;
                assert(dead > 2000);
            }
        });
    }
}


// A branch that the program never takes cannot stop it. The branch appends a
// pointer to an opaque struct to an array, and the append of druntime names
// the type information of the element: an opaque struct has no size and no
// default value.
static foreach (backend; Matrix!()) {
    @("virtualMethodNeverAppendsPointerToOpaqueStruct." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Opaque;
            class C {
                Opaque*[] handles;
                int f(Opaque* handle, bool keep) {
                    if (keep)
                        handles ~= handle;
                    return 1;
                }
            }
            void main() {
                auto c = new C;
                assert(c.f(null, false) == 1);
            }
        });
    }
}


// The same for `typeid` of a pointer to an opaque struct.
static foreach (backend; Matrix!()) {
    @("virtualMethodNeverNamesTypeInfoOfPointerToOpaqueStruct." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Opaque;
            class C {
                int f(bool ask) {
                    if (ask)
                        return cast(int) typeid(Opaque*).tsize;
                    return 1;
                }
            }
            void main() {
                auto c = new C;
                assert(c.f(false) == 1);
            }
        });
    }
}


// Compiled D has type information for a pointer to an opaque struct: a
// program can keep handles of a C library in an array.
static foreach (backend; Matrix!()) {
    @("virtualMethodAppendsPointerToOpaqueStruct." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Opaque;
            class C {
                Opaque*[] handles;
                int f(Opaque* handle) {
                    handles ~= handle;
                    return cast(int) handles.length;
                }
            }
            void main() {
                auto c = new C;
                assert(c.f(null) == 1);
            }
        });
    }
}


// `Object.classinfo` as the operand of `typeid` is the address of the
// static `TypeInfo_Class` object of `Object`, and that object is itself an
// instance of `TypeInfo_Class`.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE internal error: determining classinfo"),
)) {
    @("class.typeidOfAClassinfoOfAType." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        int main() {
            auto info = typeid(Object.classinfo);
            return info is typeid(TypeInfo_Class) ? 0 : 1;
        }
        });
    }
}

// `I.classinfo` of an interface is the `TypeInfo_Class` object of the
// interface, not the `TypeInfo_Interface` object that `typeid(I)` gives.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE engine fails with an internal error on the classinfo"),
)) {
    @("class.typeidOfAClassinfoOfAnInterface." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        interface I {}
        int main() {
            return typeid(I.classinfo) is typeid(TypeInfo_Class) ? 0 : 1;
        }
        });
    }
}

// `I.classinfo` is the same object as the `info` of `typeid(I)`.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE engine cannot compare `typeid(I)` at compile time"),
)) {
    @("class.classinfoOfAnInterfaceIsTheInfoOfItsTypeid." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        interface I {}
        int main() {
            return I.classinfo is typeid(I).info ? 0 : 1;
        }
        });
    }
}

// A cast of a null class reference reads no vtable: the result is null.
static foreach (backend; Matrix!()) {
    @("castNullClassReferenceIsNotAFault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        class Base { }
        class Derived: Base { }

        int main() {
            Base b;
            return cast(Derived) b is null ? 0 : 1;
        }
        });
    }
}

// A class constructor takes a delegate whether the argument is a literal
// that reads the enclosing function's local, a literal that reads
// nothing, or a delegate that already exists.
static foreach (backend; Matrix!()) {
    @("newWithDelegateArguments." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Holder {
                int delegate() dg;
                this(int delegate() dg) {
                    this.dg = dg;
                }
            }

            int main() {
                int base = 40;
                auto captured = new Holder(() => base + 2);
                auto plain = new Holder(() => 7);
                int delegate() existing = () => base;
                auto reused = new Holder(existing);
                return captured.dg() == 42
                    && plain.dg() == 7
                    && reused.dg() == 40 ? 0 : 1;
            }
        });
    }
}

// `==` on class references compares null first, and reads no vtable.
static foreach (backend; Matrix!()) {
    @("nullClassReferenceEqualityIsNotAFault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        class C { }

        int main() {
            C a;
            C b = new C;
            return a == b || b == a ? 1 : 0;
        }
        });
    }
}

// `destroy` of a null class reference does nothing.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot convert the reference that `destroy` takes, `&C`, to " ~
        "`void**`"),
)) {
    @("destroyNullClassReferenceIsNotAFault." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
        class C { }

        int main() {
            C c;
            destroy(c);
            return 0;
        }
        });
    }
}

// A derived class whose constructor takes a `scope` delegate with default
// arguments, hands a new base-class object to it, delegates to a sibling
// constructor and then to the base constructor; the caller passes a
// delegate literal with a `scope` parameter to a `scope` variable's `new`.
static foreach (backend; Matrix!()) {
    @("newWithScopeDelegateLiteralAndConstructorChain." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            interface Store {
                void write(string name);
            }

            class MockStore: Store {
                string[] names;
                override void write(string name) {
                    names ~= name;
                }
            }

            class Base {
                Store store;
                string root;
                this(Store store, string root) {
                    this.store = store;
                    this.root = root;
                }
            }

            class Derived: Base {
                this(scope void delegate(scope Store) dg = null,
                    string root = "/root")
                {
                    auto store = new MockStore;
                    if (dg !is null)
                        dg(store);
                    super(store, root);
                }

                this(scope void delegate(scope Store) dg, string root, int extra) {
                    this(dg, root);
                }
            }

            int main() {
                scope derived = new Derived((scope Store store) {
                    store.write("a");
                    store.write("b");
                });
                scope other = new Derived((scope Store store) {
                    store.write("c");
                }, "/other", 1);
                const first = cast(MockStore) derived.store;
                const second = cast(MockStore) other.store;
                return first.names == ["a", "b"] && derived.root == "/root"
                    && second.names == ["c"] && other.root == "/other" ? 0 : 1;
            }
        });
    }
}
