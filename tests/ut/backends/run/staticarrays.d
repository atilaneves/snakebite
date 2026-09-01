module ut.backends.run.staticarrays;


// The expected exit status of each guest is what `dmd -run` gives it,
// so each test states what compiled D does. A backend joins a test's
// `Matrix` when it agrees.


import ut.backends;


// A static array is its elements in place, with no length or pointer
// header: `int[3][2]` is six contiguous `int`s. Assigning a whole row
// writes that row's own three elements, an element write reaches into
// one of them, and `==`/`!=` compare the whole value - this pins the
// exact shape `examples/ct-full/source/corpus.d`'s own `int[3][2]`
// unittest exercises, since the interpreter refused every one of these
// before it could run through them.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
)) {
    @("staticArray.rowAssignElementWriteAndEquality." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int bucket(int n) {
                return n;
            }

            void main() {
                int[3][2] a;
                a[0] = [bucket(1), bucket(2), bucket(3)];
                a[1] = [bucket(4), bucket(5), bucket(6)];

                int[3][2] b;
                b[0] = [bucket(1), bucket(2), bucket(3)];
                b[1] = [bucket(4), bucket(5), bucket(6)];

                assert(a == b);
                assert(!(a != b));

                b[1][2] = bucket(99);
                assert(a != b);
                assert(!(a == b));
            }
        });
    }
}

// Reading a static-array element after a row assignment sees exactly
// that row's elements, at their own position - `a[1][2]` is the row
// `a` was assigned, indexed a second time, not some other row's or
// column's byte.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
)) {
    @("staticArray.nestedElementReadAfterRowAssign." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        6.shouldBeRetOf!(backend, q{
            int third() {
                int[3][2] a;
                a[0] = [1, 2, 3];
                a[1] = [4, 5, 6];
                return a[1][2];
            }
        }, "third");
    }
}

// Assigning one static-array local to another copies every element's
// bytes, not a reference: mutating a row through the copy leaves the
// original's row untouched, the same guarantee already pinned for a
// struct local (`structLocalAssignmentCopiesByValue`).
//
// dmd's own CTFE engine does not honour this for a static-array local
// `=`: `enum` over an equivalent snippet at compile time shows `b = a`
// aliasing rather than copying, so mutating `b` there also mutates `a`
// - confirmed directly with a `pragma(msg, ...)` against dmd, not just
// this backend. `Ctfe` calls that same engine, so it disagrees here on
// purpose.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.diverges,
        "dmd's CTFE engine aliases a static-array local on `=` " ~
        "instead of copying it, unlike its runtime codegen"),
)) {
    @("staticArray.localAssignmentCopiesByValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[2] a = [1, 2];
                int[2] b = a;
                b[0] = 99;

                assert(a[0] == 1);
                assert(b[0] == 99);
            }
        });
    }
}

// `int[3].init` is every element's own `.init` - zero for `int` - so a
// freshly declared static array reads back as all zero bytes before
// anything writes to it.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
)) {
    @("staticArray.defaultInitIsZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[3][2] a;
                assert(a[0][0] == 0);
                assert(a[1][2] == 0);
            }
        });
    }
}
