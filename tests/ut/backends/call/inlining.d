module ut.backends.call.inlining;


import ut.backends;


// A small callee may run inside the caller's own instruction stream. These
// tests pin what a call must still do then.

static foreach (backend; Matrix!()) {
    @("inlining.arguments.evaluateInOrder." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int difference(int left, int right) { return left - right; }

            void main() {
                int trace;
                int mark(int digit) {
                    trace = trace * 10 + digit;
                    return digit;
                }
                assert(difference(mark(1), mark(2)) == -1);
                assert(trace == 12);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("inlining.throw.fromSmallCalleeIsCaughtByCaller." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void thrower(Exception thrown) { throw thrown; }

            void main() {
                auto expected = new Exception("inlined");
                bool caught;
                try
                    thrower(expected);
                catch (Exception actual)
                    caught = actual is expected;
                assert(caught);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("inlining.result.discardedStillRunsCallee." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int bump(ref int counter) { return ++counter; }

            void main() {
                int counter;
                bump(counter);
                bump(counter);
                assert(counter == 2);
                assert(bump(counter) == 3);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("inlining.recursion.tinyFunctionStaysCorrect." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int sum(int count) { return count == 0 ? 0 : count + sum(count - 1); }

            void main() {
                assert(sum(10) == 55);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("inlining.pointer.calleeReadsAndWritesThroughPointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Box {
                int value;
                int get() { return value; }
                void set(int number) { value = number; }
            }

            void store(int* place, int number) { *place = number; }
            int load(const(int)* place) { return *place; }

            void main() {
                int slot;
                store(&slot, 7);
                assert(load(&slot) == 7);
                Box box;
                box.set(9);
                assert(box.get() == 9);
            }
        });
    }
}


static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the native link fails on an undefined `extern(C)` symbol"),
)) {
    @("inlining.callee.neverRunCalleeWithUnresolvedSymbolDoesNotFailCaller." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            extern(C) int snakebite_ut_missing_symbol(int);

            int neverRuns(int number) { return snakebite_ut_missing_symbol(number); }

            int caller(bool call) {
                if (call)
                    return neverRuns(1);
                return 0;
            }

            void main() {
                assert(caller(false) == 0);
            }
        });
    }
}
