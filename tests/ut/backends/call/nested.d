module ut.backends.call.nested;


import ut.backends;


// The non-escaping case: `bump` is called while `main`'s own frame is
// still on the interpreter's frame stack, so reading and then writing
// `counter` through the static chain reaches the same storage a compiled
// `bump` would.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
)) {
    @("nested.staticChain.readsAndWritesOuterLocal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int counter = 40;
                int bump() {
                    counter += 2;
                    return counter;
                }

                assert(bump() == 42);
                assert(counter == 42);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("nested.recursiveGuestCall.countsDown." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(
            backend,
            q{
                int countdown(int n) {
                    if (n == 0)
                        return 0;
                    return countdown(n - 1) + 1;
                }

                int main() {
                    return countdown(42) == 42 ? 0 : 1;
                }
            },
        );
    }
}

static foreach (backend; Matrix!()) {
    @("nested.recursiveGuestCall.factorial." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(
            backend,
            q{
                int factorial(int n) {
                    if (n <= 1)
                        return 1;
                    return n * factorial(n - 1);
                }

                int main() {
                    return factorial(6) == 720 ? 0 : 1;
                }
            },
        );
    }
}

static foreach (backend; Matrix!()) {
    @("nested.mutualGuestCall.evenOdd." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(
            backend,
            q{
                int odd(int n);

                int even(int n) {
                    if (n == 0)
                        return 1;
                    return odd(n - 1);
                }

                int odd(int n) {
                    if (n == 0)
                        return 0;
                    return even(n - 1);
                }

                int main() {
                    return even(20) == 1 && odd(21) == 1 ? 0 : 1;
                }
            },
        );
    }
}

static foreach (backend; Matrix!()) {
    @("nested.recursiveGuestCall.fibonacci." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(
            backend,
            q{
                int fibonacci(int n) {
                    if (n < 2)
                        return n;
                    return fibonacci(n - 1) + fibonacci(n - 2);
                }

                int tak(int x, int y, int z) {
                    if (x <= y)
                        return y;
                    return tak(
                        tak(x - 1, y, z),
                        tak(y - 1, z, x),
                        tak(z - 1, x, y),
                    );
                }

                int main() {
                    return fibonacci(12) == 144 && tak(6, 4, 2) == 6
                        ? 0 : 1;
                }
            },
        );
    }
}

// A delegate that captures nothing never reads its context word, so
// `call`, a function with no static chain of its own to `main`, must
// still be able to run it - the delegate's own body needs nothing from
// `call`'s frame, or from any frame at all.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
)) {
    @("nested.staticChain.nonCapturingDelegateNeedsNoLink." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int call(int delegate(int) dg) { return dg(41); }
            int main() {
                int delegate(int) inc = (int v) => v + 1;
                return call(inc) == 42 ? 0 : 1;
            }
        });
    }
}

// `callInner` never reads an outer variable itself, but the static link
// it is handed still has to be the real one, not a stand-in: `inner`,
// which `callInner` calls, does read one, and it reaches it by walking
// the same link back up from wherever it was called through - here, that
// is `callInner`'s frame, not `main`'s directly.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
)) {
    @("nested.staticChain.transitiveLinkThroughNonCapturingCaller." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                int x = 41;
                int inner() { return x + 1; }
                int callInner() { return inner(); }
                return callInner() == 42 ? 0 : 1;
            }
        });
    }
}

// Taking `captureIt`'s address makes dmd move `x` to a heap-allocated
// closure. Returning the delegate proves that the captured storage remains
// available after the function that created it has returned.
static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.unconfirmed),
)) {
    @("nested.staticChain.escapingCaptureOutlivesCreator." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        67.shouldBeRetOf!(
            backend,
            q{
            int delegate() makeCounter() {
                int count = 5;
                int next() {
                    return ++count;
                }

                return &next;
            }

            int main() {
                auto counter = makeCounter();
                int first = counter();
                int second = counter();
                return first * 10 + second;
            }
            },
            "main",
        );
    }
}
