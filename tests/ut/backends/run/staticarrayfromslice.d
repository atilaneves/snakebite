module ut.backends.run.staticarrayfromslice;


import ut.backends;

// `T[N] a = d[lo .. hi];`: dmd types the slice `T[N]` when both bounds are
// compile-time constants, so it is the `N` elements at `d.ptr + lo`, not a
// length and a pointer to copy into `a`.

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
    @("staticArray.fromSlice.decl.ushort." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            ushort mk(size_t i) { return cast(ushort) (i * 4099 + 3); }
            void main() {
                ushort[7] store;
                foreach (i; 0 .. store.length) store[i] = mk(i);
                ushort[] d = store[];
                ushort[4] a = d[1 .. 5];
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


static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.decl.struct." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Pair { int a; short b; }
            Pair mk(size_t i) { return Pair(cast(int) i + 1, cast(short) (i * 3)); }
            void main() {
                Pair[7] store;
                foreach (i; 0 .. store.length) store[i] = mk(i);
                Pair[] d = store[];
                Pair[4] a = d[1 .. 5];
                foreach (i; 0 .. 4) assert(a[i] == mk(i + 1));
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.decl.pointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int* mk(size_t i) { return new int(cast(int) (i * 5 + 2)); }
            void main() {
                int*[7] store;
                foreach (i; 0 .. store.length) store[i] = mk(i);
                int*[] d = store[];
                int*[4] a = d[1 .. 5];
                foreach (i; 0 .. 4) assert(*a[i] == *mk(i + 1));
            }
        });
    }
}

// An assignment of a slice with constant bounds to a `T[N]` copies the
// `N` elements that the slice names.

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.assign.ubyte." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            ubyte mk(size_t i) { return cast(ubyte) (i * 7 + 1); }
            void main() {
                ubyte[7] store;
                foreach (i; 0 .. store.length) store[i] = mk(i);
                ubyte[] d = store[];
                ubyte[4] a;
                a = d[1 .. 5];
                foreach (i; 0 .. 4) assert(a[i] == mk(i + 1));
            }
        });
    }
}


// A slice with constant bounds converts implicitly to a `T[N]` parameter:
// the callee gets the `N` elements, not the slice's length and pointer.

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.argument.ubyte." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            ubyte mk(size_t i) { return cast(ubyte) (i * 7 + 1); }
            void take(ubyte[4] a) {
                foreach (i; 0 .. 4) assert(a[i] == mk(i + 1));
            }
            void main() {
                ubyte[7] store;
                foreach (i; 0 .. store.length) store[i] = mk(i);
                ubyte[] d = store[];
                take(d[1 .. 5]);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.argument.long." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            long mk(size_t i) { return cast(long) i * 4_000_000_007L - 5; }
            void take(long[4] a) {
                foreach (i; 0 .. 4) assert(a[i] == mk(i + 1));
            }
            void main() {
                long[7] store;
                foreach (i; 0 .. store.length) store[i] = mk(i);
                long[] d = store[];
                take(d[1 .. 5]);
            }
        });
    }
}


// Returning a slice with constant bounds from a function that returns
// `T[N]` returns the `N` elements.

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.return.ubyte." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            ubyte mk(size_t i) { return cast(ubyte) (i * 7 + 1); }
            ubyte[4] make(ubyte[] d) { return d[1 .. 5]; }
            void main() {
                ubyte[7] store;
                foreach (i; 0 .. store.length) store[i] = mk(i);
                ubyte[] d = store[];
                auto a = make(d);
                foreach (i; 0 .. 4) assert(a[i] == mk(i + 1));
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.return.long." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            long mk(size_t i) { return cast(long) i * 4_000_000_007L - 5; }
            long[4] make(long[] d) { return d[1 .. 5]; }
            void main() {
                long[7] store;
                foreach (i; 0 .. store.length) store[i] = mk(i);
                long[] d = store[];
                auto a = make(d);
                foreach (i; 0 .. 4) assert(a[i] == mk(i + 1));
            }
        });
    }
}


// A constructor that assigns a constant-bounds slice to a `T[N]` field
// stores the elements in the field.

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.fieldInit.ubyte." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            ubyte mk(size_t i) { return cast(ubyte) (i * 7 + 1); }
            struct Holder { ubyte[4] a; this(ubyte[] d) { a = d[1 .. 5]; } }
            void main() {
                ubyte[7] store;
                foreach (i; 0 .. store.length) store[i] = mk(i);
                ubyte[] d = store[];
                auto h = Holder(d);
                foreach (i; 0 .. 4) assert(h.a[i] == mk(i + 1));
            }
        });
    }
}


// A struct literal takes the elements of a constant-bounds slice for a
// `T[N]` field.

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.literal.ubyte." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            ubyte mk(size_t i) { return cast(ubyte) (i * 7 + 1); }
            struct Holder { ubyte[4] a; int tail; }
            void main() {
                ubyte[7] store;
                foreach (i; 0 .. store.length) store[i] = mk(i);
                ubyte[] d = store[];
                auto h = Holder(d[1 .. 5], 99);
                foreach (i; 0 .. 4) assert(h.a[i] == mk(i + 1));
                assert(h.tail == 99);
            }
        });
    }
}


// `cast(T[N]) d[lo .. hi]` is the same static-array-typed slice that an
// implicit conversion gives.

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.cast.ubyte." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            ubyte mk(size_t i) { return cast(ubyte) (i * 7 + 1); }
            void main() {
                ubyte[7] store;
                foreach (i; 0 .. store.length) store[i] = mk(i);
                ubyte[] d = store[];
                auto a = cast(ubyte[4]) d[1 .. 5];
                foreach (i; 0 .. 4) assert(a[i] == mk(i + 1));
            }
        });
    }
}


// An assignment from `cast(T[N]) d[lo .. hi]` copies the elements.

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.castAssign.ubyte." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            ubyte mk(size_t i) { return cast(ubyte) (i * 7 + 1); }
            void main() {
                ubyte[7] store;
                foreach (i; 0 .. store.length) store[i] = mk(i);
                ubyte[] d = store[];
                ubyte[4] a;
                a = cast(ubyte[4]) d[1 .. 5];
                foreach (i; 0 .. 4) assert(a[i] == mk(i + 1));
            }
        });
    }
}


// Every dimension, including one and the non-power-of-two three, takes the
// elements of the slice.

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.length.1." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int mk(size_t i) { return cast(int) (i * 100003 - 7); }
            void main() {
                int[4] store;
                foreach (i; 0 .. store.length) store[i] = mk(i);
                int[] d = store[];
                int[1] a = d[1 .. 2];
                foreach (i; 0 .. 1) assert(a[i] == mk(i + 1));
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.length.3." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int mk(size_t i) { return cast(int) (i * 100003 - 7); }
            void main() {
                int[6] store;
                foreach (i; 0 .. store.length) store[i] = mk(i);
                int[] d = store[];
                int[3] a = d[1 .. 4];
                foreach (i; 0 .. 3) assert(a[i] == mk(i + 1));
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.length.16." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int mk(size_t i) { return cast(int) (i * 100003 - 7); }
            void main() {
                int[19] store;
                foreach (i; 0 .. store.length) store[i] = mk(i);
                int[] d = store[];
                int[16] a = d[1 .. 17];
                foreach (i; 0 .. 16) assert(a[i] == mk(i + 1));
            }
        });
    }
}

// The slice may be of a static array or a pointer, with a non-zero start.

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.source.static." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int mk(size_t i) { return cast(int) (i * 100003 - 7); }
            void main() {
                int[7] d;
                foreach (i; 0 .. d.length) d[i] = mk(i);
                int[4] a = d[1 .. 5];
                foreach (i; 0 .. 4) assert(a[i] == mk(i + 1));
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.source.pointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int mk(size_t i) { return cast(int) (i * 100003 - 7); }
            void main() {
                int[7] store;
                foreach (i; 0 .. store.length) store[i] = mk(i);
                int* d = store.ptr;
                int[4] a = d[1 .. 5];
                foreach (i; 0 .. 4) assert(a[i] == mk(i + 1));
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.argument.sourceStatic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int mk(size_t i) { return cast(int) (i * 100003 - 7); }
            void take(int[4] a) {
                foreach (i; 0 .. 4) assert(a[i] == mk(i + 1));
            }
            void main() {
                int[7] d;
                foreach (i; 0 .. d.length) d[i] = mk(i);
                take(d[1 .. 5]);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.return.sourceStatic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int mk(size_t i) { return cast(int) (i * 100003 - 7); }
            int[4] make(int[7] d) { return d[1 .. 5]; }
            void main() {
                int[7] d;
                foreach (i; 0 .. d.length) d[i] = mk(i);
                auto a = make(d);
                foreach (i; 0 .. 4) assert(a[i] == mk(i + 1));
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.argument.sourcePointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int mk(size_t i) { return cast(int) (i * 100003 - 7); }
            void take(int[4] a) {
                foreach (i; 0 .. 4) assert(a[i] == mk(i + 1));
            }
            void main() {
                int[7] store;
                foreach (i; 0 .. store.length) store[i] = mk(i);
                int* d = store.ptr;
                take(d[1 .. 5]);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.return.sourcePointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int mk(size_t i) { return cast(int) (i * 100003 - 7); }
            int[4] make(int* d) { return d[1 .. 5]; }
            void main() {
                int[7] store;
                foreach (i; 0 .. store.length) store[i] = mk(i);
                int* d = store.ptr;
                auto a = make(d);
                foreach (i; 0 .. 4) assert(a[i] == mk(i + 1));
            }
        });
    }
}


// A `T[N]` that a slice with a run-time length initialises is a copy of
// `N` elements: a slice of another length fails the length check, and
// compiled D throws `RangeError`.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd CTFE reports a length mismatch as a compile-time error that a guest cannot catch"),
)) {
    @("staticArray.fromSlice.wrongLength.decl." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: RangeError;
            void main() {
                int[] d = [1, 2, 3, 4, 5, 6];
                size_t n = 3;
                bool thrown;
                try {
                    int[4] a = d[0 .. n];
                } catch (RangeError) {
                    thrown = true;
                }
                assert(thrown);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd CTFE reports a length mismatch as a compile-time error that a guest cannot catch"),
)) {
    @("staticArray.fromSlice.wrongLength.assign." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: RangeError;
            void main() {
                int[] d = [1, 2, 3, 4, 5, 6];
                size_t n = 5;
                int[4] a;
                bool thrown;
                try {
                    a = d[1 .. n + 1];
                } catch (RangeError) {
                    thrown = true;
                }
                assert(thrown);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.runTimeLength." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[] d = [1, 2, 3, 4, 5, 6];
                size_t lo = 2;
                int[3] a = d[lo .. lo + 3];
                assert(a[0] == 3 && a[1] == 4 && a[2] == 5);
            }
        });
    }
}

// `cast(U[N])` of a slice with constant bounds reinterprets the bytes
// that the slice names when the sizes are equal.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd CTFE does not reinterpret the bytes of a slice cast"),
)) {
    @("staticArray.fromSlice.reinterpret.intAsBytes." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[] d = [0, 0x01020304, 0];
                auto b = cast(ubyte[4]) d[1 .. 2];
                assert(b[0] == 4 && b[1] == 3 && b[2] == 2 && b[3] == 1);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd CTFE does not reinterpret the bytes of a slice cast"),
)) {
    @("staticArray.fromSlice.reinterpret.bytesAsUshorts." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                ubyte[] u = [1, 2, 3, 4, 5, 6, 7, 8];
                auto c = cast(ushort[2]) u[2 .. 6];
                assert(c[0] == 0x0403 && c[1] == 0x0605);
            }
        });
    }
}

// The way `std.bitmanip` reads a value: the bytes go into a `ubyte[T.sizeof]`
// from a `ubyte[]` slice and a pointer cast reads the value from them.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot reinterpret bytes through a pointer cast"),
)) {
    @("staticArray.fromSlice.reinterpret.bytesThroughPointerCast." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            T read(T)(ubyte[] d) @trusted {
                ubyte[T.sizeof] bytes = d[1 .. 1 + T.sizeof];
                return *cast(T*) bytes.ptr;
            }
            void main() {
                ubyte[] d = [0xff, 0x34, 0x12, 0x78, 0x56, 0x34, 0x12, 0xf0, 0xde, 0xbc, 0x9a, 0x78];
                assert(read!ushort(d) == 0x1234);
                assert(read!uint(d) == 0x5678_1234);
                assert(read!ulong(d) == 0xdef0_1234_5678_1234);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read a union through a different member"),
)) {
    @("staticArray.fromSlice.reinterpret.bytesThroughUnion." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            T read(T)(ubyte[] d) {
                union U { ubyte[T.sizeof] bytes; T value; }
                U u;
                u.bytes = d[1 .. 1 + T.sizeof];
                return u.value;
            }
            void main() {
                ubyte[] d = [0xff, 0x34, 0x12, 0x78, 0x56, 0x34, 0x12, 0xf0];
                assert(read!ushort(d) == 0x1234);
                assert(read!uint(d) == 0x5678_1234);
            }
        });
    }
}

// A reference parameter binds to the elements that a static-array-typed
// slice names, so the callee writes into the original array.
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

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.indexAssignThroughCast." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                ubyte[] d = [1, 2, 3, 4];
                (cast(ubyte[2]) d[1 .. 3])[1] = 77;
                assert(d[0] == 1 && d[1] == 2 && d[2] == 77 && d[3] == 4);
            }
        });
    }
}

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

// `peek` builds a `ubyte[2]` from a slice of its range argument, which has a
// template type, and converts it to the value.
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

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.bitmanip.read." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import std.bitmanip: read;
            void main() {
                ubyte[] b = [0x12, 0x34, 0, 1];
                assert(b.read!ushort == 0x1234);
                assert(b.length == 2);
                assert(b.read!ushort == 1);
            }
        });
    }
}

// A slice with no bounds of a static array has the type of its array, and a
// cast to a static array of the same size is the elements, not a header.
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

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd CTFE does not reinterpret the bytes of a slice cast"),
)) {
    @("staticArray.fromSlice.cast.wholeReinterpret." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                ubyte[8] sa = [1, 0, 2, 0, 3, 0, 4, 0];
                auto w = cast(ushort[4]) sa[];
                assert(w == [1, 2, 3, 4]);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.zeroLength." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[] d = [1, 2, 3];
                int[0] a = d[2 .. 2];
                int after = 5;
                assert(a.length == 0);
                assert(after == 5);
                assert(d == [1, 2, 3]);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.nestedElements." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[2][] dd = [[1, 2], [3, 4], [5, 6], [7, 8]];
                int[2][2] m = dd[1 .. 3];
                assert(m[0] == [3, 4] && m[1] == [5, 6]);
            }
        });
    }
}

// A `$` in the bounds of a slice of a static array is a constant, so the
// slice is typed `T[N]`.
static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.dollar.staticSource." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[7] s = [10, 11, 12, 13, 14, 15, 16];
                int[2] a = s[$ - 2 .. $];
                assert(a == [15, 16]);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.dollar.dynamicSource." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[] d = [10, 11, 12, 13, 14, 15, 16];
                int[2] a = d[$ - 2 .. $];
                assert(a == [15, 16]);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.nestedSlice." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                ubyte[] d = [1, 2, 3, 4, 5, 6, 7];
                ubyte[2] a = d[1 .. 6][1 .. 3];
                assert(a == [3, 4]);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.ofArrayLiteral." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                ubyte[2] a = [1, 2, 3, 4][1 .. 3];
                assert(a == [2, 3]);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.ofStringLiteral." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                char[2] a = "hello"[1 .. 3];
                assert(a == "el");
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.outArgument." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void fill(out ubyte[2] a) { a[0] = 7; a[1] = 8; }
            void main() {
                ubyte[] d = [1, 2, 3, 4];
                fill(cast(ubyte[2]) d[1 .. 3]);
                assert(d == [1, 7, 8, 4]);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.inArgument." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int sum(in ubyte[2] a) { return a[0] + a[1]; }
            void main() {
                ubyte[] d = [1, 2, 3, 4];
                assert(sum(d[1 .. 3]) == 5);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.refArgumentImplicit." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void bump(ref ubyte[2] a) { a[0] += 10; a[1] += 20; }
            void main() {
                ubyte[] d = [1, 2, 3, 4];
                bump(d[1 .. 3]);
                assert(d == [1, 12, 23, 4]);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.returnRef." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            ref ubyte[2] mid(return ref ubyte[4] s) { return s[1 .. 3]; }
            void main() {
                ubyte[4] s = [10, 20, 30, 40];
                mid(s)[0] = 99;
                assert(s == [10, 99, 30, 40]);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.returnRefDynamic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            ref ubyte[2] mid(ubyte[] s) { return s[1 .. 3]; }
            void main() {
                ubyte[] d = [10, 20, 30, 40];
                mid(d)[1] = 88;
                assert(d == [10, 20, 88, 40]);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.foreachRef." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                ubyte[] d = [1, 2, 3, 4];
                foreach (ref x; cast(ubyte[2]) d[1 .. 3]) x += 100;
                assert(d == [1, 102, 103, 4]);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.addressOf." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                ubyte[] d = [1, 2, 3, 4];
                auto p = &(cast(ubyte[2]) d[1 .. 3]);
                (*p)[0] = 42;
                assert(d == [1, 42, 3, 4]);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.equality." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                ubyte[] d = [1, 2, 3, 2, 3];
                ubyte[2] w = [2, 3];
                assert(cast(ubyte[2]) d[1 .. 3] == w);
                assert(cast(ubyte[2]) d[1 .. 3] == cast(ubyte[2]) d[3 .. 5]);
                assert(!(cast(ubyte[2]) d[0 .. 2] == w));
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.arrayOpAssignOnLeft." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                ubyte[] d = [1, 2, 3, 4, 5];
                (cast(ubyte[2]) d[1 .. 3])[] += 5;
                assert(d == [1, 7, 8, 4, 5]);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.arrayOpOnLeft." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[] d = [1, 2, 3, 4, 5];
                (cast(int[2]) d[0 .. 2])[] = d[3 .. 5][] * 2;
                assert(d == [8, 10, 3, 4, 5]);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("staticArray.fromSlice.scalarFillOfCast." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                ubyte[] d = [1, 2, 3, 4];
                cast(ubyte[2]) d[1 .. 3] = 6;
                assert(d == [1, 6, 6, 4]);
            }
        });
    }
}

// The bounds are constants, so the slice is typed `T[N]`; the source array is
// shorter at run time and the slice fails its check before it reads memory.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd CTFE reports a slice that is out of bounds as a compile-time error that a guest cannot catch"),
)) {
    @("staticArray.fromSlice.constantBoundsPastEnd.decl." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: ArraySliceError;
            void take(ubyte[2] a) {}
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

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd CTFE reports a slice that is out of bounds as a compile-time error that a guest cannot catch"),
)) {
    @("staticArray.fromSlice.constantBoundsPastEnd.assign." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: ArraySliceError;
            void take(ubyte[2] a) {}
            void main() {
                ubyte[] d = [1];
                bool thrown;
                try {
                    ubyte[2] a;
                    a = d[0 .. 2];
                } catch (ArraySliceError e) {
                    thrown = true;
                    assert(e.msg == "slice [0 .. 2] extends past source array of length 1");
                }
                assert(thrown);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd CTFE reports a slice that is out of bounds as a compile-time error that a guest cannot catch"),
)) {
    @("staticArray.fromSlice.constantBoundsPastEnd.argument." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: ArraySliceError;
            void take(ubyte[2] a) {}
            void main() {
                ubyte[] d = [1];
                bool thrown;
                try {
                    take(d[0 .. 2]);
                } catch (ArraySliceError e) {
                    thrown = true;
                    assert(e.msg == "slice [0 .. 2] extends past source array of length 1");
                }
                assert(thrown);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd CTFE reports a slice that is out of bounds as a compile-time error that a guest cannot catch"),
)) {
    @("staticArray.fromSlice.constantBoundsPastEnd.cast." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: ArraySliceError;
            void take(ubyte[2] a) {}
            void main() {
                ubyte[] d = [1];
                bool thrown;
                try {
                    auto a = cast(ubyte[2]) d[0 .. 2];
                } catch (ArraySliceError e) {
                    thrown = true;
                    assert(e.msg == "slice [0 .. 2] extends past source array of length 1");
                }
                assert(thrown);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd CTFE reports a slice that is out of bounds as a compile-time error that a guest cannot catch"),
)) {
    @("staticArray.fromSlice.constantBoundsPastEnd.assignTarget." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.exception: ArraySliceError;
            void take(ubyte[2] a) {}
            void main() {
                ubyte[] d = [1];
                bool thrown;
                try {
                    ubyte[2] v;
                    cast(ubyte[2]) d[0 .. 2] = v;
                } catch (ArraySliceError e) {
                    thrown = true;
                    assert(e.msg == "slice [0 .. 2] extends past source array of length 1");
                }
                assert(thrown);
            }
        });
    }
}
