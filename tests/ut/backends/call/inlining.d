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
    @("inlining.recursion.selfCallingFunctionStaysCorrect." ~ backend.stringof)
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


static foreach (backend; Matrix!()) {
    @("inlining.branch.conditionalExpressionCalleeTakesBothArms." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int pick(bool first) { return first ? 11 : 22; }

            void main() {
                assert(pick(true) == 11);
                assert(pick(false) == 22);
                int total;
                foreach (index; 0 .. 3)
                    total += pick(index == 1);
                assert(total == 22 + 11 + 22);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("inlining.return.earlyReturnJumpsToEndOfCallee." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int sign(int number) {
                if (number < 0)
                    return -1;
                return 1;
            }

            // Has an `if`, so it compiles when it first runs, after `sign`
            // is complete and can be copied into it.
            int scaled(int number) {
                const factor = sign(number);
                if (factor > 0)
                    return factor * 10;
                return factor * 100;
            }

            void main() {
                assert(sign(-3) == -1);
                assert(scaled(4) == 10);
                assert(scaled(-4) == -100);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("inlining.address.calleeReturningFunctionAddressStaysCorrect." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int larger(int number) {
                int total;
                foreach (digit; 0 .. number)
                    total += digit;
                return total;
            }

            int function(int) pick() { return &larger; }

            int caller(bool call) {
                if (call)
                    return pick()(5);
                return 0;
            }

            void main() {
                assert(caller(false) == 0);
                assert(caller(true) == 10);
            }
        });
    }
}


// A callee whose operands are places moves into the caller's frame with
// their address slots, and it is copied more than once.
static foreach (backend; Matrix!()) {
    @("inlining.places.calleeOperandsMoveWithTheFrame." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Node { int value; Node* next; }
            class Counter { int count; }

            int second(Node* node) { return node.next.value; }
            void bump(Counter counter, int by) { counter.count += by; }
            int viaPointer(int* pointer, size_t index) {
                return pointer[index] * 10 + pointer[0];
            }

            void main() {
                Node c = Node(3, null);
                Node b = Node(2, &c);
                Node a = Node(1, &b);
                assert(second(&a) == 2);
                assert(second(&b) + second(&a) == 5);

                auto counter = new Counter;
                bump(counter, 4);
                bump(counter, 5);
                assert(counter.count == 9);

                int[3] values = [7, 8, 9];
                assert(viaPointer(values.ptr, 2) == 97);
                assert(viaPointer(values.ptr, 1) + viaPointer(values.ptr, 0)
                    == 87 + 77);
            }
        });
    }
}
