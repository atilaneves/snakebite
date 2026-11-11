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
            interface Operation {
                long evaluate(long value);
            }

            class Add : Operation {
                long offset;
                this(long offset) { this.offset = offset; }
                override long evaluate(long value) { return value + offset; }
            }

            class Subtract : Operation {
                long offset;
                this(long offset) { this.offset = offset; }
                override long evaluate(long value) { return value - offset; }
            }

            void main() {
                Operation first = new Add(17);
                Operation second = new Add(29);
                Operation third = new Subtract(41);
                auto addFirst = &first.evaluate;
                auto addSecond = &second.evaluate;
                auto subtract = &third.evaluate;
                foreach (round; 0 .. 1024) {
                    auto operation = addFirst;
                    long offset = 17;
                    if (round % 3 == 1) {
                        operation = addSecond;
                        offset = 29;
                    } else if (round % 3 == 2) {
                        operation = subtract;
                        offset = -41;
                    }
                    assert(operation(round) == round + offset);
                }
            }
        }, ["main"]);
    }
}
