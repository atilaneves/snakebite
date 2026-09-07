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

// `ubyte[3]`'s own size is 3 bytes - not one of the native integral
// widths (1/2/4/8) `opConstant`'s `storeWidth` lays out - so this is the
// same odd-width zero-init shape as `staticArray.defaultInitIsZero`
// above, but a static array reaching it directly rather than through an
// `int[3][2]`'s 24-byte outer size, and a literal alongside it.
static foreach (backend; Matrix!()) {
    @("staticArray.threeByteDefaultInitAndLiteral." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                ubyte[3] zero;
                assert(zero[0] == 0 && zero[1] == 0 && zero[2] == 0);

                ubyte[3] lit = [1, 2, 3];
                assert(lit[0] == 1 && lit[1] == 2 && lit[2] == 3);
            }
        });
    }
}

// A `char[3]` literal - the same 3-byte width as `ubyte[3]` above, but
// `char.init` is `0xFF`, not zero, so this only covers the literal shape,
// not a default-init one (`staticArray.threeByteDefaultInitAndLiteral`
// already covers the odd-width zero-init path with `ubyte[3]`).
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "confirmed: \"bytecode compiler cannot compile `\\\"xyz\\\"` in " ~
        "`main`\" - a string literal copied into a `char[3]` static-array " ~
        "local is a separate gap from the odd-width zero-init bug this " ~
        "file's other new tests cover, not fixed here"),
    Omit!(Interpreter, Because.unconfirmed,
        "confirmed: \"no native layout for the string literal `\\\"xyz\\\"` " ~
        "as a `char[3]`\" - `nativelayout.storeValue` refuses a string " ~
        "literal's width against a static array's element width here; a " ~
        "separate gap from the odd-width zero-init bug this file's other " ~
        "new tests cover, not fixed here"),
)) {
    @("staticArray.charThreeByteLiteral." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                char[3] a = "xyz";
                assert(a[0] == 'x' && a[1] == 'y' && a[2] == 'z');
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

// `a[] = v` evaluates `v` once, then writes that scalar into every element
// of `a`. DMD represents `a[]` as a dynamic slice even when `a` itself has
// static-array storage; this is also the scalar-fill shape it generates for
// a static array's initialisation. The right side therefore must be evaluated
// as the element type, not as the slice's `{length, pointer}` value.
static foreach (backend; Matrix!(
)) {
    @("staticArray.sliceScalarFill." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                ubyte[3] bytes = [1, 2, 3];
                bytes[] = cast(ubyte) 0u;
                assert(bytes[0] == 0);
                assert(bytes[1] == 0);
                assert(bytes[2] == 0);
            }
        });
    }
}

// `a[] = v` is an expression whose value is the slice `a[]` after the
// fill, so it can initialise a dynamic array that aliases `a`.
static foreach (backend; Matrix!()) {
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


// A static-array local initialized from an `ArrayLiteralExp` whose elements
// are runtime values (not folded at compile time, since they come from a
// function's parameters): the literal is typed `int[3]`, not `int[]`, so
// it copies element by element into the local's own storage.
static foreach (backend; Matrix!()) {
    @("staticArray.literalFromRuntimeValues." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int[3] make(int x, int y, int z) {
                int[3] a = [x, y, z];
                return a;
            }

            void main() {
                auto a = make(1, 2, 3);
                assert(a[0] == 1);
                assert(a[1] == 2);
                assert(a[2] == 3);
            }
        });
    }
}

// A nested `ArrayLiteralExp`, one `int[3]` row literal per element of the
// outer `int[3][2]`: each row must land in its own row's storage, not be
// aliased or share one temporary.
static foreach (backend; Matrix!()) {
    @("staticArray.nestedLiteral." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[3][2] a = [[3, 5, 6], [-3, 6, 1]];
                assert(a[0][0] == 3);
                assert(a[0][2] == 6);
                assert(a[1][0] == -3);
                assert(a[1][2] == 1);
            }
        });
    }
}

// A nested `ArrayLiteralExp` of `string`, a reference type, into a
// static-array context: each element is a `{length, ptr}` pair copied by
// value, not a struct needing element-wise construction.
static foreach (backend; Matrix!()) {
    @("staticArray.stringLiteral." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                string[2] a = ["foo", "sunny"];
                assert(a[0] == "foo");
                assert(a[1] == "sunny");
            }
        });
    }
}
