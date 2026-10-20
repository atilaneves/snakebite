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
