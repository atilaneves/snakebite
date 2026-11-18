module ut.backends.call.windowtierup;


import ut.backends;


// Repeated calls keep argument evaluation order and the caller's result
// storage. Each recursive exit runs its scope guard, including on a throw.
static foreach (backend; Matrix!()) {
    @("window.hotCallsKeepArgumentsAndUnwind." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            long digit(long* next, long value) {
                assert(*next == value);
                ++*next;
                return value;
            }

            long digits(long a, long b, long* result, long* cleaned,
                int depth, bool fail) {
                scope(exit) ++*cleaned;
                if (depth != 0)
                    return digits(a, b, result, cleaned, depth - 1, fail);
                if (fail)
                    throw new Exception("digits");
                return *result + 10 * a + b;
            }

            void sumTo(long* result, int depth) {
                if (depth == 0) {
                    *result = 0;
                    return;
                }
                sumTo(result, depth - 1);
                *result += depth;
            }

            void main() {
                // The JIT can defer compilation if another thread holds its lock.
                enum rounds = 1024;
                long cleaned;
                foreach (round; 0 .. rounds) {
                    long next = 4;
                    long sum;
                    sumTo(&sum, 3);
                    assert(sum == 6);

                    long[2] results = [round, round + 1];
                    const index = round % results.length;
                    const before = results[index];
                    const fail = round == rounds - 1;
                    try {
                        results[index] = digits(digit(&next, 4), digit(&next, 5),
                            &results[index], &cleaned, 2, fail);
                        assert(!fail && results[index] == before + 45);
                    } catch (Exception thrown) {
                        assert(fail && thrown.msg == "digits");
                        assert(results[index] == before);
                    }
                    assert(next == 6 && cleaned == 3 * (round + 1));
                }
            }
        }, ["main", "digits", "sumTo"]);
    }
}


static foreach (backend; Matrix!()) {
    @("window.hotDelegateCallsUseCurrentTargetAndReceiver." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            interface Addition { long add(long value); }
            interface Subtraction { long subtract(long value); }
            interface Tag { void tag(); }

            class Add : Addition {
                long offset;
                this(long offset) { this.offset = offset; }
                override long add(long value) { return value + offset; }
            }

            class Subtract : Tag, Subtraction {
                long offset;
                this(long offset) { this.offset = offset; }
                override long subtract(long value) { return value - offset; }
                override void tag() {}
            }

            class Multiply {
                long factor;
                this(long factor) { this.factor = factor; }
                long multiply(long value) { return value * factor; }
            }

            class Mask {
                long mask(long value) {
                    long[1024] storage = void;
                    const index = cast(size_t) value % storage.length;
                    storage[index] = value ^ 7;
                    return storage[index];
                }
            }

            class Negate {
                long negate(long value) { return -value; }
            }

            long invoke(long delegate(long) operation, long value) {
                return operation(value);
            }

            void main() {
                Addition first = new Add(17);
                Addition second = new Add(29);
                Subtraction third = new Subtract(41);
                auto fourth = new Multiply(5);
                auto fifth = new Mask;
                auto sixth = new Negate;
                auto operations = [
                    &first.add, &second.add, &third.subtract,
                    &fourth.multiply, &fifth.mask, &sixth.negate,
                ];
                // The pointer call lets invoke tier up even if the direct
                // call is inlined into main.
                auto indirectInvoke = &invoke;
                foreach (round; 0 .. 1024L) {
                    assert(invoke(operations[0], round) == round + 17);
                    assert(indirectInvoke(operations[0], round) == round + 17);
                }

                // The later calls add targets, change the current receiver,
                // and exceed the number of targets the call can remember.
                foreach (round; 0 .. 3072L) {
                    const index = round % operations.length;
                    long[6] expected = [
                        round + 17, round + 29, round - 41,
                        round * 5, round ^ 7, -round,
                    ];
                    assert(invoke(operations[index], round) == expected[index]);
                    assert(indirectInvoke(operations[index], round) == expected[index]);
                }
            }
        }, ["main", "invoke", "add", "subtract", "multiply", "mask"]);
    }
}


// An index failure must use the callee's error location and keep a field
// write that happened before the check.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns an out-of-range index into a compile-time error"),
)) {
    @("window.hotFieldTransferKeepsCommittedWritesOnExit." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            import core.exception: RangeError;

            class Box { int value; }

            interface Transfer {
                int apply(Box first, Box second, bool forward,
                    int[] values, size_t index) @safe;
            }

            class Increment : Transfer {
                static size_t indexLine;

                override int apply(Box first, Box second, bool forward,
                    int[] values, size_t index) @safe
                {
                    if (forward)
                        second.value = first.value + 1;
                    else
                        first.value = second.value + 2;
                    indexLine = __LINE__ + 1;
                    return values[index];
                }
            }

            class Replace : Transfer {
                override int apply(Box first, Box second, bool forward,
                    int[] values, size_t index) @safe
                {
                    first.value = 30;
                    return values[index] + 1;
                }
            }

            int transfer(Transfer operation, Box first, Box second,
                bool forward, int[] values, size_t index)
            {
                return operation.apply(first, second, forward, values, index)
                    + 10;
            }

            void main() {
                Transfer increment = new Increment;
                Transfer replace = new Replace;
                auto first = new Box;
                auto second = new Box;
                int[1] values = [11];
                foreach (round; 0 .. 1024) {
                    first.value = 3;
                    second.value = 7;
                    assert(transfer(increment, first, second, true, values[], 0)
                        == 21);
                    assert(first.value == 3 && second.value == 4);
                    assert(transfer(increment, first, second, false, values[], 0)
                        == 21);
                    assert(first.value == 6 && second.value == 4);
                }
                assert(transfer(replace, first, second, true, values[], 0) == 22);
                assert(first.value == 30 && second.value == 4);
                bool caught;
                try {
                    cast(void) transfer(increment, first, first, false,
                        values[], values.length);
                } catch (RangeError error) {
                    caught = error.line == Increment.indexLine;
                }
                assert(caught && first.value == 32);
            }
        }, ["transfer"]);
    }
}


// A checked search can call delegates with the same context and different
// function bodies. The second function sees the current capture.
static foreach (backend; Matrix!()) {
    @("window.hotSearchKeepsCaptureAndResidualCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            bool contains(int[] values, bool delegate(int) predicate) {
                foreach (i; 0 .. values.length)
                    if (predicate(values[i]))
                        return true;
                return false;
            }

            bool search(int[] values, bool delegate(int) predicate) {
                return contains(values, predicate);
            }

            void main() {
                int[4] values = [2, 4, 7, 8];
                int key;
                int checks;
                bool match(int value) {
                    ++checks;
                    return value == key;
                }
                bool greater(int value) {
                    ++checks;
                    return value > key;
                }

                auto callSearch = &search;
                foreach (round; 0 .. 320) {
                    key = values[0];
                    checks = 0;
                    assert(callSearch(values[], &match));
                    assert(checks == 1);
                }

                foreach (round; 0 .. 1024) {
                    key = round % 2 == 0 ? 7 : 9;
                    checks = 0;
                    assert(callSearch(values[], &match) == (key == 7));
                    assert(checks == (key == 7 ? 3 : 4));
                }
                key = 4;
                checks = 0;
                assert(callSearch(values[], &greater));
                assert(checks == 3);
            }
        }, ["search", "contains"]);
    }
}


static foreach (backend; Matrix!()) {
    @("window.hotVoidRelayKeepsReceiverAndSample." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOfWithJitCode!(backend, q{
            abstract class Meter {
                int total;
                abstract void record(int sample);
            }

            final class Sum : Meter {
                override void record(int sample) { total += sample; }
            }

            final class Count : Meter {
                override void record(int sample) { ++total; }
            }

            final class Peak : Meter {
                int samples;

                override void record(int sample) {
                    ++samples;
                    if (sample > total)
                        total = sample;
                }
            }

            alias Observer = void function(Meter, int);
            void ignore(Meter meter, int sample) {}
            void relay(Meter meter, int sample) { meter.record(sample); }
            void notify(Observer observer, Meter meter, int sample) {
                observer(meter, sample);
            }

            void main() {
                auto sum = new Sum;
                auto count = new Count;
                auto peak = new Peak;
                auto send = &notify;
                auto train = &relay;

                enum training = 1024;
                foreach (_; 0 .. training) {
                    send(&ignore, sum, 3);
                    train(count, 3);
                    train(sum, 3);
                }

                // Both receivers go through the same call site. Peak only
                // enters it after the relay has run with the trained receiver.
                enum common = 24_000;
                enum residual = 80_000;
                foreach (i; 0 .. common + residual) {
                    Meter meter = i < common ? cast(Meter) sum : peak;
                    send(&relay, meter, i < common ? 3 : i - common);
                }

                assert(sum.total == 3 * (training + common));
                assert(count.total == training);
                assert(peak.total == residual - 1);
                assert(peak.samples == residual);
            }
        }, ["notify", "relay"]);
    }
}
