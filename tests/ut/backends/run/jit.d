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

}

static foreach (backend; Matrix!(
    Omit!(LoadedBytecode, Because.unconfirmed,
        "after a load, `orbit` gets no JIT code; from RAM it does (#1006)"),
)) {
    @("jit.floatingPointLoopCanEnterAtTheCounterUpdate." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            int orbit(double realPart, double imaginaryPart, bool skipFirst) {
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
            int mark(ubyte[] flags, int first, int last, int step,
                bool aliasIndex)
            {
                assert(step != 0);
                int k = first;
                if (aliasIndex)
                    flags = (cast(ubyte*) &k)[0 .. 1];
                while (k <= last) {
                    flags[k - 1] = 0;
                    k += step;
                }
                return k;
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
                return mark(flags, 1, 1, 2, true) == 2 ? 0 : 4;
            }
        }, ["mark"]);
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
            void work(long* result, uint depth) {
                if (depth != 0) {
                    work(result, depth - 1);
                    return;
                }
                long sum;
                foreach (i; 0 .. 5000)
                    sum += i & 7;
                *result = sum;
            }
            class Resource {
                long* result;
                this(long* result) { this.result = result; }
                ~this() { work(result, 4); }
            }
            void main() {
                long result;
                auto resource = new Resource(&result);
                const address = cast(const void*) typeid(Resource).destructor;
                GC.runFinalizers(address[0 .. 1]);
                assert(result == 5000 / 8 * 28);
                result = 0;
                work(&result, 4);
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
