module ut.backends.run.declarations;


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
    @("visibilityDeclaration." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import std.experimental.allocator: expandArray;
            import std.experimental.allocator.mallocator: Mallocator;

            struct Vector {
                private char[] _elements;
                private long _length;

                this(char[] values...) {
                    _elements = cast(char[]) Mallocator.instance.allocate(
                        values.length,
                    );
                    _elements[] = values[];
                    _length = values.length;
                }

                ~this() {
                    Mallocator.instance.deallocate(cast(void[]) _elements);
                }

                void put(char value) {
                    expand(_length + 1);
                    _elements[_length - 1] = value;
                }

                void put(const(char)[] values) {
                    const oldLength = _length;
                    expand(_length + values.length);
                    _elements[oldLength .. _length] = values[];
                }

                private void expand(long newLength) {
                    if (newLength > _elements.length) {
                        const newCapacity = (newLength * 3) / 2;
                        Mallocator.instance.expandArray(
                            mutableElements,
                            newCapacity - _elements.length,
                        );
                    }
                    _length = newLength;
                }

                private ref char[] mutableElements() return {
                    auto pointer = &_elements;
                    return *pointer;
                }
            }

            void main() {
                auto vector = Vector('f', 'o', 'o');
                vector.put('b');
                vector.put(['a', 'r']);
                vector.put("quux");
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("pragmaDeclaration." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            pragma(mangle, "_D4core10checkedint__T4muluZQgFNaNbNiNfmmKbZm")
            ulong residentMulu(ulong left, ulong right, ref bool overflow);

            void main() {
                bool overflow;
                assert(residentMulu(6, 7, overflow) == 42);
                assert(!overflow);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("staticCtorDeclaration." ~ backend.stringof)
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

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("userAttributeDeclaration." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeStatusOf!(backend, q{
            void main() {
                assert(1 == 2);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("linkDeclaration." ~ backend.stringof)
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

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("storageClassDeclaration." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                static struct S { int[][] a; }
                S s;
                s.a ~= [1, 2, 3];
                auto p = &s.a[0][1];
                *p = 9;
                assert(s.a[0][1] == 9);
                assert(s.a[0][0] == 1);
                assert(s.a[0].length == 3);
            }
        });
    }
}

