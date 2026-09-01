module ut.backends.run.structs;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


// A slice assignment copies element by element and runs the postblit for
// each one, rather than blitting the whole slice.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("sliceAssignRunsPostBlitPerElement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            __gshared int copies;

            struct Element {
                int value;

                this(this) {
                    ++copies;
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

// The members of an anonymous union occupy the same storage, so writing
// through one member changes what is read back through another.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("anonymousUnionMembersShareStorage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S {
                union {
                    int a;
                    uint b;
                }
            }

            void main() {
                S s;
                s.a = -1;
                assert(s.b == uint.max);
            }
        });
    }
}

// A struct declared inside a function sees that function's locals, so its
// method can call a delegate the function made.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
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

// `.tupleof` on both sides assigns field by field between the two field
// lists, so it works across struct types that share a field layout even
// though they share no other relationship.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
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

            struct Twin {
                int head;
                long tail;
            }

            void main() {
                auto source = Pair(2, 3L);
                Twin target;
                target.tupleof = source.tupleof;
                assert(target.head == 2);
                assert(target.tail == 3);
            }
        });
    }
}

// A struct literal writes each field at its own native offset, and a
// plain field assignment overwrites only that field's own bytes, leaving
// its siblings untouched.
static foreach (backend; Matrix!()) {
    @("localStructConstructionAndFieldAssignment." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Point {
                int x;
                long y;
            }

            void main() {
                auto p = Point(3, 4);
                assert(p.x == 3);
                assert(p.y == 4);

                p.x = 10;
                assert(p.x == 10);
                assert(p.y == 4);
            }
        });
    }
}

// Assigning one struct local to another copies every field's bytes, not a
// reference: mutating the copy leaves the original untouched.
static foreach (backend; Matrix!()) {
    @("structLocalAssignmentCopiesByValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Point {
                int x;
                int y;
            }

            void main() {
                auto a = Point(1, 2);
                auto b = a;
                b.x = 99;

                assert(a.x == 1);
                assert(b.x == 99);
            }
        });
    }
}

// A struct passed by value into a function, and returned by value out of
// one, is copied both ways - the callee's own mutation of its parameter
// never reaches the caller's argument.
static foreach (backend; Matrix!()) {
    @("structParametersAndReturnsCopyByValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Point {
                int x;
                int y;
            }

            Point make(int a, int b) {
                return Point(a, b);
            }

            int sum(Point p) {
                p.x = -1;
                return p.x + p.y;
            }

            void main() {
                auto p = make(3, 4);
                assert(sum(p) == 3);
                assert(p.x == 3);
            }
        });
    }
}

// A nested struct field is reached through its own enclosing field's
// offset, added to the outer field's.
static foreach (backend; Matrix!()) {
    @("nestedStructFieldAccess." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Inner {
                int value;
            }

            struct Outer {
                Inner inner;
                int tag;
            }

            void main() {
                Outer o;
                o.inner.value = 7;
                o.tag = 2;
                assert(o.inner.value == 7);
                assert(o.tag == 2);
            }
        });
    }
}

