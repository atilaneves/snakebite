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
static foreach (backend; Matrix!()) {
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
