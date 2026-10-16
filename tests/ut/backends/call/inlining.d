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


static foreach (backend; Matrix!()) {
    @("inlining.locals.calleeWithSeveralStatementsKeepsItsOwnLocals." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int mix(int left, int right) {
                int sum = left + right;
                int product = left * right;
                sum += 1;
                product -= sum;
                return product * 2 + sum;
            }

            void main() {
                int first = 3;
                assert(mix(first, 4) == 2 * (12 - 8) + 8);
                assert(first == 3);
                assert(mix(2, 3) + mix(mix(2, 3), 1) == 6 + 4);

            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("inlining.parameters.arithmeticResultIntoAnArgumentDestination." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int add(int x, int y) { return x + y; }
            int mul(int x, int y) { return x * y; }

            void main() {
                int a = 3;
                int b = 4;
                a = add(a, b);
                assert(a == 7);
                b = add(a, b);
                assert(b == 11);
                a = mul(a, b);
                assert(a == 77);
                a = add(b, a);
                assert(a == 88);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("inlining.branch.ifElseAndEarlyReturnInsideLargerCallee." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int classify(int number) {
                if (number < 0)
                    return -1;
                int result;
                if (number == 0)
                    result = 100;
                else
                    result = number > 10 ? number * 2 + 1000 : number * 2;
                return result + 1;
            }

            void main() {
                assert(classify(-5) == -1);
                assert(classify(0) == 101);
                assert(classify(4) == 9);
                assert(classify(11) == 1023);
                int total;
                foreach (index; -1 .. 12)
                    total += classify(index);
                assert(total == -1 + 101 + 3 + 5 + 7 + 9 + 11 + 13 + 15 + 17 + 19 + 21 + 1023);

            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("inlining.parameters.getterResultIntoItsOwnPointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Node { int value; Node* next; }
            Node* following(Node* node) { return node.next; }

            void main() {
                Node c = Node(3, null);
                Node b = Node(2, &c);
                Node a = Node(1, &b);
                Node* p = &a;
                p = following(p);
                assert(p.value == 2);
                p = following(p);
                assert(p.value == 3);
                p = following(p);
                assert(p is null);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("inlining.parameters.sameArgumentTwice." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int add(int x, int y) { return x + y; }
            int minus(int x, int y) { return x - y; }

            void main() {
                int a = 21;
                assert(add(a, a) == 42);
                assert(minus(a, a) == 0);
                a = add(a, a);
                assert(a == 42);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("inlining.parameters.calleeWritingItsParameterLeavesTheCaller." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int clobber(int x) { return x += 100; }
            int clobberTwo(int x, int y) { return x = y; }
            int clearSecond(int x, int y) { return y = x - x; }

            void main() {
                int a = 5;
                int b = 6;
                assert(clobber(a) == 105);
                assert(a == 5);
                assert(clobberTwo(a, b) == 6);
                assert(a == 5);
                assert(b == 6);
                assert(clearSecond(a, b) == 0);
                assert(a == 5);
                assert(b == 6);
                int c = clobber(b);
                assert(c == 106);
                assert(b == 6);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("inlining.parameters.refArgument." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void increment(ref int x) { x += 1; }
            int read(ref int x) { return x; }
            int addInto(ref int x, int y) { x = x + y; return x; }

            void main() {
                int a = 1;
                increment(a);
                increment(a);
                assert(a == 3);
                assert(read(a) == 3);
                assert(addInto(a, a) == 6);
                assert(a == 6);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("inlining.parameters.argumentWrittenByALaterArgument." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int add3(int x, int y, int z) { return x + y + z; }

            void main() {
                int a = 5;
                assert(add3(a, a = 1, 10) == 16);
                assert(a == 1);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("inlining.parameters.pointerArithmeticResultIntoAnArgumentDestination." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Pair { int first; int second; }

            int* advance(int* pointer, size_t count) { return pointer + count; }
            int* secondOf(Pair* pair) { return &pair.second; }

            void main() {
                int[4] values = [10, 20, 30, 40];
                int* p = values.ptr;
                size_t step = 2;
                p = advance(p, step);
                assert(*p == 30);
                p = advance(p, 1);
                assert(*p == 40);
                assert(*advance(values.ptr, step) == 30);

                Pair pair = Pair(1, 2);
                Pair* q = &pair;
                int* r = secondOf(q);
                assert(*r == 2);
                assert(*secondOf(q) == 2);
                assert(q.first == 1);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("inlining.parameters.compoundAssignmentResultIntoAnArgumentDestination." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int addTo(int x, int y) { return x += y; }
            int subtractFrom(int x, int y) { return x -= y; }
            int incremented(int x) { return ++x; }

            void main() {
                int a = 3;
                int b = 4;
                a = addTo(a, b);
                assert(a == 7);
                b = addTo(a, b);
                assert(b == 11);
                a = subtractFrom(b, a);
                assert(a == 4);
                a = incremented(a);
                assert(a == 5);
                assert(addTo(a, b) == 16);
                assert(a == 5);
                assert(b == 11);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("inlining.parameters.receiverIsFixedBeforeArgumentsRun." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Box {
                int value;
                Box* next;
                int plus(int by) { return value + by; }
                Box* following() { return next; }
                int bump() { return ++value; }
            }

            void main() {
                Box second = Box(20, null);
                Box first = Box(1, &second);
                Box* p = &first;
                assert(p.plus((p = &second).value) == 21);
                assert(p is &second);

                p = &first;
                p = p.following();
                assert(p is &second);

                assert(first.plus(first.bump()) == 4);
                assert(first.value == 2);
            }
        });
    }
}


static foreach (backend; Matrix!()) {
    @("inlining.result.refToFieldAtNonZeroOffsetIsWrittenReadAndUpdated." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct S {
                int x;
                int y;
                ref int getY() return { return y; }
            }

            void main() {
                S s;
                s.getY() = 9;
                assert(s.y == 9 && s.x == 0);
                assert(s.getY() == 9);
                s.getY() += 4;
                assert(s.y == 13 && s.x == 0);
            }
        });
    }
}
