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
                assert(dtors == 2);
            }
        });
    }
}


// `C[2] a = C(0)` calls the copy constructor for each element and the
// destructor once for the temporary.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "dmd's interpreter does not follow the lowering that runs the copy "
        ~ "constructor for the elements of a static array"),
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
                assert(dtors == 2);
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
                dtors = 0;
                {
                    H h2 = h1;
                    assert(copies == 2);
                    assert(h2.f[0].v == 7 && h2.f[1].v == 8);
                }
                assert(dtors == 2);
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
                assert(dtors == 4);
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
                {
                    P[2] a = d[0 .. 2];
                    assert(copies == 2);
                    assert(a[0].v == 7 && a[1].v == 8);
                }
                assert(dtors == 2);
            }
        });
    }
}

// An element-wise slice assignment runs the postblit for each element.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "dmd's interpreter does not run the postblit for `a[] = b[]`"),
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
                this(this) { ++*copies; }
            }
            void main() {
                int copies;
                P[2] w = [P(7, &copies), P(8, &copies)];
                copies = 0;
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
        "dmd's interpreter does not follow the lowering that runs the copy "
        ~ "constructor for the elements of a static array"),
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
        "dmd's interpreter does not follow the lowering that runs the copy "
        ~ "constructor for the elements of a static array"),
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
                assert(dtors == 2);
            }
        });
    }
}

// A copy constructor runs for each element of a static array returned by
// value from an lvalue.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "dmd's interpreter does not follow the lowering that runs the copy "
        ~ "constructor for the elements of a static array"),
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
                assert(dtors == 2);
            }
        });
    }
}


// A static array of structs that have only a destructor, declared from one
// element, destroys the temporary once and each element at scope exit.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "dmd's interpreter does not follow the lowering that runs the copy "
        ~ "constructor or postblit for the elements of a static array"),
)) {
    @("structCopy.dtorOnlyElementFromRvalue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct D {
                int v;
                int* dtors;
                ~this() { ++*dtors; }
            }
            void main() {
                int copies, dtors;
                {
                    D[2] a = D(3, &dtors);
                    assert(a[0].v == 3 && a[1].v == 3);
                    assert(dtors == 1);
                }
                assert(dtors == 3);
            }
        });
    }
}

// A postblit that throws for the second element of a declared static array
// leaves the first element destroyed and the others never built.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "dmd's interpreter does not follow the lowering that runs the copy "
        ~ "constructor or postblit for the elements of a static array"),
)) {
    @("structCopy.staticArrayDeclThrowingPostblit." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct T {
                int v;
                int* copies;
                int* dtors;
                this(this) {
                    if (v == 2)
                        throw new Exception("x");
                    ++*copies;
                }
                ~this() { ++*dtors; }
            }
            void main() {
                int copies, dtors;
                T[3] w = [
                    T(1, &copies, &dtors),
                    T(2, &copies, &dtors),
                    T(3, &copies, &dtors),
                ];
                copies = 0;
                dtors = 0;
                bool caught;
                try {
                    T[3] a = w;
                } catch (Exception) {
                    caught = true;
                }
                assert(caught);
                assert(copies == 1);
                assert(dtors == 1);
            }
        });
    }
}

// A static array read from an associative array value runs the postblit for
// each element.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "the counters are module-level variables, which compile-time "
        ~ "evaluation cannot write"),
)) {
    @("structCopy.staticArrayAssociativeArrayValueRead." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int copies, dtors;
            struct P {
                int v;
                this(this) { ++copies; }
                ~this() { ++dtors; }
            }
            void main() {
                P[2] w = [P(7), P(8)];
                P[2][int] aa;
                aa[1] = w;
                copies = 0;
                dtors = 0;
                {
                    P[2] a = aa[1];
                    assert(a[1].v == 8);
                }
                assert(copies == 2);
                assert(dtors == 2);
            }
        });
    }
}

// Appending a static array to an array of static arrays runs the postblit
// for each element.
static foreach (backend; Matrix!()) {
    @("structCopy.staticArrayAppendRunsPostblit." ~ backend.stringof)
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
                P[2][] d;
                d ~= w;
                assert(d[0][1].v == 8);
                assert(copies == 2);
            }
        });
    }
}

// An array literal of static arrays runs the postblit for each element of
// each static array.
static foreach (backend; Matrix!()) {
    @("structCopy.staticArrayLiteralOfArraysRunsPostblit." ~ backend.stringof)
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
                P[2][] d = [w, w];
                assert(d[1][1].v == 8);
                assert(copies == 4);
                assert(dtors == 0);
            }
        });
    }
}

// `foreach` over an array of static arrays copies each static array into the
// loop variable and destroys it afterwards.
static foreach (backend; Matrix!()) {
    @("structCopy.staticArrayForeachByValueRunsPostblit." ~ backend.stringof)
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
                int sum;
                foreach (P[2] e; w[])
                    sum += e[0].v + e[1].v;
                assert(sum == 10);
                assert(copies == 4);
                assert(dtors == 4);
            }
        });
    }
}

// A static array declared in a `scope(exit)` body is copied when the scope
// ends.
static foreach (backend; Matrix!()) {
    @("structCopy.staticArrayDeclInScopeExit." ~ backend.stringof)
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
                    scope (exit) {
                        P[2] a = w;
                        assert(a[1].v == 8);
                    }
                }
                assert(copies == 2);
                assert(dtors == 2);
            }
        });
    }
}

// A static array declared from one element in a `finally` body runs the copy
// constructor for each element.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "dmd's interpreter does not follow the lowering that runs the copy "
        ~ "constructor or postblit for the elements of a static array"),
)) {
    @("structCopy.staticArrayFromRvalueInFinally." ~ backend.stringof)
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
                try {
                    throw new Exception("x");
                } catch (Exception) {
                } finally {
                    C[2] a = C(1, &copies, &dtors);
                    assert(a[1].v == 1);
                }
                assert(copies == 2);
                assert(dtors == 3);
            }
        });
    }
}

// A static array declared from one element in a lambda runs the copy
// constructor for each element.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "dmd's interpreter does not follow the lowering that runs the copy "
        ~ "constructor or postblit for the elements of a static array"),
)) {
    @("structCopy.staticArrayFromRvalueInLambda." ~ backend.stringof)
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
                auto f = (int x) {
                    C[2] a = C(x, &copies, &dtors);
                    return a[1].v;
                };
                assert(f(4) == 4);
                assert(copies == 2);
                assert(dtors == 3);
            }
        });
    }
}

// A static array declared from one element in an `opApply` loop body runs the
// copy constructor for each element, on each iteration.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "dmd's interpreter does not follow the lowering that runs the copy "
        ~ "constructor or postblit for the elements of a static array"),
)) {
    @("structCopy.staticArrayFromRvalueInOpApplyBody." ~ backend.stringof)
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
            struct R {
                int opApply(scope int delegate(int) dg) {
                    foreach (i; 0 .. 2)
                        if (auto r = dg(i))
                            return r;
                    return 0;
                }
            }
            void main() {
                int copies, dtors;
                int sum;
                foreach (i; R()) {
                    C[2] a = C(i, &copies, &dtors);
                    sum += a[1].v;
                }
                assert(sum == 1);
                assert(copies == 4);
                assert(dtors == 6);
            }
        });
    }
}

// A static array declared from one element in a loop body runs the copy
// constructor for each element, on each iteration.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "dmd's interpreter does not follow the lowering that runs the copy "
        ~ "constructor or postblit for the elements of a static array"),
)) {
    @("structCopy.staticArrayFromRvalueInLoop." ~ backend.stringof)
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
                foreach (i; 0 .. 3) {
                    C[2] a = C(i, &copies, &dtors);
                    assert(a[1].v == i);
                }
                assert(copies == 6);
                assert(dtors == 9);
            }
        });
    }
}


// A MEMORY-class returned local is constructed in its caller's result place.
// Its constructor and a nonescaping nested function must see that same place.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.diverges,
        "CTFE copies the returned local without rebinding its constructor's "
        ~ "object address; the sibling test records that result"),
)) {
    @("structCopy.returnedLocalKeepsConstructorAddress." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, returnedLocalAddressCode);
    }
}

@("structCopy.returnedLocalKeepsConstructorAddress.CtfeDivergence")
@Tags("Ctfe")
unittest {
    1.shouldBeStatusOf!(Ctfe, returnedLocalAddressCode);
}

private enum returnedLocalAddressCode = q{
            struct S {
                S* constructed;
                long[4] values;
                this(long value) {
                    constructed = &this;
                    values[0] = value;
                }
            }
            S make(long value) {
                auto result = S(value);
                void update() { ++result.values[0]; }
                update();
                if (value < 0) return result;
                result.values[1] = value;
                return result;
            }
            int main() {
                auto first = make(7);
                if (first.constructed != &first) return 1;
                if (first.values[0] != 8 || first.values[1] != 7) return 2;
                auto second = make(-2);
                if (second.constructed != &second) return 3;
                return second.values[0] == -1 ? 0 : 4;
            }
        };


// Returning different named locals copies the selected value directly into
// the result place, even when neither named local can share that place.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot cast a constructor's object address to size_t"),
)) {
    @("structCopy.returnCopyCtorKeepsResultAddress." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S {
                size_t copied;
                int* copies;
                long[4] values;
                this(long value, int* count) {
                    copies = count;
                    values[0] = value;
                }
                this(ref return scope const S other) {
                    copied = cast(size_t) &this;
                    copies = cast(int*) other.copies;
                    values = other.values;
                    ++*copies;
                }
            }
            S choose(bool first, int* count) {
                auto left = S(7, count);
                auto right = S(9, count);
                if (first) return left;
                return right;
            }
            int main() {
                int count;
                auto left = choose(true, &count);
                if (left.copied != cast(size_t) &left || left.values[0] != 7) return 1;
                if (count != 1) return 2;
                auto right = choose(false, &count);
                if (right.copied != cast(size_t) &right || right.values[0] != 9) return 3;
                return count == 2 ? 0 : 4;
            }
        });
    }
}
