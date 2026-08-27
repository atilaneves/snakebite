module ut.backends.run.arrays;


// Every test here reaches an AST node class that no test
// chosen before it reached, and is named for that class.
// Together they reach every class the frontend produced
// for a corpus of guest programs.
//
// The expected exit status is what `dmd -run` gives the
// program, so each test states what compiled D does. A
// backend joins a test's `Matrix` when it agrees.


import ut.backends;


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("catAssignExp." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Name {
                string text;
            }

            string a() {
                return "Al" ~ "ice";
            }

            string b() {
                char[] buf;
                buf ~= "Alice";
                return buf.idup;
            }

            void main() {
                int[Name] ages;
                ages[Name(a())] = 30;

                Name key = Name(b());
                ages[key] = 31;
                assert(ages.length == 1);
                assert(ages[Name("Alice")] == 31);
                assert((Name("Bob") in ages) is null);

                int sum;
                foreach (k, v; ages) {
                    sum += v;
                    assert(k.text == "Alice");
                }
                assert(sum == 31);

                assert(ages.remove(Name("Alice")));
                assert(ages.length == 0);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("arrayInitializer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int[] arr = [1, 2, 3];

            int sum() {
                return arr[0] + arr[1] + arr[2];
            }

            void main() {
                // First touch is from a lazily-compiled callee, not the
                // entry itself; it must still see the initialised contents.
                assert(sum() == 6);

                assert(arr.length == 3);
                assert(arr[0] == 1);
                assert(arr[1] == 2);
                assert(arr[2] == 3);

                arr[0] = 99;
                assert(arr[0] == 99);
                arr ~= 4;
                assert(arr.length == 4);
                assert(arr[3] == 4);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("catExp." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                ubyte first = cast(ubyte) 10;
                ubyte second = cast(ubyte)(first + 32);
                ubyte[] left = [first];
                ubyte[] right = [second];

                const combined = left ~ right;

                assert(combined.length == 2);
                assert(combined[0] == first);
                assert(combined[1] == second);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("realExp." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            long longValue(long seed) {
                return seed;
            }

            double doubleValue(double seed) {
                return seed;
            }

            void main() {
                long first = longValue(1_000_000_000_000L);
                long[] longs =
                    [first, first + 1, first + 2, first + 3];

                long[] longCopy = longs.dup;
                longCopy[0] = longValue(-1);

                assert(longCopy.length == 4);
                assert(longCopy[0] == -1);
                assert(longs[0] == 1_000_000_000_000L);
                assert(longCopy[1] == longs[1]);
                assert(longCopy[2] == longs[2]);
                assert(longCopy[3] == longs[3]);

                double firstDouble = doubleValue(1.5);
                double[] doubles = [firstDouble, firstDouble + 1.5];

                immutable(double)[] frozenDoubles = doubles.idup;
                doubles[0] = doubleValue(-2.5);

                assert(frozenDoubles[0] == 1.5);
                assert(frozenDoubles[1] == 3.0);
                assert(doubles[0] == -2.5);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed),
    Omit!(Interpreter, Because.unconfirmed),
)) {
    @("catDcharAssignExp." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            dchar pick(dchar value) {
                return value;
            }

            void main() {
                char[] s;
                s ~= pick('A');

                assert(s.length == 1);
                assert(s[0] == 'A');
            }
        });
    }
}

