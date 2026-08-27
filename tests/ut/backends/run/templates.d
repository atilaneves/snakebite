module ut.backends.run.templates;


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
    @("isExp." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Simple {
                ubyte first;
                ushort second;
            }

            struct Decoder {
                ubyte[] bytes;

                @property T value(T)() {
                    T val;
                    grainStruct(this, val);
                    return val;
                }
            }

            void grainStruct(T)(ref Decoder d, ref T val) {
                foreach (member; __traits(allMembers, T))
                    grainField(d, __traits(getMember, val, member));
            }

            void grainField(T)(ref Decoder d, ref T val) if (is(T == ubyte)) {
                val = d.bytes[0];
                d.bytes = d.bytes[1 .. $];
            }

            void grainField(T)(ref Decoder d, ref T val) if (is(T == ushort)) {
                val = cast(ushort)((d.bytes[0] << 8) | d.bytes[1]);
                d.bytes = d.bytes[2 .. $];
            }

            bool isEqual(V, E)(in auto ref V value, in auto ref E expected) {
                return value == expected;
            }

            void main() {
                ubyte[] bytes = [2, 0, 3];
                const e = Simple(2, 3);

                auto dec = Decoder(bytes);
                assert(dec.value!Simple == e, "direct == on the getter's result");

                auto dec2 = Decoder(bytes);
                assert(
                    isEqual(dec2.value!Simple, e),
                    "the same result, forwarded through `in auto ref`",
                );
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("scopeExp." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import std.experimental.allocator.mallocator: Mallocator;

            auto owners(T)(T[] values...) {
                return Owner!T(values);
            }

            struct Owner(T) {
                private T[] _storage;
                private long _length;

                this(T[] values...) {
                    _storage = cast(T[]) Mallocator.instance.allocate(
                        values.length * T.sizeof,
                    );
                    _storage[] = values[];
                    _length = values.length;
                }

                ~this() {
                    Mallocator.instance.deallocate(_storage);
                    _length = 0;
                }

                T[] range() return scope {
                    return _storage[0 .. _length];
                }
            }

            void main() {
                import std.algorithm: equal;

                auto owner = owners(0, 1, 2, 3);
                int[4] expected = [0, 1, 2, 3];
                assert(equal(owner.range, expected[]));
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("templateMixin." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            mixin template Describes() {
                override int describe() {
                    return field + 2;
                }
            }

            class Base {
                int describe() {
                    return 1;
                }
            }

            class Child : Base {
                int field;

                this(int field) {
                    this.field = field;
                }

                mixin Describes;
            }

            int classify(int seed) {
                Base value = new Child(seed);
                return value.describe;
            }

            void main() {
                assert(classify(5) == 7);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("templateValueParameter." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Counter {
                int value;

                void opOpAssign(string op: "+")(int amount) {
                    value += amount;
                }
            }

            void main() {
                Counter[] arr = [Counter(1), Counter(2)];
                Counter* p = &arr[1];
                *p += 40;
                assert(arr[0].value == 1);
                assert(arr[1].value == 42);
            }
        });
    }
}

