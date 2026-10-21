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


// A statement that the evaluator runs sits on a path that a function called
// many times takes only now and then. Each call that takes it still gives its
// caller back the caller's own state: the caller's next statement that the
// evaluator runs reads the caller's frame.
static foreach (backend; Matrix!()) {
    @("leancalls.coldEvaluatedStatementInHotCallee." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                int leaf(int x) { return x + 1; }

                int hot(int x) {
                    int y = x * 2;
                    if (x % 97 == 96) {
                        switch (y % 3) {
                            case 0:
                                y += leaf(y);
                                break;
                            default:
                                y -= 1;
                                break;
                        }
                    }
                    return y + leaf(x);
                }

                int caller(int x) {
                    int total = hot(x);
                    switch (total % 2) {
                        case 0:
                            total += 1;
                            break;
                        default:
                            total += 2;
                            break;
                    }
                    return total;
                }

                int answer() {
                    int sum;
                    foreach (i; 0 .. 1000)
                        sum += caller(i);
                    return sum == 1505258 ? 42 : sum;
                }
            },
            "answer",
        );
    }
}


// `alloca` memory lasts until the function that allocated it returns, in
// every call of a loop. A callee's own `alloca` and an exception that a
// callee throws past another callee's `alloca` leave the caller's block as it
// was.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot call alloca"),
)) {
    @("leancalls.allocaInLoopOfCalls." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                import core.stdc.stdlib: alloca;

                int helper(int seed) {
                    auto q = cast(int*) alloca(4 * int.sizeof);
                    foreach (i; 0 .. 4)
                        q[i] = -seed;
                    return q[0];
                }

                int failing(int seed) {
                    auto q = cast(int*) alloca(4 * int.sizeof);
                    foreach (i; 0 .. 4)
                        q[i] = seed * 7;
                    if (seed % 5 == 0)
                        throw new Exception("thrown");
                    return q[3];
                }

                int middle(int seed) {
                    int result;
                    try
                        result = failing(seed);
                    catch (Exception)
                        result = -1;
                    return result;
                }

                int user(int seed) {
                    auto p = cast(int*) alloca(4 * int.sizeof);
                    foreach (i; 0 .. 4)
                        p[i] = seed + i;
                    int other = helper(seed) + middle(seed);
                    int sum;
                    foreach (i; 0 .. 4)
                        sum += p[i];
                    return sum + other;
                }

                int answer() {
                    int total;
                    foreach (i; 0 .. 200)
                        total += user(i);
                    return total == 172860 ? 42 : total;
                }
            },
            "answer",
        );
    }
}


// An exception leaves a callee that ran a statement through the evaluator.
// The function that catches it runs statements through the evaluator before
// and after its `try`, and those read its own frame.
static foreach (backend; Matrix!()) {
    @("leancalls.throwPastEvaluatedCallee." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                int thrower(int x) {
                    if (x % 3 == 0)
                        throw new Exception("thrown");
                    return x;
                }

                int evaluated(int x) {
                    int y = x;
                    switch (y % 2) {
                        case 0:
                            y += 10;
                            break;
                        default:
                            y += 20;
                            break;
                    }
                    return thrower(y) + y;
                }

                int catcher(int x) {
                    int local = x * 3;
                    switch (local % 4) {
                        case 0:
                            local += 1;
                            break;
                        default:
                            local += 2;
                            break;
                    }
                    int result;
                    try
                        result = evaluated(x);
                    catch (Exception)
                        result = -local;
                    switch (result % 2) {
                        case 0:
                            result += local;
                            break;
                        default:
                            result -= local;
                            break;
                    }
                    return result;
                }

                int answer() {
                    int sum;
                    foreach (i; 0 .. 30)
                        sum += catcher(i);
                    return sum == 1552 ? 42 : sum;
                }
            },
            "answer",
        );
    }
}


// An exception leaves an evaluated callee inside a full expression whose
// temporary has a destructor. The destructor runs guest code that reads its
// own frame before the `try` catches the exception, and the catching function
// still reads its own frame afterwards.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd CTFE does not destroy a temporary that a throw leaves"),
)) {
    @("leancalls.throwPastEvaluatedCalleeWithTemporary." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                struct Guard {
                    int* runs;
                    int value;

                    ~this() {
                        int step = value;
                        switch (step % 2) {
                            case 0:
                                step += 1;
                                break;
                            default:
                                step += 2;
                                break;
                        }
                        *runs += step - value;
                    }
                }

                int thrower(int x) {
                    if (x % 3 == 0)
                        throw new Exception("thrown");
                    return x;
                }

                int evaluated(int x) {
                    int y = x;
                    switch (y % 2) {
                        case 0:
                            y += 10;
                            break;
                        default:
                            y += 20;
                            break;
                    }
                    return thrower(y) + y;
                }

                int catcher(int x, ref int runs) {
                    int local = x * 3;
                    switch (local % 4) {
                        case 0:
                            local += 1;
                            break;
                        default:
                            local += 2;
                            break;
                    }
                    int result;
                    try
                        result = Guard(&runs, x).value + evaluated(x);
                    catch (Exception)
                        result = -local;
                    switch (result % 2) {
                        case 0:
                            result += local;
                            break;
                        default:
                            result -= local;
                            break;
                    }
                    return result;
                }

                int answer() {
                    int sum;
                    int runs;
                    foreach (i; 0 .. 30)
                        sum += catcher(i, runs);
                    // 15 even values add 1 and 15 odd values add 2: 45 in all.
                    return runs == 45 && sum == 852 ? 42 : runs * 10000 + sum;
                }
            },
            "answer",
        );
    }
}


// A `return` that the evaluator runs (one in a `case`) writes only the bytes
// of the result type. The caller reads the whole value: a negative `byte`, a
// large `ushort`, a `bool` and a `float` keep their values, whatever the call
// before them left at the same place on the frame stack.
static foreach (backend; Matrix!()) {
    @("leancalls.evaluatedReturnOfNarrowResults." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                long ones() { return -1; }
                long zeros() { return 0; }

                byte narrowByte(int x) {
                    switch (x) {
                        case 0: return cast(byte) -3;
                        default: return cast(byte) 5;
                    }
                }

                ushort narrowUshort(int x) {
                    switch (x) {
                        case 0: return cast(ushort) 0xFFFE;
                        default: return cast(ushort) 7;
                    }
                }

                bool narrowBool(int x) {
                    switch (x) {
                        case 0: return true;
                        default: return false;
                    }
                }

                float narrowFloat(int x) {
                    switch (x) {
                        case 0: return 1.5f;
                        default: return -2.25f;
                    }
                }

                long round() {
                    long total;
                    total += zeros();
                    total += narrowByte(0);
                    total += ones();
                    total += narrowByte(1);
                    total += zeros();
                    total += narrowUshort(0);
                    total += ones();
                    total += narrowUshort(1);
                    total += ones();
                    total += narrowBool(0);
                    total += ones();
                    total += narrowBool(1);
                    total += ones();
                    total += cast(long) (narrowFloat(0) * 4);
                    total += ones();
                    total += cast(long) (narrowFloat(1) * 4);
                    return total;
                }

                int answer() {
                    long sum;
                    foreach (i; 0 .. 3)
                        sum += round();
                    // Each round: -3 + 5 + 65534 + 7 + 1 + 0 + 6 - 9, and six
                    // calls of `ones`.
                    return sum == 3 * 65535 ? 42 : cast(int) sum;
                }
            },
            "answer",
        );
    }
}


// The same narrow results from calls deep enough that some of them run past
// the limit of the native stack, on a new piece of it.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE stops at a fixed recursion limit far below this depth"),
)) {
    @("leancalls.evaluatedReturnOfNarrowResultsAtDepth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                byte narrowByte(int x) {
                    switch (x) {
                        case 0: return cast(byte) -3;
                        default: return cast(byte) 5;
                    }
                }

                ushort narrowUshort(int x) {
                    switch (x) {
                        case 0: return cast(ushort) 0xFFFE;
                        default: return cast(ushort) 7;
                    }
                }

                bool narrowBool(int x) {
                    switch (x) {
                        case 0: return true;
                        default: return false;
                    }
                }

                float narrowFloat(int x) {
                    switch (x) {
                        case 0: return 1.5f;
                        default: return -2.25f;
                    }
                }

                long walk(int n) {
                    if (n == 0)
                        return 0;
                    const parity = n % 2;
                    long here = narrowByte(parity);
                    here += narrowUshort(parity);
                    here += narrowBool(parity);
                    here += cast(long) (narrowFloat(parity) * 4);
                    return walk(n - 1) + here;
                }

                int answer() {
                    // 5,000 odd levels give 5 + 7 + 0 - 9 and 5,000 even
                    // levels give -3 + 65534 + 1 + 6.
                    const sum = walk(10_000);
                    return sum == 5_000L * 3 + 5_000L * 65_538 ? 42 : 1;
                }
            },
            "answer",
        );
    }
}


// A `char` result that a `return` in a `try` statement gives, with a
// `finally` that runs after it, is the whole unsigned value at the caller:
// for the `return` that the evaluator runs in a `case` and for the one that
// the tree runs.
static foreach (backend; Matrix!()) {
    @("leancalls.charReturnedFromTryFinally." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                long ones() { return -1; }

                char pick(int x, ref int cleanups) {
                    try {
                        switch (x) {
                            case 0: return cast(char) 0xE9;
                            default: break;
                        }
                        return cast(char) 0xF0;
                    } finally {
                        cleanups += 1;
                    }
                }

                int answer() {
                    int cleanups;
                    long total;
                    foreach (i; 0 .. 3) {
                        total += ones();
                        total += pick(0, cleanups);
                        total += ones();
                        total += pick(1, cleanups);
                    }
                    return total == 3 * (0xE9 + 0xF0 - 2) && cleanups == 6
                        ? 42 : cast(int) total;
                }
            },
            "answer",
        );
    }
}


// A `try` in a call catches a throw that left a call below it, after a
// statement of the same call ran in the evaluator. A statement of the call
// that runs for the first time after that is built for its own function,
// not for the function that called it, which returns `ref`.
static foreach (backend; Matrix!()) {
    @("leancalls.statementBuiltAfterCaughtThrow." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                int boom(int mode) {
                    if (mode != 0)
                        throw new Exception("boom");
                    return mode;
                }

                int late(int mode) {
                    int value = mode;
                    try {
                        switch (value) {
                            default:
                                value += 1;
                                break;
                        }
                        value += boom(mode);
                    } catch (Exception) {
                        value += 10;
                    }
                    if (mode == 2)
                        return value + 29;
                    return value;
                }

                ref int holder(ref int stored, int mode) {
                    if (mode == 2) {
                        stored = late(mode);
                        return stored;
                    }
                    stored = late(mode);
                    return stored;
                }

                int answer() {
                    int stored;
                    int total = holder(stored, 0);
                    total += holder(stored, 1);
                    total += holder(stored, 2);
                    // late(0) is 1, late(1) is 12 and late(2) is 42.
                    return total == 55 && stored == 42 ? 42 : total;
                }
            },
            "answer",
        );
    }
}
