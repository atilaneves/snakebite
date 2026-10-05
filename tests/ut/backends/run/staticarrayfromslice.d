module ut.backends.run.staticarrayfromslice;


import ut.backends;


// `T[N] a = d[lo .. hi];`: dmd types the slice `T[N]` when both bounds are
// constants, so it is the `N` elements at `d.ptr + lo`, not a length and a
// pointer. The three sizes are below, at and above the 16 bytes of a header.
static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.decl.ubyte." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            ubyte mk(size_t i) { return cast(ubyte) (i * 7 + 1); }
            void main() {
                ubyte[7] store;
                foreach (i; 0 .. store.length) store[i] = mk(i);
                ubyte[] d = store[];
                ubyte[4] a = d[1 .. 5];
                foreach (i; 0 .. 4) assert(a[i] == mk(i + 1));
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.decl.int." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int mk(size_t i) { return cast(int) (i * 100003 - 7); }
            void main() {
                int[7] store;
                foreach (i; 0 .. store.length) store[i] = mk(i);
                int[] d = store[];
                int[4] a = d[1 .. 5];
                foreach (i; 0 .. 4) assert(a[i] == mk(i + 1));
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.decl.long." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            long mk(size_t i) { return cast(long) i * 4_000_000_007L - 5; }
            void main() {
                long[7] store;
                foreach (i; 0 .. store.length) store[i] = mk(i);
                long[] d = store[];
                long[4] a = d[1 .. 5];
                foreach (i; 0 .. 4) assert(a[i] == mk(i + 1));
            }
        });
    }
}


// A slice with no bounds of a static array is also typed `T[N]`.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd CTFE makes the cast of a slice of a static array alias the array instead of copying it"),
)) {
    @("staticArray.fromSlice.cast.whole." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[4] sa = [1, 2, 3, 4];
                auto b = cast(int[4]) sa[];
                assert(b == [1, 2, 3, 4]);
                b[0] = 9;
                assert(sa[0] == 1);
            }
        });
    }
}


// `peek` builds a `ubyte[2]` from a slice of its range argument.
static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.bitmanip.peek." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import std.bitmanip: peek;
            void main() {
                ubyte[] b = [0x12, 0x34, 0, 1];
                assert(b.peek!ushort == 0x1234);
            }
        });
    }
}


// A reference parameter binds to the elements that the slice names.
static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.refArgument." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void bump(ref ubyte[2] a) { a[0] += 10; a[1] += 20; }
            void main() {
                ubyte[] d = [1, 2, 3, 4];
                bump(cast(ubyte[2]) d[1 .. 3]);
                assert(d[0] == 1 && d[1] == 12 && d[2] == 23 && d[3] == 4);
            }
        });
    }
}


// A static-array-typed slice on the left of an assignment is an ordinary
// lvalue, not a slice copy.
static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.assignToCast." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                ubyte[] d = [1, 2, 3, 4];
                ubyte[2] v = [9, 8];
                cast(ubyte[2]) d[1 .. 3] = v;
                assert(d[0] == 1 && d[1] == 9 && d[2] == 8 && d[3] == 4);
            }
        });
    }
}


// The slice has constant bounds and its source is shorter at run time: the
// bounds check fails before any element is read.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd CTFE reports a slice that is out of bounds as a compile-time error that a guest cannot catch"),
)) {
    @("staticArray.fromSlice.constantBoundsPastEnd.decl." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: ArraySliceError;
            void main() {
                ubyte[] d = [1];
                bool thrown;
                try {
                    ubyte[2] a = d[0 .. 2];
                } catch (ArraySliceError e) {
                    thrown = true;
                    assert(e.msg == "slice [0 .. 2] extends past source array of length 1");
                }
                assert(thrown);
            }
        });
    }
}
