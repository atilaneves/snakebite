module ut.backends.call.leancalls;


import ut.backends;


// A function whose tree hands a statement to the evaluator (a `switch`) reads
// that call's own frame there, wherever the call is on the stack. The same
// function runs at several depths, with calls to functions that run no
// evaluator code between its statements.
static foreach (backend; Matrix!()) {
    @("leancalls.treeWithEvaluatedStatement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                int leaf(int x) { return x + 1; }

                int bump(int x) {
                    int y = x;
                    y += 2;
                    return y;
                }

                int mixed(int x) {
                    int total;
                    switch (x) {
                        case 1:
                            total = leaf(x);
                            break;
                        default:
                            total = leaf(x) * 2;
                            break;
                    }
                    total += bump(total);
                    switch (total % 3) {
                        case 0:
                            total += leaf(total);
                            break;
                        default:
                            total -= bump(total);
                            break;
                    }
                    return total;
                }

                int atDepth(int depth, int x) {
                    return depth == 0 ? mixed(x) : atDepth(depth - 1, x);
                }

                int answer() {
                    int sum;
                    foreach (round; 0 .. 4)
                        foreach (x; 0 .. 6)
                            sum += atDepth(x % 3 + round, x);
                    return sum == 228 ? 42 : sum;
                }
            },
            "answer",
        );
    }
}


// A statement that has not run has no node yet, and a function that has run
// many times can still build a node that hands control to the evaluator. The
// caller's own statement that the evaluator runs afterwards reads the
// caller's frame, not the frame of the function that built the node.
static foreach (backend; Matrix!()) {
    @("leancalls.statementBuiltAfterManyCalls." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                int leaf(int x) { return x + 1; }

                int bump(int x) {
                    int y = x;
                    y += 2;
                    return y;
                }

                int late(int x) {
                    if (x > 100) {
                        switch (x) {
                            case 101:
                                x += leaf(x);
                                break;
                            default:
                                x -= bump(x);
                                break;
                        }
                    }
                    return x + 1;
                }

                int answer() {
                    int sum;
                    foreach (i; 0 .. 50)
                        sum += late(i);
                    sum += late(500);
                    sum += late(101);
                    int local = 7;
                    switch (sum % 2) {
                        case 0:
                            local += 1;
                            break;
                        default:
                            local += 2;
                            break;
                    }
                    return sum == 1478 && local == 8 ? 42 : 1;
                }
            },
            "answer",
        );
    }
}


// A function whose tree never hands control to the evaluator calls itself:
// each call returns its own result through its own place, and a pointer
// that it passes down is the same one in every call.
static foreach (backend; Matrix!()) {
    @("leancalls.recursion." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                long sumTo(long n) {
                    if (n == 0)
                        return 0;
                    long rest = sumTo(n - 1);
                    return rest + n;
                }

                void fill(int* total, int n) {
                    if (n == 0)
                        return;
                    fill(total, n - 1);
                    *total += n;
                }

                int fib(int n) {
                    if (n < 2)
                        return n;
                    int a = fib(n - 1);
                    int b = fib(n - 2);
                    return a + b;
                }

                int answer() {
                    int total;
                    foreach (round; 0 .. 3) {
                        fill(&total, 6);
                        if (sumTo(8 + round) != 36 + round * 9 + round * (round - 1) / 2)
                            return 1;
                        if (fib(9) != 34)
                            return 2;
                    }
                    return total == 63 ? 42 : total;
                }
            },
            "answer",
        );
    }
}


// A failed index check inside functions that no evaluator code runs in throws
// through their callers. The function that catches goes on with its own
// result and place.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns an out-of-range index into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
)) {
    @("leancalls.exceptionThroughCalls." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                int read(int[] values, int index) {
                    int picked = values[index];
                    return picked + 1;
                }

                int through(int[] values, int index) {
                    int below = read(values, index);
                    return below * 2;
                }

                int catcher(int[] values, int index) {
                    int result = 0;
                    try {
                        result = through(values, index);
                    } catch (Throwable) {
                        result = -1;
                    }
                    return result;
                }

                int answer() {
                    int[] values = [1, 2, 3];
                    int sum;
                    foreach (round; 0 .. 3) {
                        sum += catcher(values, round);
                        sum += catcher(values, 3 + round);
                    }
                    return sum == 6 + 4 + 8 - 3 ? 42 : sum;
                }
            },
            "answer",
        );
    }
}


// A temporary with a destructor in a full expression whose later call throws
// is destroyed while the exception leaves that expression. Its destructor
// runs before the `try` of an outer function catches.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd CTFE does not destroy a temporary that a throw leaves"),
)) {
    @("leancalls.temporaryDestroyedByThrowThroughCalls." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                struct Counted {
                    int* count;
                    int value;
                    ~this() {
                        if (count !is null)
                            ++*count;
                    }
                }

                Counted make(int* count, int value) {
                    return Counted(count, value);
                }

                int thrower(int x) {
                    if (x > 0)
                        throw new Exception("thrown");
                    return x;
                }

                int through(int x) {
                    int below = thrower(x);
                    return below + 1;
                }

                int use(int* count, int x) {
                    return make(count, 5).value + through(x);
                }

                int catcher(int* count, int x) {
                    int result;
                    try
                        result = use(count, x);
                    catch (Exception)
                        result = -1;
                    return result;
                }

                int answer() {
                    int count;
                    int sum;
                    foreach (round; 0 .. 3) {
                        sum += catcher(&count, 0);
                        sum += catcher(&count, 1);
                    }
                    return sum == 15 && count == 6 ? 42 : sum * 100 + count;
                }
            },
            "answer",
        );
    }
}


// A fiber that yields inside nested calls resumes in the callee that
// yielded, also once the callee has run before. The main fiber runs calls of
// its own between, and the fiber then catches an exception thrown through
// calls.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot call native functions such as "
        ~ "`core.thread.fiber.Fiber`'s constructor"),
)) {
    @("leancalls.fiberYieldsInCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.thread.fiber: Fiber;

            int inner(int x) {
                int before = x + 1;
                Fiber.yield;
                return before;
            }

            int middle(int x) {
                int below = inner(x);
                return below * 2;
            }

            int twice(int x) {
                int below = x + 1;
                return below * 2;
            }

            int thrower(int x) {
                if (x > 0)
                    throw new Exception("thrown");
                return x;
            }

            int caught(int x) {
                int result;
                try
                    result = thrower(x);
                catch (Exception)
                    result = -1;
                return result;
            }

            void main() {
                int result;
                int afterThrow;
                auto fiber = new Fiber({
                    foreach (round; 0 .. 3)
                        result += middle(20 + round);
                    afterThrow = caught(1);
                });
                int between;
                foreach (round; 0 .. 3) {
                    fiber.call;
                    between += twice(round) + caught(1);
                }
                fiber.call;
                assert(fiber.state == Fiber.State.TERM);
                assert(between == 9);
                assert(result == 132);
                assert(afterThrow == -1);
            }
        });
    }
}
