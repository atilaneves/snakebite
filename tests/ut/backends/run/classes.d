module ut.backends.run.classes;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;
import snakebite.backends.backend: Program;
import snakebite.frontend.compiler: parseSnippet, parseSnippets;
import snakebite.frontend.dmd.functions: findFunction;
import std.string: endsWith;


public final class HostDispatchObject: Object {
    public override size_t toHash() @trusted nothrow {
        return 42;
    }
}


public Object hostDispatchObject() {
    return new HostDispatchObject;
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
        q{
            module ut.backends.run.classes;
            Object hostDispatchObject();
        },
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

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
)) {
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


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
)) {
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

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
)) {
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

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
)) {
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

static foreach (backend; Matrix!(Omit!(Ctfe, Because.unconfirmed))) {
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
    Omit!(Bytecode, Because.unconfirmed,
        "`scope class` stack allocation (`NewExp.onstack`) is not " ~
            "compiled; only the GC-allocated `new C(args)` path is"),
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

            void main() {
                {
                    scope Resource resource = new Resource;
                }

                assert(destructions == 1);
            }
        });
    }
}

// A call through an interface reference finds the class's override, which
// needs the interface's own offset rather than the class vtable.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
)) {
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
    Omit!(Interpreter, Because.unconfirmed,
        "`Exception.classinfo.name == \"object.Exception\"` fails"),
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
    Omit!(Interpreter, Because.unconfirmed,
        "`MyException.classinfo.base is Exception.classinfo` fails"),
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
    Omit!(Interpreter, Because.unconfirmed,
        "`caught.classinfo is typeid(Exception)` fails"),
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
