module ut.backends.run.classes;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;


// `shared` is a qualifier, not a distinct class: the shared type's
// `TypeInfo` names the unshared one as its base.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
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
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("classConstructionInitializesFieldsAndRunsConstructor."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Base {
                int base = 7;
            }

            class Derived : Base {
                int value = 2;

                this(int value_) {
                    value = value_;
                }
            }

            void main() {
                auto derived = new Derived(42);
                assert(derived.base == 7);
                assert(derived.value == 42);
            }
        });
    }
}

@("ordinaryClassStorageIsZeroed.Interpreter")
@Tags(Interpreter.stringof)
unittest {
    auto module_ = parseSnippet(q{
        class Plain {
        }

        Plain make() {
            return new Plain;
        }
    });
    auto function_ = findFunction(module_, "make");

    Object value;
    interpreter(module_).call(function_, &value, []);

    assert(value !is null);
    assert(
        *cast(void**) cast(void*) value is null,
        "ordinary guest class storage must remain zeroed",
    );
}

@("classConstructionBindsThisForDependentFieldAssignments.Interpreter")
@Tags(Interpreter.stringof)
unittest {
    0.shouldBeStatusOf!(Interpreter, q{
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

// A call through an interface reference finds the class's override, which
// needs the interface's own offset rather than the class vtable.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
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
