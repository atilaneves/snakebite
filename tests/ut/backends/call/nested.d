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

// `middle`'s own nested function, `captureIt`, has its address taken and
// handed to a delegate variable - dmd's conservative `needsClosure()`
// rule (`FuncDeclaration.tookAddressOf`) marks `middle` as needing to
// heap-allocate its own frame for exactly this reason, regardless of
// `dg` never leaving `middle`'s own scope. A heap-allocated frame can
// outlive the call that made it, which calling `middle` here cannot
// provide, so it refuses loudly rather than handing `captureIt` a static
// link into storage that would not outlive it the way a real closure's
// would.
@("nested.staticChain.escapingCaptureIsRefused.Interpreter")
@Tags("Interpreter")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        int outer() {
            int middle() {
                int x = 5;
                int captureIt() { return x; }
                int delegate() dg = &captureIt;
                return dg();
            }
            return middle();
        }
    });
    auto function_ = findFunction(module_, "outer");

    int result;
    interpreter(module_).call(function_, &result, [])
        .shouldThrowWithMessage(
            "interpreter cannot call `middle`: it captures an outer " ~
                "variable that must outlive the enclosing call, which " ~
                "the interpreter's frame stack does not support");
}
