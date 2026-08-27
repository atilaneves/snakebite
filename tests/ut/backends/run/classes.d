module ut.backends.run.classes;


// Every test here reaches an AST node class that no test
// chosen before it reached, and is named for that class.
// Together they reach every class the frontend produced
// for a corpus of guest programs.
//
// The expected exit status is what `dmd -run` gives the
// program, so each test states what compiled D does. A
// backend joins a test's `Matrix` when it agrees.


import ut.backends;


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("typeInfoSharedDeclaration." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Scalars {
                int value;
            }

            void main() {
                auto base = cast(TypeInfo_Class) typeid(shared Scalars).base;

                assert(base is typeid(Scalars));
                assert((base.m_flags & TypeInfo_Class.ClassFlags.noPointers) != 0);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("superExp." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Expected : Exception {
                this(string msg) {
                    super(msg);
                }
            }

            class Other : Exception {
                this(string msg) {
                    super(msg);
                }
            }

            void main() {
                int value = 1;

                try {
                    throw new Expected("expected");
                } catch (Other) {
                    value = 100;
                } catch (Exception caught) {
                    value += cast(int) caught.msg.length;
                }

                assert(value == 9);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("typeInfoInvariantDeclaration." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Holder {
                immutable int[] values;

                ref int[] mutableValues() return {
                    auto pointer = &values;
                    return *(cast(int[]*) pointer);
                }
            }

            void main() {
                Holder holder = Holder([1, 2, 3]);
                const int index = 1;

                holder.mutableValues[index] = 42;

                assert(holder.values == [1, 42, 3]);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("interfaceDeclaration." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.lifetime: emplace;

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
                enum words =
                    (__traits(classInstanceSize, Implementation)
                        + ulong.sizeof - 1)
                    / ulong.sizeof;
                ulong[words] storage;
                auto implementation =
                    emplace!Implementation(cast(void[]) storage[]);
                implementation.calls = 0;
                Allocator allocator = implementation;

                () @trusted { allocator.deallocate; }();

                assert(implementation.calls == 1);
            }
        });
    }
}

