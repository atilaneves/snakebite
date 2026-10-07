module ut.backends.run.structcopy;


import ut.backends;


// A copy constructor runs for a by-value argument that comes from a named
// local, exactly as for a temporary.
static foreach (backend; Matrix!()) {
    @("structCopy.copyCtorArgFromNamedLocal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S {
                int v;
                int* copies;
                int* dtors;
                this(int v, int* copies, int* dtors) {
                    this.v = v;
                    this.copies = copies;
                    this.dtors = dtors;
                }
                this(ref return scope const S o) {
                    v = o.v;
                    copies = cast(int*) o.copies;
                    dtors = cast(int*) o.dtors;
                    ++*copies;
                }
                ~this() { ++*dtors; }
            }
            int take(S s) { return s.v; }
            void main() {
                int copies, dtors;
                {
                    auto s = S(5, &copies, &dtors);
                    assert(take(s) == 5);
                    assert(copies == 1);
                    assert(dtors == 1);
                }
                assert(dtors == 2);
            }
        });
    }
}


// A postblit and a destructor run for each element of a static array that
// is copied by a declaration.
static foreach (backend; Matrix!()) {
    @("structCopy.staticArrayDeclRunsPostblit." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct P {
                int v;
                int* copies;
                int* dtors;
                this(this) { ++*copies; }
                ~this() { ++*dtors; }
            }
            void main() {
                int copies, dtors;
                P[2] w = [P(7, &copies, &dtors), P(8, &copies, &dtors)];
                copies = 0;
                dtors = 0;
                {
                    P[2] a = w;
                    assert(copies == 2);
                    assert(a[0].v == 7 && a[1].v == 8);
                }
                assert(dtors == 2);
            }
        });
    }
}


// A static array of postblit structs passed by value arrives intact and the
// postblit runs for each element.
static foreach (backend; Matrix!()) {
    @("structCopy.staticArrayArgRunsPostblit." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct P {
                int v;
                int* copies;
                int* dtors;
                this(this) { ++*copies; }
                ~this() { ++*dtors; }
            }
            int takeP(P[2] a) { return a[0].v * 10 + a[1].v; }
            void main() {
                int copies, dtors;
                P[2] w = [P(7, &copies, &dtors), P(8, &copies, &dtors)];
                copies = 0;
                dtors = 0;
                assert(takeP(w) == 78);
                assert(copies == 2);
            }
        });
    }
}


// `C[2] a = C(0)` calls the copy constructor for each element and the
// destructor once for the temporary.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "dmd's interpreter does not run the copy constructor for the "
        ~ "elements of a static array; the sibling `Ctfe` unittest below "
        ~ "pins the count it gives"),
)) {
    @("structCopy.staticArrayFromRvalueCopyCtor." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct C {
                int v;
                int* copies;
                int* dtors;
                this(int v, int* copies, int* dtors) {
                    this.v = v;
                    this.copies = copies;
                    this.dtors = dtors;
                }
                this(ref return scope const C o) {
                    v = o.v;
                    copies = cast(int*) o.copies;
                    dtors = cast(int*) o.dtors;
                    ++*copies;
                }
                ~this() { ++*dtors; }
            }
            void main() {
                int copies, dtors;
                {
                    C[2] a = C(0, &copies, &dtors);
                    assert(copies == 2);
                    assert(dtors == 1);
                }
            }
        });
    }
}

// A static array of postblit structs assigned to another one copies each
// element and destroys the old ones.
static foreach (backend; Matrix!()) {
    @("structCopy.staticArrayAssignRunsPostblit." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct P {
                int v;
                int* copies;
                int* dtors;
                this(this) { ++*copies; }
                ~this() { ++*dtors; }
            }
            void main() {
                int copies, dtors;
                P[2] w = [P(7, &copies, &dtors), P(8, &copies, &dtors)];
                copies = 0;
                dtors = 0;
                {
                    P[2] a = [P(1, &copies, &dtors), P(2, &copies, &dtors)];
                    copies = 0;
                    dtors = 0;
                    a = w;
                    assert(copies == 2);
                    assert(dtors == 2);
                    assert(a[0].v == 7 && a[1].v == 8);
                }
            }
        });
    }
}

// A static array returned by value from an lvalue runs the postblit for
// each element.
static foreach (backend; Matrix!()) {
    @("structCopy.staticArrayReturnRunsPostblit." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct P {
                int v;
                int* copies;
                int* dtors;
                this(this) { ++*copies; }
                ~this() { ++*dtors; }
            }
            P[2] give(ref P[2] s) { return s; }
            void main() {
                int copies, dtors;
                P[2] w = [P(7, &copies, &dtors), P(8, &copies, &dtors)];
                copies = 0;
                dtors = 0;
                {
                    P[2] a = give(w);
                    assert(copies == 2);
                    assert(a[0].v == 7 && a[1].v == 8);
                }
            }
        });
    }
}

// A struct whose field is a static array of postblit structs copies each
// element when the struct is copied.
static foreach (backend; Matrix!()) {
    @("structCopy.staticArrayFieldRunsPostblit." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct P {
                int v;
                int* copies;
                int* dtors;
                this(this) { ++*copies; }
                ~this() { ++*dtors; }
            }
            struct H { P[2] f; }
            void main() {
                int copies, dtors;
                P[2] w = [P(7, &copies, &dtors), P(8, &copies, &dtors)];
                copies = 0;
                dtors = 0;
                H h1 = H(w);
                copies = 0;
                {
                    H h2 = h1;
                    assert(copies == 2);
                    assert(h2.f[0].v == 7 && h2.f[1].v == 8);
                }
            }
        });
    }
}

// A nested static array runs the postblit for every innermost element.
static foreach (backend; Matrix!()) {
    @("structCopy.nestedStaticArrayRunsPostblit." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct P {
                int v;
                int* copies;
                int* dtors;
                this(this) { ++*copies; }
                ~this() { ++*dtors; }
            }
            void main() {
                int copies, dtors;
                P[2][2] w = [
                    [P(1, &copies, &dtors), P(2, &copies, &dtors)],
                    [P(3, &copies, &dtors), P(4, &copies, &dtors)],
                ];
                copies = 0;
                dtors = 0;
                {
                    P[2][2] a = w;
                    assert(copies == 4);
                    assert(a[0][0].v == 1 && a[1][1].v == 4);
                }
            }
        });
    }
}

// A static array constructed from a slice runs the postblit for each
// element.
static foreach (backend; Matrix!()) {
    @("structCopy.staticArrayFromSliceRunsPostblit." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct P {
                int v;
                int* copies;
                int* dtors;
                this(this) { ++*copies; }
                ~this() { ++*dtors; }
            }
            void main() {
                int copies, dtors;
                P[2] w = [P(7, &copies, &dtors), P(8, &copies, &dtors)];
                copies = 0;
                dtors = 0;
                P[] d = w[];
                P[2] a = d[0 .. 2];
                assert(copies == 2);
                assert(a[0].v == 7 && a[1].v == 8);
            }
        });
    }
}

// An element-wise slice assignment runs the postblit for each element.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "dmd's interpreter does not run the postblit for `a[] = b[]`; "
        ~ "the sibling `Ctfe` unittest below pins the count it gives"),
)) {
    @("structCopy.staticArraySliceAssignRunsPostblit." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct P {
                int v;
                int* copies;
                int* dtors;
                this(this) { ++*copies; }
                ~this() { ++*dtors; }
            }
            void main() {
                int copies, dtors;
                P[2] w = [P(7, &copies, &dtors), P(8, &copies, &dtors)];
                copies = 0;
                dtors = 0;
                {
                    P[2] a = [P(1, &copies, &dtors), P(2, &copies, &dtors)];
                    copies = 0;
                    dtors = 0;
                    a[] = w[];
                    assert(copies == 2);
                    assert(dtors == 2);
                    assert(a[0].v == 7 && a[1].v == 8);
                }
            }
        });
    }
}

// A static array captured by a closure holds the copied elements.
static foreach (backend; Matrix!()) {
    @("structCopy.staticArrayClosureCaptureRunsPostblit." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct P {
                int v;
                int* copies;
                int* dtors;
                this(this) { ++*copies; }
                ~this() { ++*dtors; }
            }
            void main() {
                int copies, dtors;
                P[2] w = [P(7, &copies, &dtors), P(8, &copies, &dtors)];
                copies = 0;
                dtors = 0;
                P[2] a = w;
                assert(copies == 2);
                auto sum = () => a[0].v + a[1].v;
                assert(sum() == 15);
            }
        });
    }
}

// A copy constructor runs for each element of a static array declared
// from an lvalue.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "dmd's interpreter does not run the copy constructor for the "
        ~ "elements of a static array; the sibling `Ctfe` unittest below "
        ~ "pins the count it gives"),
)) {
    @("structCopy.staticArrayFromLvalueCopyCtor." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct P {
                int v;
                int* copies;
                int* dtors;
                this(int v, int* copies, int* dtors) {
                    this.v = v;
                    this.copies = copies;
                    this.dtors = dtors;
                }
                this(ref return scope const P o) {
                    v = o.v;
                    copies = cast(int*) o.copies;
                    dtors = cast(int*) o.dtors;
                    ++*copies;
                }
                ~this() { ++*dtors; }
            }
            void main() {
                int copies, dtors;
                P[2] w = [P(7, &copies, &dtors), P(8, &copies, &dtors)];
                copies = 0;
                dtors = 0;
                {
                    P[2] a = w;
                    assert(copies == 2);
                    assert(a[0].v == 7 && a[1].v == 8);
                }
                assert(dtors == 2);
            }
        });
    }
}

// A copy constructor runs for each element of a static array passed by
// value.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "dmd's interpreter does not run the copy constructor for the "
        ~ "elements of a static array; the sibling `Ctfe` unittest below "
        ~ "pins the count it gives"),
)) {
    @("structCopy.staticArrayArgRunsCopyCtor." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct P {
                int v;
                int* copies;
                int* dtors;
                this(int v, int* copies, int* dtors) {
                    this.v = v;
                    this.copies = copies;
                    this.dtors = dtors;
                }
                this(ref return scope const P o) {
                    v = o.v;
                    copies = cast(int*) o.copies;
                    dtors = cast(int*) o.dtors;
                    ++*copies;
                }
                ~this() { ++*dtors; }
            }
            int take(P[2] a) { return a[0].v * 10 + a[1].v; }
            void main() {
                int copies, dtors;
                P[2] w = [P(7, &copies, &dtors), P(8, &copies, &dtors)];
                copies = 0;
                dtors = 0;
                assert(take(w) == 78);
                assert(copies == 2);
            }
        });
    }
}

// A copy constructor runs for each element of a static array returned by
// value from an lvalue.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "dmd's interpreter does not run the copy constructor for the "
        ~ "elements of a static array; the sibling `Ctfe` unittest below "
        ~ "pins the count it gives"),
)) {
    @("structCopy.staticArrayReturnRunsCopyCtor." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct P {
                int v;
                int* copies;
                int* dtors;
                this(int v, int* copies, int* dtors) {
                    this.v = v;
                    this.copies = copies;
                    this.dtors = dtors;
                }
                this(ref return scope const P o) {
                    v = o.v;
                    copies = cast(int*) o.copies;
                    dtors = cast(int*) o.dtors;
                    ++*copies;
                }
                ~this() { ++*dtors; }
            }
            P[2] give(ref P[2] s) { return s; }
            void main() {
                int copies, dtors;
                P[2] w = [P(7, &copies, &dtors), P(8, &copies, &dtors)];
                copies = 0;
                dtors = 0;
                {
                    P[2] a = give(w);
                    assert(copies == 2);
                    assert(a[0].v == 7 && a[1].v == 8);
                }
            }
        });
    }
}


// Siblings pinning the divergences above: dmd's interpreter attaches no
// lowering to these constructions, so it runs neither the copy constructor
// for the elements of a static array nor the postblit for `a[] = b[]`.
@("structCopy.staticArrayFromLvalueCopyCtorNotRun.Ctfe")
@Tags(Ctfe.stringof)
unittest {
    0.shouldBeStatusOf!(Ctfe, q{
    struct P {
        int v;
        int* copies;
        int* dtors;
        this(int v, int* copies, int* dtors) {
            this.v = v;
            this.copies = copies;
            this.dtors = dtors;
        }
        this(ref return scope const P o) {
            v = o.v;
            copies = cast(int*) o.copies;
            dtors = cast(int*) o.dtors;
            ++*copies;
        }
        ~this() { ++*dtors; }
    }

        void main() {
        int copies, dtors;
        P[2] w = [P(7, &copies, &dtors), P(8, &copies, &dtors)];
        copies = 0;
        dtors = 0;

            P[2] a = w;
            assert(copies == 0);
        }
    });
}

@("structCopy.staticArraySliceAssignPostblitNotRun.Ctfe")
@Tags(Ctfe.stringof)
unittest {
    0.shouldBeStatusOf!(Ctfe, q{
    struct P {
        int v;
        int* copies;
        int* dtors;
        this(this) { ++*copies; }
        ~this() { ++*dtors; }
    }

        void main() {
        int copies, dtors;
        P[2] w = [P(7, &copies, &dtors), P(8, &copies, &dtors)];
        copies = 0;
        dtors = 0;

            P[2] a = [P(1, &copies, &dtors), P(2, &copies, &dtors)];
            a[] = w[];
            assert(copies == 0);
        }
    });
}
