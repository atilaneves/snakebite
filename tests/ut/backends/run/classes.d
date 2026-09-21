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
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot access class destructors through TypeInfo"),
)) {
    @("firstDestructorCallFromGc." ~ backend.stringof)
    @Tags(backend.stringof)
    @Serial
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
            auto backend_ = new BackendType(Program([modules[0]]));
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
    auto backend = new Interpreter(Program([modules[0]]));

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
