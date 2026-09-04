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
    Omit!(Interpreter, Because.unconfirmed),
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
    Omit!(Bytecode, Because.inexpressible,
        "bytecode cannot compile class parameters"),
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
    Omit!(Bytecode, Because.inexpressible,
        "bytecode cannot compile associative arrays of delegates"),
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
    Omit!(Bytecode, Because.inexpressible,
        "bytecode cannot compile class parameters"),
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
