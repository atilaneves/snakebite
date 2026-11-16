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
