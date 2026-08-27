module ut.backends.run.structs;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


// A slice assignment copies element by element and runs the postblit for
// each one, rather than blitting the whole slice.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("sliceAssignRunsPostBlitPerElement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            __gshared int copies;
            __gshared int destructions;

            struct Element {
                int value;

                this(this) {
                    ++copies;
                }

                ~this() {
                    ++destructions;
                }
            }

            void main() {
                Element[] source = [Element(3), Element(5)];
                Element[] target = new Element[source.length];

                const before = copies;
                target[] = source[];

                assert(copies == before + 2);
                assert(target[0].value == 3);
                assert(target[1].value == 5);
            }
        });
    }
}

// A member of an anonymous union has an address like any other, so it can
// be passed by reference.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("anonymousUnionMemberIsAddressable." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S {
                union {
                    int a;
                    float b;
                }
            }

            union U {
                S s;
                long l;
            }

            int observe(ref int x) {
                return x;
            }

            void main() {
                U u;
                u.s.a = 7;
                assert(observe(u.s.a) == 7);
                assert(u.s.a == 7);
            }
        });
    }
}

// A struct declared inside a function sees that function's locals, so its
// method can call a delegate the function made.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("nestedStructMethodSeesEnclosingDelegate." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            auto wrap() {
                int base = 40;
                int delegate() dg = () => base + 2;

                struct Caller {
                    int call() {
                        return dg();
                    }
                }

                return Caller();
            }

            void main() {
                assert(wrap().call() == 42);
            }
        });
    }
}

// `.tupleof` on both sides assigns field by field, so fields of different
// types each keep their own value.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("tupleofAssignsFieldwise." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Pair {
                int head;
                long tail;
            }

            void main() {
                auto source = Pair(2, 3L);
                Pair target;
                target.tupleof = source.tupleof;
                assert(target.head == 2);
                assert(target.tail == 3);
            }
        });
    }
}

