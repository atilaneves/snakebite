module ut.backends.run.jit;


// A function that is called or looped 256 times becomes hot, and the bytecode
// backend then runs it as JIT code. These programs make functions hot in the
// ways that change how a function is entered, and check what compiled D gives.
// A function that the bytecode backend can copy into its caller never has
// events of its own, so a function that the test checks for JIT code has an
// `assert`, which keeps it a call.


import ut.backends;

static foreach (backend; Matrix!()) {
    // An unsigned division keeps its handler, so one function runs JIT code
    // and handlers in turn.
    @("jit.handlersAndJitCodeInOneFunction." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            long twice(long x) { return x * 2; }
            long mixed(long n) {
                assert(n > 0);
                long sum;
                foreach (i; 1 .. n + 1)
                    sum += twice(i) + cast(long) (100UL / i) + (i << 1);
                return sum;
            }
            int main() {
                long expected;
                foreach (i; 1 .. 3001)
                    expected += i * 2 + 100 / i + (i << 1);
                return mixed(3000) == expected ? 0 : 1;
            }
        }, ["mixed"]);
    }

    @("jit.signedDivisionAndRemainder." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            void checkInt(int left, int right) {
                assert(right != 0);
                assert(left / right == -2);
                assert(left % right == -1);
                assert(left / -3 == 2);
                assert(left % -3 == -1);
                int[2] values = [left, right];
                int* value = &values[0];
                *value /= values[1];
                assert(values[0] == -2);
                *value %= *value;
                assert(values[0] == 0 && values[1] == right);
            }
            void checkLong(long left, long right) {
                assert(right != 0);
                const quotient = left / right;
                const remainder = left % right;
                assert(quotient == -(1L << 20) && remainder == -1);
                left %= right;
                assert(left == -1);
            }
            int main() {
                foreach (_; 0 .. 300) {
                    checkInt(-7, 3);
                    checkLong(-((1L << 40) + 1), 1L << 20);
                }
                return 0;
            }
        }, ["checkInt", "checkLong"]);
    }

    @("jit.signedDivisionByConstants." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            enum constants = [1, 2, -2, 3, -7, 10, -10, 256, int.max, int.min];
            void check(int dividend, int[] divisors) {
                static foreach (index, divisor; constants) {
                    assert(dividend / divisor == dividend / divisors[index]);
                    assert(dividend % divisor == dividend % divisors[index]);
                }
            }
            int main() {
                auto divisors = constants.dup;
                foreach (_; 0 .. 40)
                    foreach (dividend; [int.min, int.min + 1, -21, -20, -19,
                            -1, 0, 1, 19, 20, 21, int.max - 1, int.max])
                        check(dividend, divisors);
                return 0;
            }
        }, ["check"]);
    }

    // The loop is the only thing that makes `scan` hot: it is called once.
    @("jit.functionBecomesHotInsideALoop." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            int scan(int[] values) {
                assert(values.length > 0);
                int best = int.min;
                for (size_t i = 0; i < values.length; ++i)
                    if (values[i] > best)
                        best = values[i];
                return best;
            }
            int main() {
                auto values = new int[](5000);
                foreach (i, ref value; values)
                    value = cast(int) ((i * 7919) % 10007);
                return scan(values) == 10006 ? 0 : 1;
            }
        }, ["scan"]);
    }

    @("jit.shortCircuitReadsOnlyTheSelectedFlags." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            struct Flag { bool value; }
            struct Output { int value; }

            void assignIfSelected(const(Flag)* first, const(Flag)* second,
                    const(Flag)* third, Output* output, int value) {
                if (first.value || (!second.value && third.value))
                    output.value = value;
            }

            int main() {
                auto assign = &assignIfSelected;
                Flag yes = Flag(true);
                Flag no = Flag(false);
                foreach (_; 0 .. 300) {
                    Output result;
                    assign(&yes, null, null, &result, 1);
                    assert(result.value == 1);
                    assign(&no, &yes, null, &result, 2);
                    assert(result.value == 1);
                    assign(&no, &no, &yes, &result, 3);
                    assert(result.value == 3);
                    assign(&no, &no, &no, &result, 4);
                    assert(result.value == 3);
                }
                return 0;
            }
        }, ["assignIfSelected"]);
    }

    @("jit.shiftUsesValueFromTheTakenPath." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            int work(int value, int count, bool reset) {
                assert(count > 0);
                if (reset) count = 1;
                const shifted = value >> count;
                const highBits = cast(uint) value >>> 28;
                return shifted + cast(int) highBits + (count << 3);
            }
            int main() {
                foreach (i; 0 .. 300) {
                    if (work(-64, 4, true) != -9) return 1;
                    if (work(-64, 4, false) != 43) return 2;
                }
                return 0;
            }
        }, ["work"]);
    }

    @("jit.mixedArithmeticKeepsValuesAcrossBackedges." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            double packetWeights(int count, int shift, double offset) {
                double sum = 0;
                for (; count > 0; --count)
                    sum += 2.0 * cast(double) (count << shift) + offset;
                return sum;
            }

            double lastReading(long reading, uint count) {
                double last = 0;
                for (uint i = 0; i < count; ++i) {
                    last = cast(double) reading;
                    ++reading;
                }
                return last;
            }

            int main() {
                auto weight = &packetWeights;
                foreach (_; 0 .. 2)
                    assert(weight(512, 1, -1.5) == 524_544.0);
                assert(weight(3, 0, -2.0) == 6.0);
                assert(weight(136, 24, 0) == 235_283_677_184.0);
                assert(weight(0, 1, -1.5) == 0.0);
                auto last = &lastReading;
                foreach (_; 0 .. 2)
                    assert(last(9_007_199_254_740_994, 257) == 9_007_199_254_741_250.0);
                return 0;
            }
        }, ["packetWeights", "lastReading"]);
    }

    @("jit.floatingLiteralsKeepTheirValues." ~ backend.stringof)
    @Tags(is(backend == Bytecode) || is(backend == LoadedBytecode)
        ? [backend.stringof, "requires-jit-code"] : [backend.stringof])
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            int work(double value, float narrow) {
                assert(value != 0.0);
                const quotient = value / -0.0;
                const product = narrow * 0.25f;
                const bool equal = product == 0.75f;
                if (quotient != -double.infinity) return 1;
                if (value < double.nan) return 2;
                return equal ? 0 : 3;
            }
            int main() {
                foreach (i; 0 .. 300) {
                    const status = work(2.0, 3.0f);
                    if (status) return status;
                }
                return 0;
            }
        }, ["work"]);
    }
    @("jit.floatingPointSlotsFollowJumpsAndPointerWrites." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            double update(double a, double b, bool skip) {
                assert(b > 0);
                double* view = &a;
                if (skip)
                    goto second;
                a = a + b;
            second:
                b = a - b;
                a = a + b;
                *view = a * b;
                b = a - b;
                if (b > 8)
                    return a + b;
                return a - b;
            }
            int main() {
                foreach (i; 0 .. 300) {
                    if (update(2, 3, false) != 26)
                        return 1;
                    if (update(2, 3, true) != -1)
                        return 2;
                }
                return 0;
            }
        }, ["update"]);
    }


    @("jit.floatingPointStoresUseTheCurrentAliasedValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            import core.math: sqrt;

            double update(double* first, double* second, double local,
                    bool useLocal, bool skip) {
                assert(first !is null && second !is null);
                if (useLocal)
                    first = &local;

                double value = 1;
                if (skip)
                    goto store;
                value = *first + *second;
                value = sqrt(value * value);
            store:
                value = value + *first;
                *first = value;
                *second = *first + 1;
                return *first + *second + local;
            }

            int main() {
                foreach (i; 0 .. 300) {
                    double first = 2;
                    double second = 3;
                    if (update(&first, &second, 5, false, false) != 20
                            || first != 7 || second != 8)
                        return 1;
                    first = 2;
                    if (update(&first, &first, 5, false, false) != 19
                            || first != 7)
                        return 2;
                    second = 3;
                    if (update(&first, &second, 5, true, false) != 40
                            || first != 7 || second != 14)
                        return 3;
                    first = 2;
                    second = 3;
                    if (update(&first, &second, 5, false, true) != 12
                            || first != 3 || second != 4)
                        return 4;
                }
                return 0;
            }
        }, ["update"]);
    }

    @("jit.floatingPointStoreReadsEarlierPointerWrites." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            void update(double* first, double* second, double* third,
                    double* output) {
                assert(output !is null);
                double value = *first + *second;
                value = value * *third;
                value = value - *second;
                *first = value + *third;
                *output = *first + *second;
            }

            int main() {
                foreach (i; 0 .. 300) {
                    double first = 2;
                    double second = 3;
                    double third = 4;
                    double output = 0;
                    update(&first, &second, &third, &output);
                    if (first != 21 || output != 24)
                        return 1;
                    update(&first, &second, &third, &second);
                    if (first != 97 || second != 100)
                        return 2;
                }
                return 0;
            }
        }, ["update"]);
    }

}

static foreach (backend; Matrix!()) {
    @("jit.floatingPointLoopCanEnterAtTheCounterUpdate." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            int orbit(double realPart, double imaginaryPart, bool skipFirst) {
                // An assert leaves no inline body: `orbit` stays a call.
                assert(realPart < 100);
                double realSquared = 0;
                double imaginarySquared = 0;
                double imaginary = 0;
                int steps = 0;
                bool keepGoing = true;
                int escaped = 0;
                // A jump to the counter update skips the first FP step.
                if (skipFirst)
                    goto count;
                while (keepGoing && steps < 50) {
                    {
                        const realValue = realSquared - imaginarySquared + realPart;
                        imaginary = 2.0 * realValue * imaginary + imaginaryPart;
                        realSquared = realValue * realValue;
                        imaginarySquared = imaginary * imaginary;
                    }
                    if (realSquared + imaginarySquared > 4.0) {
                        keepGoing = false;
                        escaped = 1;
                    }
                count:
                    steps += 1;
                }
                return steps * 2 + escaped;
            }
            int main() {
                foreach (_; 0 .. 12) {
                    if (orbit(0, 0, false) != 100)
                        return 1;
                    if (orbit(1, 0, false) != 7)
                        return 2;
                    if (orbit(0, 2, false) != 5)
                        return 3;
                    if (orbit(1, 0, true) != 9)
                        return 4;
                }
                return 0;
            }
        }, ["orbit"]);
    }
}

static foreach (backend; Matrix!()) {

    @("jit.hotForLoopChecksItsFirstIterationAndContinue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            int countOdd(int first, int end) {
                assert(end <= 5000);
                int count;
                for (int i = first; i < end;) {
                    if ((i & 1) == 0) {
                        ++i;
                        continue;
                    }
                    ++count;
                    ++i;
                }
                return count;
            }
            int main() {
                if (countOdd(-5, 5000) != 2503)
                    return 1;
                if (countOdd(-3, -3) != 0)
                    return 2;
                return countOdd(-3, -2) == 1 ? 0 : 3;
            }
        }, ["countOdd"]);
    }

    @("jit.integerSlotsFollowJumpsAndSignedWidening." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            long scale(int n, int delta, long ceiling, bool skip) {
                assert(delta > 0);
                if (skip)
                    goto convert;
                n += delta;
            convert:
                const long value = n;
                if (value >= ceiling)
                    return value;
                return value * delta;
            }
            int main() {
                foreach (_; 0 .. 300) {
                    if (scale(-5, 4, -3, false) != -1)
                        return 1;
                    if (scale(-5, 4, -3, true) != -20)
                        return 2;
                }
                return 0;
            }
        }, ["scale"]);
    }

    @("jit.pointerFieldComparisonFollowsTheTakenPath." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Buffer {
                size_t length;
                size_t capacity;
            }
            struct Buffers {
                Buffer* replacement;
            }
            bool fits(ref Buffers buffers, Buffer* current, size_t needed,
                bool keepCurrent)
            {
                assert(needed > 0);
                if (keepCurrent)
                    goto compareCapacity;
                current = buffers.replacement;
            compareCapacity:
                if (current.capacity >= needed)
                    return true;
                return false;
            }
            int main() {
                Buffer small = Buffer(2, 3);
                Buffer large = Buffer(4, 8);
                Buffers buffers = Buffers(&large);
                foreach (_; 0 .. 300) {
                    if (!fits(buffers, &small, 8, false))
                        return 1;
                    if (fits(buffers, &small, 8, true))
                        return 2;
                }
                return 0;
            }
        });
    }

    @("jit.pointerCopyUsesBothValuesFromTheTakenPath." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            struct Cell {
                int value;
            }
            struct Pair {
                Cell* dest;
                Cell* source;
            }
            void copy(ref Pair first, ref Pair second, bool keepFirst) {
                assert(first.dest !is null);
                auto dest = first.dest;
                auto source = first.source;
                if (keepFirst)
                    goto assign;
                dest = second.dest;
                source = second.source;
            assign:
                dest.value = source.value;
            }
            int main() {
                Cell a, b;
                Cell x = Cell(5), y = Cell(9);
                Pair first = Pair(&a, &x), second = Pair(&b, &y);
                foreach (_; 0 .. 300) {
                    a.value = b.value = 0;
                    copy(first, second, true);
                    if (a.value != 5 || b.value != 0)
                        return 1;
                    copy(first, second, false);
                    if (a.value != 5 || b.value != 9)
                        return 2;
                }
                return 0;
            }
        }, ["copy"]);
    }

    @("jit.pointerCopyReadsTheFrameAfterAnIndirectStore." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            struct Cell {
                int value;
            }
            struct Pair {
                Cell* dest;
                Cell* source;
            }
            void copy(ref Pair pair, Cell* replacement) {
                assert(replacement !is null);
                Cell* dest;
                auto aliasOfDest = &dest;
                dest = pair.dest;
                auto source = pair.source;
                *aliasOfDest = replacement;
                dest.value = source.value;
            }
            int main() {
                Cell a, b;
                Cell x = Cell(5);
                Pair pair = Pair(&a, &x);
                foreach (_; 0 .. 300) {
                    a.value = b.value = 0;
                    copy(pair, &b);
                    if (a.value != 0 || b.value != 5)
                        return 1;
                }
                return 0;
            }
        }, ["copy"]);
    }

    @("jit.pointerLoopReadsTheCurrentFrame." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            struct Link { Link* next; }

            int walk(Link* left, Link* right, bool enterLate) {
                assert(left !is null);
                if (enterLate)
                    goto advance;
                while (right !is null) {
                    if (left is null)
                        return 1;
                advance:
                    left = left.next;
                    right = right.next;
                }
                return left is null ? 2 : 3;
            }

            int readFromAlias(Link* left) {
                assert(left !is null);
                Link cursor = Link(left);
                auto right = &cursor;
                while (right !is null) {
                    if (cursor.next is null)
                        return 4;
                    cursor.next = cursor.next.next;
                    right = right.next;
                }
                return cursor.next is null ? 5 : 6;
            }

            int writeThroughAlias(Link* left, Link* right, Link* replacement) {
                assert(left !is null);
                auto aliasOfRight = &right;
                while (right !is null) {
                    if (left is null)
                        return 7;
                    left = left.next;
                    *aliasOfRight = replacement;
                    right = right.next;
                }
                return left is null ? 8 : 9;
            }

            int main() {
                Link last, middle = Link(&last), first = Link(&middle);
                foreach (_; 0 .. 300) {
                    assert(walk(&last, &first, false) == 1);
                    assert(walk(&first, &first, false) == 2);
                    assert(walk(&first, null, false) == 3);
                    assert(walk(&first, &middle, true) == 3);
                    assert(readFromAlias(&first) == 5);
                    assert(writeThroughAlias(&first, &first, &last) == 9);
                }
                return 0;
            }
        }, ["walk", "readFromAlias", "writeThroughAlias"]);
    }

    @("jit.pointerLoopTakesTheForwardJumpBeforeRepeating." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            struct Link { Link* next; }

            int visit(Link* cursor) {
                assert(cursor !is null);
            head:
                if (cursor !is null) {
                    cursor = cursor.next;
                    goto check;
                }
                return 1;
            check:
                if (cursor is null)
                    return 2;
                goto head;
            }

            int main() {
                Link last, first = Link(&last);
                foreach (_; 0 .. 300)
                    if (visit(&first) != 2)
                        return 3;
                return 0;
            }
        }, ["visit"]);
    }

    @("jit.loopUpdateUsesTheNewStep." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            int countVisits(int first, int end, int step) {
                assert(end > first);
                int count;
                for (int i = first; i < end; i += ++step)
                    ++count;
                return count;
            }
            int main() {
                foreach (_; 0 .. 300)
                    if (countVisits(1, 7, 0) != 3)
                        return 1;
                return 0;
            }
        }, ["countVisits"]);
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot convert an int address to a ubyte pointer"),
)) {
    @("jit.checkedByteLoopReadsTheUpdatedIndex." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            import core.exception: RangeError;

            enum storeLine = __LINE__ + 9;
            int mark(ubyte[] flags, int first, int last, int step,
                bool aliasIndex)
            {
                assert(flags.length != 0);
                int k = first;
                if (aliasIndex)
                    flags = (cast(ubyte*) &k)[0 .. 1];
                while (k <= last) {
                    flags[k - 1] = 0;
                    k += step;
                }
                return k;
            }

            void verifyFailure(ubyte[] flags, int first, int last, int step,
                string message, ubyte[] expected)
            {
                RangeError caught;
                try
                    mark(flags, first, last, step, false);
                catch (RangeError error)
                    caught = error;
                assert(caught !is null);
                assert(caught.file == __FILE__);
                assert(caught.line == storeLine);
                assert(caught.msg == message);
                assert(flags == expected);
            }

            int main() {
                auto flags = new ubyte[600];
                flags[] = 1;
                if (mark(flags, 1, 600, 2, false) != 601)
                    return 1;
                foreach (i, flag; flags)
                    if (flag != i % 2)
                        return 2;
                if (mark(flags, 601, 600, 1, false) != 601)
                    return 3;
                // The write changes k from 1 to 0 before the add.
                if (mark(flags, 1, 1, 2, true) != 2)
                    return 4;

                flags = [1, 1, 1];
                verifyFailure(flags, 1, 7, 2,
                    "index [4] is out of bounds for array of length 3", [0, 1, 0]);
                flags[] = 1;
                verifyFailure(flags, 4, 4, 0,
                    "index [3] is out of bounds for array of length 3", [1, 1, 1]);
                verifyFailure(flags, 3, 3, -2,
                    "index [18446744073709551614] is out of bounds for array of length 3",
                    [0, 1, 0]);
                flags[] = 1;
                verifyFailure(flags, 1, 1, int.max,
                    "index [2147483647] is out of bounds for array of length 3",
                    [0, 1, 1]);
                return 0;
            }
        }, ["mark"]);
    }
}

private enum sampleLabels = q{
    enum storeLine = __LINE__ + 12;
    int labelSamples(ubyte[] samples, ubyte[] labels, bool resume) {
        enum last = 300;
        int index = last;
        int count = 0;
        if (resume)
            goto sample;
        assert(samples.length != 0);
        for (index = 1; index <= last; ++index) {
        sample:
            if (!samples[index - 1])
                continue;
            labels[index - 1] = 9;
            ++count;
        }
        return count;
    }
};

static foreach (backend; Matrix!()) {
    @("jit.checkedByteLoopKeepsItsEntryState." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, sampleLabels ~ q{
            int main() {
                auto samples = new ubyte[300];
                auto labels = new ubyte[300];
                samples[0] = 2;
                samples[$ - 1] = 3;
                assert(labelSamples(samples, labels, false) == 2);
                assert(labels[0] == 9 && labels[$ - 1] == 9);

                labels[] = 0;
                assert(labelSamples(samples, labels, true) == 1);
                assert(labels[0] == 0 && labels[$ - 1] == 9);

                labels[] = 0;
                assert(labelSamples(samples, labels, false) == 2);
                assert(labels[0] == 9 && labels[1 .. $ - 1] == samples[1 .. $ - 1]);
                assert(labels[$ - 1] == 9);
                return 0;
            }
        }, ["labelSamples"]);
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "an out-of-bounds index is a compile-time error in CTFE"),
)) {
    @("jit.checkedByteLoopKeepsWritesBeforeABoundsError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, sampleLabels ~ q{
            import core.exception: ArrayIndexError;

            int main() {
                auto samples = new ubyte[300];
                auto labels = new ubyte[300];
                samples[0 .. 2] = 1;
                assert(labelSamples(samples, labels, false) == 2);
                labels[] = 0;
                try {
                    labelSamples(samples, labels[0 .. 1], false);
                    return 1;
                } catch (ArrayIndexError error) {
                    assert(error.file == __FILE__);
                    assert(error.line == storeLine);
                    assert(error.index == 1 && error.length == 1);
                    assert(labels[0] == 9 && labels[1] == 0);
                }
                return 0;
            }
        }, ["labelSamples"]);
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot reinterpret overlapped union fields"),
)) {
    @("jit.floatingPointSlotsFollowPartialAndAdjacentWrites." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            union Pair {
                double wide;
                struct { float low; float high; }
            }
            struct Values {
                Pair pair;
                double next;
            }
            float update(double x, float y, bool overlap) {
                assert(y > 0);
                Values values = void;
                double* view = overlap ? &values.pair.wide : &values.next;
                values.pair.high = y + y;
                *view = x * x;
                return values.pair.high * y;
            }
            int main() {
                version (LittleEndian)
                    enum partialProduct = 4.5f;
                else
                    enum partialProduct = 0.0f;
                foreach (i; 0 .. 300) {
                    if (update(2, 2, true) != partialProduct)
                        return 1;
                    if (update(2, 2, false) != 8.0f)
                        return 2;
                }
                return 0;
            }
        }, ["update"]);
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot access class destructors through TypeInfo"),
)) {
    // The destructor runs in a GC finalizer, which must not allocate, and
    // its recursive calls and loop make `work` hot there. A function that
    // gets hot in a finalizer keeps its handlers until a later event.
    @("jit.functionBecomesHotInAFinalizer." ~ backend.stringof)
    @Tags(backend.stringof, "forced-finalizers")
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.memory: GC;
            void work(long* result, uint depth, int n) {
                if (depth != 0) {
                    work(result, depth - 1, n);
                    return;
                }
                long sum;
                foreach (i; 0 .. n)
                    sum += i & 7;
                *result = sum;
            }
            class Resource {
                long* result;
                this(long* result) { this.result = result; }
                ~this() { work(result, 4, 5000); }
            }
            void main() {
                long result;
                // Prepare the recursive call before the finalizer can use it.
                work(&result, 4, 0);
                auto resource = new Resource(&result);
                const address = cast(const void*) typeid(Resource).destructor;
                GC.runFinalizers(address[0 .. 1]);
                assert(result == 5000 / 8 * 28);
                result = 0;
                work(&result, 4, 5000);
                assert(result == 5000 / 8 * 28);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE has no threads"),
)) {
    @("jit.severalThreadsMakeTheSameFunctionHot." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            import core.thread: Thread;
            long work(long n) {
                assert(n > 0);
                long sum;
                foreach (i; 0 .. n)
                    sum += i % 5;
                return sum;
            }
            __gshared long[4] results;
            void delegate() run(int index) {
                return {
                    foreach (round; 0 .. 20)
                        results[index] += work(600);
                };
            }
            void main() {
                Thread[4] threads;
                foreach (t; 0 .. 4) {
                    threads[t] = new Thread(run(t));
                    threads[t].start;
                }
                foreach (thread; threads)
                    thread.join;
                foreach (result; results)
                    assert(result == 20 * 600 / 5 * 10);
            }
        }, ["work"]);
    }
}

static foreach (backend; Matrix!()) {
    // A backend that is gone gives back its JIT code region. Many backends
    // that one after the other make a function hot must not keep a code
    // file open each.
    @("jit.backendsThatAreGoneDoNotKeepTheirCodeFiles." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        import core.memory: GC;

        enum backends = 200;
        const before = openJitFiles;
        foreach (_; 0 .. backends) {
            0.shouldBeStatusOf!(backend, q{
                long work(long n) {
                    assert(n > 0);
                    long sum;
                    foreach (i; 0 .. n)
                        sum += i % 5;
                    return sum;
                }
                int main() {
                    return work(5000) == 5000 / 5 * 10 ? 0 : 1;
                }
            });
        }
        GC.collect;
        (openJitFiles - before).shouldBeSmallerThan(backends / 2);
    }
}

private enum recursiveVisits = q{
    final class Search {
        int[1] visits;
        int[] updates;

        void walk(uint depth, size_t index) {
            visits[0] += 1;
            if (depth == 0)
                return;
            walk(depth - 1, index);
            updates[index] = visits[0] + 10;
            walk(depth - 1, index);
        }
    }

    void warmUp(Search search) {
        foreach (_; 0 .. 350) {
            search.visits[0] = 0;
            search.walk(3, 0);
            assert(search.visits[0] == 15);
            assert(search.updates[0] == 24);
        }
    }
};

static foreach (backend; Matrix!()) {
    @("jit.recursiveCallsObserveAnAliasedStore." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, recursiveVisits ~ q{
            void cold(int* visits, uint depth) {
                ++*visits;
                if (depth != 0)
                    cold(visits, depth - 1);
            }

            int main() {
                int coldVisits;
                cold(&coldVisits, 5);
                assert(coldVisits == 6);

                auto search = new Search;
                int[1] separate;
                search.updates = separate[];
                warmUp(search);

                search.updates = search.visits[];
                search.visits[0] = 0;
                search.walk(3, 0);
                assert(search.visits[0] == 85);

                search.updates = separate[];
                search.visits[0] = 0;
                search.walk(4, 0);
                assert(search.visits[0] == 31);
                assert(separate[0] == 40);
                return 0;
            }
        }, ["walk"]);
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "an out-of-bounds index is a compile-time error in CTFE"),
)) {
    @("jit.recursiveBoundsFailureKeepsEarlierEffects." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, recursiveVisits ~ q{
            import core.exception: ArrayIndexError;

            int main() {
                auto search = new Search;
                int[1] separate;
                search.updates = separate[];
                warmUp(search);
                search.visits[0] = 0;
                try {
                    search.walk(3, 5);
                    return 1;
                } catch (ArrayIndexError error) {
                    assert(error.index == 5 && error.length == 1);
                    assert(search.visits[0] == 4);
                    assert(separate[0] == 24);
                }

                search.visits[0] = 0;
                search.walk(2, 0);
                assert(search.visits[0] == 7);
                assert(separate[0] == 16);
                return 0;
            }
        }, ["walk"]);
    }
}


// The number of JIT code files that this process has open.
private long openJitFiles() {
    import std.algorithm: canFind;
    import std.file: dirEntries, FileException, readLink, SpanMode;

    long count;
    foreach (entry; dirEntries("/proc/self/fd", SpanMode.shallow)) {
        try {
            if (readLink(entry.name).canFind("snakebite-jit"))
                ++count;
        } catch (FileException) {
            // The descriptor of the directory listing itself can be gone.
        }
    }
    return count;
}

private enum checkedLoadPair = q{
    int readPair(I, T)(T[] values, I i, I j, bool skipFirst) {
        assert(values.length == 3);
        T first = 9;
        if (skipFirst)
            goto second;
        first = values[i - 1];
    second:
        T last = values[j - 1];
        return first * 10 + last;
    }
};

static foreach (backend; Matrix!()) {
    @("jit.checkedLoadsFollowTheirEntryPath." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, checkedLoadPair ~ q{
            int main() {
                int[] ints = [1, 2, 3];
                ushort[] shorts = [1, 2, 3];
                foreach (_; 0 .. 300) {
                    assert(readPair(ints, 3, 3, false) == 33);
                    assert(readPair(ints, 1, 3, false) == 13);
                    assert(readPair(ints, 3, 2, true) == 92);
                    assert(readPair(shorts, 2U, 2U, false) == 22);
                    assert(readPair(shorts, 1UL, 3UL, false) == 13);
                }
                return 0;
            }
        }, ["readPair"]);
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "an out-of-bounds index is a compile-time error in CTFE"),
)) {
    @("jit.checkedLoadsCheckSecondIndexOnBothEntries." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, checkedLoadPair ~ q{
            import core.exception: ArrayIndexError;

            int main() {
                int[] values = [1, 2, 3];
                foreach (_; 0 .. 300)
                    assert(readPair(values, 3, 3, false) == 33);
                foreach (skipFirst; [false, true]) {
                    const first = skipFirst ? 0 : 3;
                    try {
                        readPair(values, first, 5, skipFirst);
                        return 1;
                    } catch (ArrayIndexError error) {
                        assert(error.index == 4 && error.length == 3);
                    }
                }
                return 0;
            }
        }, ["readPair"]);
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot reinterpret a uint array as a byte pointer"),
)) {
    @("jit.checkedLoadsObserveOverlappingWrites." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            uint loadOverlap(int index, uint seed) {
                assert(index == 0);
                uint[2] bytes = [seed, seed];
                auto data = (cast(ubyte*) bytes.ptr)[0 .. bytes.sizeof];
                auto shifted = (cast(uint*) (data.ptr + 1))[0 .. 1];
                bytes[0] = shifted[index];
                uint observed = shifted[index];
                assert(observed == *cast(uint*) (data.ptr + 1));
                return observed;
            }

            int main() {
                foreach (_; 0 .. 300)
                    assert(loadOverlap(0, 0x32107654) == 0x54543210);
                return 0;
            }
        }, ["loadOverlap"]);
    }
}

static foreach (backend; Matrix!()) {
    @("jit.byteBranchesPreserveValuesOnEachEntry." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            int byteBranches(ubyte[] values, int index, int entry, ubyte saved) {
                assert(values.length != 0);
                ubyte first = saved;
                ubyte second = 73;
                ubyte third = saved;
                if (entry == 1)
                    goto copy;
                if (entry == 2)
                    goto test;
                first = values[index];
                if (!first)
                    return first;
            copy:
                second = first;
                third = second;
            test:
                if (!third)
                    return 256 + second;
                if (first)
                    return 256 * first + third;
                return third;
            }

            int main() {
                ubyte[] values = [0, 2, 255];
                foreach (_; 0 .. 300) {
                    assert(byteBranches(values, 0, 0, 73) == 0);
                    assert(byteBranches(values, 1, 0, 73) == 0x0202);
                    assert(byteBranches(values, 2, 0, 73) == 0xFFFF);
                    assert(byteBranches(values, 3, 1, 0) == 256);
                    assert(byteBranches(values, 3, 2, 0) == 329);
                    assert(byteBranches(values, 3, 1, 255) == 0xFFFF);
                    assert(byteBranches(values, 3, 2, 2) == 0x0202);
                }
                return 0;
            }
        }, ["byteBranches"]);
    }
}

static foreach (backend; Matrix!()) {
    @("jit.byteBranchCanEnterAfterTheLoad." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            int readByte(ubyte[] values, size_t index, bool skip, ubyte value) {
                assert(values.length != 0);
                if (skip)
                    goto test;
                value = values[index];
            test:
                if (value)
                    return 256 + value;
                return 17;
            }

            int main() {
                ubyte[] values = [0, 2, 255];
                foreach (_; 0 .. 300) {
                    assert(readByte(values, 0, false, 2) == 17);
                    assert(readByte(values, 1, false, 0) == 258);
                    assert(readByte(values, 2, false, 0) == 511);
                    assert(readByte(values, 3, true, 2) == 258);
                    assert(readByte(values, 3, true, 0) == 17);
                }
                return 0;
            }
        }, ["readByte"]);
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot slice a pointer to a scalar or catch a bounds failure"),
)) {
    @("jit.byteBranchesKeepAliasedReadsAndBoundsChecks." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            import core.exception: ArrayIndexError;

            int aliasedByteBranches(int index, ubyte first, ubyte second,
                    bool aliasesFirst) {
                auto values = aliasesFirst
                    ? (&first)[0 .. 1] : (&second)[0 .. 1];
                assert(values.length != 0);
                first = values[index];
                if (!first)
                    return second;
                second = first;
                if (second)
                    return second;
                return -1;
            }

            int main() {
                foreach (_; 0 .. 300) {
                    assert(aliasedByteBranches(0, 255, 2, true) == 255);
                    assert(aliasedByteBranches(0, 255, 2, false) == 2);
                    assert(aliasedByteBranches(0, 0, 2, true) == 2);
                    assert(aliasedByteBranches(0, 255, 0, false) == 0);
                }
                foreach (aliasesFirst; [false, true]) {
                    try {
                        aliasedByteBranches(1, 255, 2, aliasesFirst);
                        return 1;
                    } catch (ArrayIndexError error) {
                        assert(error.index == 1 && error.length == 1);
                    }
                }
                return 0;
            }
        }, ["aliasedByteBranches"]);
    }
}

private enum permutationVisits = q{
    // A mutable value with a fixed address can change between calls.
    private __gshared int mutableIndex;

    final class Walker {
        int[8] state;
        int[] cells;

        void visit(bool useMutableIndex = false)(int depth) {
            ++state[0];
            if (depth == 0)
                return;
            const next = depth - 1;
            visit!useMutableIndex(next);
            for (int i = next; i >= 0; --i) {
                exchange(useMutableIndex ? mutableIndex : next, i);
                visit!useMutableIndex(next);
                exchange(useMutableIndex ? mutableIndex : next, i);
            }
        }

        private void exchange(int i, int j) {
            const value = cells[i];
            cells[i] = cells[j];
            cells[j] = value;
        }
    }

    const original = [13, 21, 34, 55, 89, 144];
};

static foreach (backend; Matrix!()) {
    @("jit.permutationLoopUsesCurrentStorage." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, permutationVisits ~ q{
            int main() {
                auto walker = new Walker;
                walker.cells = original.dup;
                foreach (_; 0 .. 10) {
                    walker.state[0] = 0;
                    walker.visit(6);
                    assert(walker.state[0] == 8660);
                    assert(walker.cells == original);
                }

                walker.state[0 .. original.length] = original[];
                walker.cells = walker.state[0 .. original.length];
                walker.visit(3);
                assert(walker.state[] == [35, 30, 44, 55, 89, 144, 0, 0]);

                int[6] cells;
                cells[] = original[];
                walker.cells = cells[];
                walker.state[0] = 0;
                walker.visit(0);
                assert(walker.state[0] == 1 && cells[] == original);
                walker.state[0] = 0;
                walker.visit(3);
                assert(walker.state[0] == 41 && cells[] == original);
                return 0;
            }
        }, ["visit"]);
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot write a mutable static variable"),
)) {
    @("jit.permutationLoopReadsTheCurrentIndex." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, permutationVisits ~ q{
            import core.exception: ArrayIndexError;

            int main() {
                auto walker = new Walker;
                walker.cells = original.dup;
                mutableIndex = 0;
                foreach (_; 0 .. 10) {
                    walker.state[0] = 0;
                    walker.visit!true(6);
                    assert(walker.state[0] == 8660);
                    assert(walker.cells == original);
                }

                mutableIndex = 5;
                walker.state[0] = 0;
                walker.visit!true(3);
                assert(walker.state[0] == 41 && walker.cells == original);

                mutableIndex = -1;
                walker.state[0] = 0;
                try {
                    walker.visit!true(3);
                    return 1;
                } catch (ArrayIndexError error) {
                    assert(error.index == size_t.max
                        && error.length == original.length);
                    assert(walker.state[0] == 4);
                }
                return 0;
            }
        }, ["visit"]);
    }
}

static foreach (backend; Matrix!()) {
    @("jit.indexedFieldUpdatesUseTheCurrentElement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            struct Cell {
                int x;
                int y;
                int dx;
                int dy;
            }

            int scan(bool maySkip)(Cell[] cells, size_t start, bool skip) {
                int adjustedCount;
                foreach (ref cell; cells[start .. $]) {
                    bool adjusted = false;
                    static if (maySkip) {
                        if (skip) {
                            skip = false;
                            goto updateY;
                        }
                    }
                    cell.x += cell.dx;
                updateY:
                    cell.y += cell.dy;
                    if (cell.x < 0) {
                        cell.x = 0;
                        adjusted = true;
                    }
                    if (cell.y > 10) {
                        cell.y = 10;
                        adjusted = true;
                    }
                    if (adjusted)
                        ++adjustedCount;
                }
                return adjustedCount;
            }

            int main() {
                enum initial = [Cell(2, 8, 3, 3), Cell(1, 1, -3, 2),
                    Cell(2, 6, 4, 1)];
                foreach (round; 0 .. 300) {
                    Cell[3] cells = initial;
                    assert(scan!false(cells[], 0, false) == 2);
                    assert(cells == [Cell(5, 10, 3, 3), Cell(0, 3, -3, 2),
                        Cell(6, 7, 4, 1)]);

                    cells = initial;
                    assert(scan!true(cells[], 1, true) == 0);
                    assert(cells == [Cell(2, 8, 3, 3), Cell(1, 3, -3, 2),
                        Cell(6, 7, 4, 1)]);
                }
                return 0;
            }
        }, ["scan"]);
    }
}

// Entering at the second update skips the first store. A branch after the
// updates can read any field through the same aggregate or an overlapping field.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE rejects a read of an overlapping field"),
)) {
    @("jit.fieldBranchesSeeCurrentValuesOnEachEntry." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            struct Record {
                int marker;
                int net;
                union {
                    int code;
                    int codeAlias;
                }
                int distance;
                int adjustment;
                int mask;
            }

            void update(ref Record record, bool skipNet) {
                assert(record.marker == 23);
                if (skipNet)
                    goto updateCode;
                record.net = record.net - record.adjustment;
            updateCode:
                record.code = record.code ^ record.mask;
                record.distance = record.distance + record.adjustment;
                if (record.codeAlias != 7) {
                    record.marker = -3;
                    return;
                }
                if (record.distance > 11) {
                    record.marker = 19;
                    return;
                }
                if (record.codeAlias == record.distance)
                    record.marker = 31;
            }

            int main() {
                foreach (round; 0 .. 300) {
                    Record record;
                    record.marker = 23;
                    record.net = 16;
                    record.code = round % 3 == 0 ? 6 : 5;
                    record.distance = round % 3 == 1 ? 8 : 3;
                    record.adjustment = 4;
                    record.mask = 2;
                    const skipNet = round % 2 == 0;
                    update(record, skipNet);
                    assert(record.net == (skipNet ? 16 : 12));
                    assert(record.marker == [-3, 19, 31][round % 3]);
                    assert(record.code == (round % 3 == 0 ? 4 : 7));
                    assert(record.distance == (round % 3 == 1 ? 12 : 7));
                }
                return 0;
            }
        }, ["update"]);
    }
}

// A field store can change the pointer used for the next field access.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE rejects the cast of the pointer slot"),
)) {
    @("jit.fieldBranchesFollowAStoreThatChangesTheirReceiver." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            struct Cell {
                int first;
                int second;
            }

            align(16) struct Storage {
                Cell* cursor;
                Cell data;
            }

            int advance(int seed) {
                Storage storage;
                storage.data = Cell(11, seed);
                storage.cursor = cast(Cell*) &storage.cursor;

                // Alignment keeps this change in the low word of the pointer.
                storage.cursor.first += cast(int) Storage.data.offsetof;
                storage.cursor.second += 2;
                if (storage.cursor.second < 0)
                    return 1;
                if (storage.cursor.first > 30)
                    return 2;
                if (storage.cursor.second == 22)
                    storage.data.first = 19;
                assert(storage.cursor is &storage.data);
                return storage.data == Cell(19, 22) ? 0 : 3;
            }

            int main() {
                foreach (round; 0 .. 300)
                    assert(advance(20) == 0);
                return 0;
            }
        }, ["advance"]);
    }
}

// A fixed-length slice still aliases its source, and an empty slice
// can point one element past the source.
static foreach (backend; Matrix!()) {
    @("jit.fixedSliceKeepsStorageAndEvaluationOrder." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            struct Three {
                ubyte[3] payload;
            }

            final class Cursor {
                size_t index;

                ubyte[] takeFixed(ubyte[] input) {
                    assert(input.length > 0);
                    return input[index .. index + 1];
                }
            }

            void checkSpans(size_t index, ushort[] words, uint[] ints,
                    ulong[] longs, Three[] triples) {
                auto s = words[index .. index + 3];
                assert(s.ptr is words.ptr + index && s.length == 3);
                s[1] = 51;
                assert(words[index + 1] == 51);

                const t = ints[index .. index + 3];
                assert(t.ptr is ints.ptr + index && t.length == 3);
                const u = longs[index .. index + 3];
                assert(u.ptr is longs.ptr + index && u.length == 3);
                const v = triples[index .. index + 3];
                assert(v.ptr is triples.ptr + index && v.length == 3);

                size_t end = words.length;
                auto empty = words[end .. end];
                assert(empty.length == 0 && empty.ptr is words.ptr + end);
            }

            int main() {
                auto cursor = new Cursor;
                ubyte[] bytes = [1, 2, 3, 4, 5];
                ushort[] words = [1, 2, 3, 4, 5];
                uint[] ints = [1, 2, 3, 4, 5];
                ulong[] longs = [1, 2, 3, 4, 5];
                auto triples = new Three[5];

                foreach (iteration; 0 .. 300) {
                    size_t index = 1 + iteration % 2;
                    cursor.index = index;
                    auto one = cursor.takeFixed(bytes);
                    assert(one.ptr is bytes.ptr + index && one.length == 1);
                    checkSpans(index, words, ints, longs, triples);
                }

                size_t index;
                ubyte[] source() {
                    index = 1;
                    return bytes;
                }
                const fromSource = source()[index .. index + 3];
                assert(fromSource.ptr is bytes.ptr + 1 && fromSource.length == 3);

                size_t nextBound() {
                    ++index;
                    return index;
                }
                const fromBounds = bytes[nextBound() .. index + 1];
                assert(fromBounds.ptr is bytes.ptr + 2 && fromBounds.length == 1);
                assert(fromBounds[0] == 3);

                shared size_t sharedIndex;
                sharedIndex = 1;
                const fromShared = bytes[sharedIndex .. sharedIndex + 2];
                assert(fromShared.ptr is bytes.ptr + 1 && fromShared.length == 2);
                return 0;
            }
        }, ["checkSpans", "takeFixed"]);
    }
}

// ArraySliceError reports the actual unsigned bound after addition wraps.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd CTFE reports an out-of-bounds slice as a compile-time error"),
)) {
    @("jit.fixedSliceReportsWrappedAndOutOfBoundsArguments." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            import core.exception: ArraySliceError;

            bool spanIsValid(int[] values, size_t lower, size_t expectedUpper,
                    bool oneElement) {
                size_t line;
                try {
                    if (oneElement) {
                        line = __LINE__ + 1;
                        auto result = values[lower .. lower + 1];
                        assert(result.length == 1);
                    } else {
                        line = __LINE__ + 1;
                        auto result = values[lower .. lower + 3];
                        assert(result.length == 3);
                    }
                    return true;
                } catch (ArraySliceError error) {
                    assert(error.file == __FILE__ && error.line == line);
                    assert(error.lower == lower && error.upper == expectedUpper);
                    assert(error.length == values.length);
                    return false;
                }
            }

            int main() {
                int[] values = [1, 2, 3, 4, 5];
                foreach (_; 0 .. 300) {
                    assert(spanIsValid(values, 4, 5, true));
                    assert(spanIsValid(values, 2, 5, false));
                }
                assert(!spanIsValid(values, 5, 6, true));
                assert(!spanIsValid(values, 3, 6, false));
                assert(!spanIsValid(values, size_t.max, 0, true));
                assert(!spanIsValid(values, size_t.max, 2, false));
                return 0;
            }
        }, ["spanIsValid"]);
    }
}
