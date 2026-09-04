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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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

// `a[i][j] = v` runs the two `next()` calls in the order `dmd -run`
// itself picks for a nested static-array index write: the inner
// (rightmost) index first, the outer (leftmost) index second, landing
// on `a[1][0]` rather than the source order `a[0][1]`. This was
// checked against `dmd -run` directly before writing the test, since
// `next()`'s return value only reveals which call happened first, not
// which bracket it was written in. dmd's own CTFE engine picks the
// opposite order for the same expression (confirmed with `static
// assert` over an `enum`) - a divergence between dmd's two evaluators,
// not a bug in either of this project's backends, so `Ctfe` disagrees
// here on purpose.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "dmd's CTFE engine evaluates a[i][j]'s indices in the opposite " ~
        "order from its runtime codegen for the same expression"),
)) {
    @("staticArray.nestedElementWriteIndexEvaluationOrder." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int n;
                int next() { return n++; }

                int[2][2] a;
                a[next()][next()] = 5;

                assert(a[1][0] == 5);
                assert(a[0][1] == 0);
                assert(a[0][0] == 0);
                assert(a[1][1] == 0);
            }
        });
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
static foreach (backend; Matrix!()) {
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

// An array literal assigned to a static array is one whole value: every
// element is evaluated from the array's old contents before any of
// them is written, so `a = [a[1], a[0]]` swaps the two elements rather
// than writing `a[1]` into `a[0]` and then reading that new `a[0]` back
// as the second element.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "the interpreter writes the literal's elements straight into " ~
        "`a` one by one, so the second element reads the first one's " ~
        "new value"),
)) {
    @("staticArray.assignLiteralReadingItself." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[2] a = [1, 2];
                a = [a[1], a[0]];
                assert(a[0] == 2);
                assert(a[1] == 1);
            }
        });
    }
}

// `a[] = b[]` copies every element of `b` into `a` in order. It is not
// a fill: `b[]` is an array, so no single value of it is written into
// every element of `a`.
static foreach (backend; Matrix!(
)) {
    @("staticArray.sliceCopyFromSlice." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[3] a;
                int[3] b = [1, 2, 3];
                a[] = b[];
                assert(a[0] == 1);
                assert(a[1] == 2);
                assert(a[2] == 3);
            }
        });
    }
}

// `a[] = d` with a dynamic array `d` on the right is the same element
// copy as `a[] = b[]`, not a fill with `d`'s length word.
static foreach (backend; Matrix!(
)) {
    @("staticArray.sliceCopyFromDynamicArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[3] a;
                int[] d = [1, 2, 3];
                a[] = d;
                assert(a[0] == 1);
                assert(a[2] == 3);
            }
        });
    }
}

// `a[] = v` is an expression whose value is the slice `a[]` after the
// fill, so it can initialise a dynamic array that aliases `a`.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "the interpreter cannot take the address of `a[]`"),
)) {
    @("staticArray.fillValueIsTheSlice." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[3] a;
                int[] s = (a[] = 5);
                assert(s.length == 3);
                assert(s[2] == 5);
                s[0] = 1;
                assert(a[0] == 1);
            }
        });
    }
}
