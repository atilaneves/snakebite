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
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot access class destructors through TypeInfo"),
)) {
    // The destructor runs in a GC finalizer, which must not allocate, and
    // its loop makes `work` hot there. A function that gets hot in a finalizer
    // keeps its handlers until a later event, so there is no JIT code to see.
    @("jit.functionBecomesHotInAFinalizer." ~ backend.stringof)
    @Tags(backend.stringof, "forced-finalizers")
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.memory: GC;
            long work(long n) {
                long sum;
                foreach (i; 0 .. n)
                    sum += i & 7;
                return sum;
            }
            class Resource {
                long* result;
                this(long* result) { this.result = result; }
                ~this() { *result = work(5000); }
            }
            void main() {
                long result;
                auto resource = new Resource(&result);
                const address = cast(const void*) typeid(Resource).destructor;
                GC.runFinalizers(address[0 .. 1]);
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
