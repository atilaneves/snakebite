module ut.backends.run.templates;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


// `__traits(allMembers)` with a recursive template walks a struct's fields
// in declaration order, choosing a branch per field type.
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
    @("decodeFrontPreservesResultAndConsumesCodeUnits." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import std.utf: decodeFront;
            void main() {
                wchar[] input = ['A', 0xD83D, 0xDE00, 'Z'];
                size_t count;
                assert(decodeFront(input, count) == 'A');
                assert(count == 1 && input.length == 3);
                assert(decodeFront(input, count) == 0x1F600);
                assert(count == 2 && input.length == 1);
                assert(decodeFront(input) == 'Z');
                assert(input.length == 0);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot take the address of an initializer symbol"),
)) {
    @("emplaceMersenneTwisterInitializerRestoresState." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.internal.lifetime: emplaceInitializer;
            import std.random: Mt19937;
            void main() {
                Mt19937 generator;
                generator.seed(123);
                generator.popFront();
                emplaceInitializer(generator);
                assert(generator == Mt19937.init);
                generator.seed(5489);
                assert(generator.front == 3499211612U);
                generator.popFront();
                assert(generator.front == 581869302U);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("postconditionReadsReturnedLocal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int checked(int value)
            out (result) {
                assert(result == value + 1);
            }
            do {
                immutable answer = value + 1;
                return answer;
            }
            void main() {
                assert(checked(41) == 42);
                assert(checked(8) == 9);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot take the address of an initializer symbol"),
)) {
    @("structInitializerSymbolCopiesDefaultBytes." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.stdc.string: memcpy;
            struct State {
                uint[6] words = 17;
                size_t index = 6;
            }
            void main() {
                State state;
                state.words[] = 99;
                state.index = 1;
                const initializer = __traits(initSymbol, State);
                assert(initializer.length == State.sizeof);
                memcpy(&state, initializer.ptr, initializer.length);
                assert(state == State.init);
            }
        });
    }
}
