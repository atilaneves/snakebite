module ut.backends.run.templates;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


// `__traits(allMembers)` with a recursive template walks a struct's fields
// in declaration order, choosing a branch per field type.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("traitsDrivenStructTraversal." ~ backend.stringof)
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
                assert(dec.value!Simple == e,
                       "direct == on the getter's result");

                auto dec2 = Decoder(bytes);
                assert(
                    isEqual(dec2.value!Simple, e),
                    "the same result, forwarded through `in auto ref`",
                );
            }
        });
    }
}

// A mixin template's member is a member of the class that mixes it in, so
// it can override a base method and see the derived class's fields.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("mixinTemplateOverridesInDerived." ~ backend.stringof)
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

// `opOpAssign` selected by a template value parameter runs on the element
// a pointer names, so the array element itself changes.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("opOpAssignThroughPointerToElement." ~ backend.stringof)
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

// A nested function used as a template's alias predicate carries the
// enclosing frame, so the predicate sees the locals it closes over.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("localPredicateInstantiatesAlgorithm." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct ByteRange {
                void* ptr;
                size_t length;
            }

            struct Allocations {
                ByteRange[] entries;

                bool remove(void[] bytes) scope pure {
                    import std.algorithm: canFind, countUntil;

                    bool matches(ByteRange other) {
                        return other.ptr == bytes.ptr &&
                            other.length == bytes.length;
                    }

                    assert(entries.canFind!matches);
                    const index = entries.countUntil!matches;
                    foreach (i; index .. entries.length - 1)
                        entries[i] = entries[i + 1];
                    entries = entries[0 .. $ - 1];
                    return true;
                }
            }

            void main() {
                ubyte[2] first;
                ubyte[3] second;
                auto allocations = Allocations([
                    ByteRange(first.ptr, first.length),
                    ByteRange(second.ptr, second.length),
                ]);
                assert(allocations.remove(first[]));
                assert(allocations.entries.length == 1);
                assert(allocations.entries[0].ptr == second.ptr);
            }
        });
    }
}

