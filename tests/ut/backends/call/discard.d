module ut.backends.call.discard;


import ut.backends;


// A value expression evaluated for no result must still compile and run.
static foreach (backend; Matrix!()) {
    @("discard.arithmetic." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int l = 5;
                cast(void) 3;
                cast(void) (l + 1);
                cast(void) (l * 2 - l);
                cast(void) -l;
                cast(void) ~l;
                cast(void) (l << 1);
                cast(void) (l / 2);
                cast(void) (l % 2);
                cast(void) (l & 1);
                cast(void) (l ? 1 : 2);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("discard.comparison." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int l = 5;
                int* p = &l;
                cast(void) (l < 6);
                cast(void) (l == 5);
                cast(void) (p is null);
                cast(void) !l;
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("discard.arrays." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[] a = [1, 2, 3];
                cast(void) a.length;
                cast(void) a[1];
                cast(void) a[1 .. 2];
                cast(void) a.ptr;
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("discard.cast." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int l = 5;
                cast(void) cast(long) l;
                cast(void) cast(double) l;
                cast(void) cast(ubyte) l;
            }
        });
    }
}


// The operand's side effect happens exactly once even though the value
// is dropped.
static foreach (backend; Matrix!()) {
    @("discard.sideEffects." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int counter;
                int bump() {
                    return ++counter;
                }

                int[] a = [1, 2, 3];
                cast(void) (bump + 1);
                assert(counter == 1);
                cast(void) (bump < 5);
                assert(counter == 2);
                cast(void) cast(long) bump;
                assert(counter == 3);
                cast(void) a[bump - 3];
                assert(counter == 4);
                cast(void) (bump + bump);
                assert(counter == 6);
                cast(void) -bump;
                assert(counter == 7);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("discard.operands." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S {
                int x;
                int y;
            }

            void main() {
                int l = 5;
                S s = S(1, 2);
                S* ps = &s;
                int[3] fixed = [1, 2, 3];
                cast(void) 1.5;
                cast(void) 'a';
                cast(void) l;
                cast(void) &l;
                cast(void) *ps;
                cast(void) ps.y;
                cast(void) s;
                cast(void) fixed[1];
                cast(void) fixed;
                cast(void) null;
                cast(void) true;
                cast(void) (1.5 * 2);
                cast(void) fixed.length;
                cast(void) fixed[];
            }
        });
    }
}


// dmd lowers a dynamic array literal to a druntime allocation call. The
// literal still allocates and evaluates its elements when nothing reads
// the array.
static foreach (backend; Matrix!()) {
    @("discard.arrayLiteral." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int counter;
                int bump() {
                    return ++counter;
                }

                cast(void) [bump, bump + 1];
                assert(counter == 2);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("discard.literals." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S {
                int x;
                int y;
            }

            void main() {
                int l = 5;
                cast(void) "abc";
                cast(void) S(1, 2);
                cast(void) S(l, 2);
                cast(void) cast(int[2]) [l, 2];
                assert(l == 5);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("discard.delegates." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C {
                int v = 3;
                int get() { return v; }
            }

            struct T {
                int v;
                int get() { return v; }
            }

            int free() { return 1; }

            void main() {
                int l = 5;
                auto c = new C;
                T t;
                int delegate() dg = &c.get;
                cast(void) &c.get;
                cast(void) &t.get;
                cast(void) () => l;
                cast(void) function() { return 1; };
                cast(void) &free;
                cast(void) dg;
                assert(dg() == 3);
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot evaluate `dg.ptr`"),
)) {
    @("discard.delegateWords." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C {
                int get() { return 3; }
            }

            void main() {
                int delegate() dg = &(new C).get;
                cast(void) dg.ptr;
                cast(void) dg.funcptr;
                assert(dg() == 3);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("discard.equality." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S {
                int x;
                int y;
            }

            void main() {
                int counter;
                int[] bump() {
                    ++counter;
                    return [1, 2, 3];
                }

                int[] a = [1, 2, 3];
                int[3] fa = [1, 2, 3];
                int[3] fb = [1, 2, 4];
                S s = S(1, 2);
                S u = S(1, 3);
                real r = 2.5;
                int delegate() dg;
                cast(void) (a == bump);
                cast(void) (bump != a);
                assert(counter == 2);
                cast(void) (fa == fb);
                cast(void) (s == u);
                cast(void) (s is u);
                cast(void) (r < 3.5);
                cast(void) (dg == dg);
                cast(void) (dg is null);
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot interpret vector arithmetic"),
)) {
    @("discard.vector." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                __vector(int[4]) v = 1;
                __vector(int[4]) w = 2;
                cast(void) (v + w);
                cast(void) v.array;
                cast(void) (v == w);
                cast(void) (v < w);
            }
        });
    }
}


// A discarded read of an lvalue makes no copy, so no postblit and no
// destructor runs. A discarded rvalue is destroyed exactly once.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE can't read a mutable static variable"),
)) {
    @("discard.lifetimes." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S {
                static int copies;
                static int destroyed;
                int x;
                this(int x) { this.x = x; }
                this(this) { ++copies; }
                ~this() { ++destroyed; }
            }

            struct W {
                S s;
            }

            S make() { return S(1); }

            void main() {
                cast(void) S(1);
                assert(S.destroyed == 1);
                cast(void) make();
                assert(S.destroyed == 2);
                assert(S.copies == 0);

                S s = S(2);
                S* ps = &s;
                S[] arr = [S(3)];
                W w = W(S(5));
                W* pw = &w;
                const destroyed = S.destroyed;
                const copies = S.copies;
                cast(void) *ps;
                cast(void) arr[0];
                cast(void) w.s;
                cast(void) pw.s;
                cast(void) *pw;
                assert(S.destroyed == destroyed);
                assert(S.copies == copies);
            }
        });
    }
}
