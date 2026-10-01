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
