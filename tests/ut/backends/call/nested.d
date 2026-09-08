module ut.backends.call.nested;


import ut.backends;


// The non-escaping case: `bump` is called while `main`'s own frame is
// still on the interpreter's frame stack, so reading and then writing
// `counter` through the static chain reaches the same storage a compiled
// `bump` would.
static foreach (backend; Matrix!()) {
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

                counter = 10;
                assert(counter++ == 10);
                assert(counter == 11);
                assert((counter = 42) == 42);
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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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

// A non-static nested struct with its own declared field carries an
// outer-function context word besides that field: dmd appends the
// context field (`vthis`) after every declared field, so the context
// must not land where the struct's own first field lives. Calling a
// method that reads the captured local proves the context reached the
// right place.
static foreach (backend; Matrix!()) {
    @("nested.staticChain.nestedStructOwnFieldKeepsContext." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                int base = 40;
                struct Adder {
                    int extra;
                    int sum() { return base + extra; }
                }
                auto a = Adder(2);
                return a.sum() == 42 ? 0 : 1;
            }
        });
    }
}

// `build!Local` is textually inside `main`'s enclosing module, not `main`
// itself, but dmd still attaches it to `main`'s own scope: instantiating a
// template with a locally-declared type argument makes the instantiation
// itself nested whichever function declared that type. `Local` is a
// `static struct`, so it has no actual outer-context field to fill in
// (`AggregateDeclaration.isNested` is `false`) - only its lexical position
// makes it look nested. Constructing a `Local` value must not try to reach
// a context nothing captured.
static foreach (backend; Matrix!()) {
    @("nested.staticChain.localStaticStructNeedsNoOuterContext." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int build(T)() {
                T t;
                return t.i;
            }

            int main() {
                static struct Local {
                    int i = 42;
                }

                return build!Local() == 42 ? 0 : 1;
            }
        });
    }
}

// A nested struct's method can read a parameter of the enclosing function,
// not only a local: dmd stores a parameter and a local the same way in the
// enclosing frame, so the static chain must reach either one.
static foreach (backend; Matrix!()) {
    @("nested.staticChain.nestedStructReadsEnclosingParameter." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int addToParam(int p) {
                struct Reader {
                    int read() { return p + 2; }
                }
                return Reader().read();
            }

            int main() {
                return addToParam(40) == 42 ? 0 : 1;
            }
        });
    }
}

// `opEquals` reading an enclosing local directly, with no field of its own
// to go through first, is the shape a `lazy` assertion wrapper actually
// builds (`should(expression) == expected` in a hand-rolled `unit_threaded`
// stand-in): the struct's `vthis` is its only field, so this also proves
// the context lands correctly when there is no other field ahead of it.
static foreach (backend; Matrix!()) {
    @("nested.staticChain.opEqualsComparesAgainstEnclosingLocal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                int base = 40;
                struct Wrapper {
                    bool opEquals(int other) {
                        return base + 2 == other;
                    }
                }
                auto w = Wrapper();
                return w == 42 ? 0 : 1;
            }
        });
    }
}

// A nested struct declared inside a nested function, reading a local two
// frames further out, exercises `contextAddressOf`'s walk across more than
// one hop: struct to its own immediate function, then that function on to
// its own enclosing one.
static foreach (backend; Matrix!()) {
    @("nested.staticChain.nestedStructInsideNestedFunctionTwoLevelChain." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                int base = 40;
                int outer() {
                    struct Reader {
                        int read() { return base + 2; }
                    }
                    return Reader().read();
                }
                return outer() == 42 ? 0 : 1;
            }
        });
    }
}

// Taking `captureIt`'s address makes dmd move `x` to a heap-allocated
// closure. Returning the delegate proves that the captured storage remains
// available after the function that created it has returned.
static foreach (backend; Matrix!(
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

            int run() {
                auto counter = makeCounter();
                int first = counter();
                int second = counter();
                return first * 10 + second;
            }
            },
            "run",
        );
    }
}

// A nested struct with a user constructor, bound to a variable: dmd
// rewrites `auto a = Adder(2)` into a default-init struct literal assigned
// to `a` followed by `a.__ctor(2)`, so the struct literal is what supplies
// the outer-context field, and the constructor runs on storage that
// already has it.
static foreach (backend; Matrix!()) {
    @("nested.staticChain.ctorCallOnVariableKeepsContext." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                int base = 40;
                struct Adder {
                    int extra;
                    this(int e) { extra = e; }
                    int sum() { return base + extra; }
                }
                auto a = Adder(2);
                return a.sum() == 42 ? 0 : 1;
            }
        });
    }
}

// The constructor body itself reads the enclosing local, so the context
// has to be in place before the constructor runs, not only before a
// later method call.
static foreach (backend; Matrix!()) {
    @("nested.staticChain.ctorBodyReadsEnclosingLocal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                int base = 40;
                struct Adder {
                    int total;
                    this(int e) { total = base + e; }
                }
                auto a = Adder(2);
                return a.total == 42 ? 0 : 1;
            }
        });
    }
}

// A constructor-call temporary used directly as an rvalue, never bound to
// a named variable: dmd keeps `S(args)` as `S.init.__ctor(args)` - a call
// whose receiver is a struct literal - rather than splitting it into a
// variable initialisation and a separate constructor call. The receiver
// literal is where dmd expects the outer context to be filled in.
static foreach (backend; Matrix!()) {
    @("nested.staticChain.ctorCallTemporaryKeepsContext." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                int base = 40;
                struct Adder {
                    int extra;
                    this(int e) { extra = e; }
                    int sum() { return base + extra; }
                }
                return Adder(2).sum() == 42 ? 0 : 1;
            }
        });
    }
}

// `new S(args)` with no constructor fills the declared fields positionally
// from the arguments; the outer-context field has no argument of its own
// and dmd expects whoever allocates the object to fill it in.
static foreach (backend; Matrix!()) {
    @("nested.staticChain.newPositionalKeepsContext." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                int base = 40;
                struct Adder {
                    int extra;
                    int sum() { return base + extra; }
                }
                auto a = new Adder(2);
                return a.sum() == 42 ? 0 : 1;
            }
        });
    }
}

// `new S` with no arguments at all: the allocation copies `S.init`, whose
// outer-context field is null, so the context still has to be written
// after the allocation.
static foreach (backend; Matrix!()) {
    @("nested.staticChain.newNoArgsKeepsContext." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                int base = 40;
                struct Reader {
                    int read() { return base + 2; }
                }
                auto r = new Reader;
                return r.read() == 42 ? 0 : 1;
            }
        });
    }
}

// `new S(args)` with a user constructor: the constructor runs on the
// allocation, so the context must already be there when it does.
static foreach (backend; Matrix!()) {
    @("nested.staticChain.newCtorKeepsContext." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                int base = 40;
                struct Adder {
                    int extra;
                    this(int e) { extra = e; }
                    int sum() { return base + extra; }
                }
                auto a = new Adder(2);
                return a.sum() == 42 ? 0 : 1;
            }
        });
    }
}

// The literal is built inside a nested function of the struct's own
// enclosing function, one frame away from the context it captures: the
// context written into the literal must be the enclosing function's
// frame, not the frame the literal happens to be built in.
static foreach (backend; Matrix!()) {
    @("nested.staticChain.literalBuiltInNestedFunction." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                int base = 40;
                struct Reader {
                    int read() { return base + 2; }
                }
                int build() { return Reader().read(); }
                return build() == 42 ? 0 : 1;
            }
        });
    }
}

// The literal is built inside another nested struct's method: reaching the
// shared enclosing frame from there goes through the builder's own
// context field first.
static foreach (backend; Matrix!()) {
    @("nested.staticChain.literalBuiltInSiblingStructMethod." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                int base = 40;
                struct Reader {
                    int read() { return base + 2; }
                }
                struct Builder {
                    int go() { return Reader().read(); }
                }
                return Builder().go() == 42 ? 0 : 1;
            }
        });
    }
}

// A struct declared inside a nested struct's method captures that method's
// frame; reading `main`'s local from the inner struct then alternates
// struct, function, struct, function all the way out.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "the interpreter's closure allocation only stores an outer link "
            ~ "when its own immediate parent is a function; a method of a "
            ~ "nested struct has a struct as its immediate parent, so the "
            ~ "closure it allocates links to nothing"),
)) {
    @("nested.staticChain.structInsideNestedStructMethod." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                int base = 40;
                struct Outer {
                    int bump;
                    int go() {
                        int extra = bump;
                        struct Inner {
                            int r() { return base + extra; }
                        }
                        return Inner().r();
                    }
                }
                return Outer(2).go() == 42 ? 0 : 1;
            }
        });
    }
}

// A struct nested in a class method captures that method's frame the same
// way as one nested in a free function; the class's own `this` is not
// visible to it, only the method's locals are.
static foreach (backend; Matrix!()) {
    @("nested.staticChain.structInClassMethodReadsLocal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class C {
                int field = 2;
                int go() {
                    int base = 40 + field;
                    struct Reader {
                        int read() { return base; }
                    }
                    return Reader().read();
                }
            }
            int main() {
                return new C().go() == 42 ? 0 : 1;
            }
        });
    }
}

// A struct declared by a template mixin mixed into a function is nested in
// that function: the mixin is transparent to the struct's parent lookup.
static foreach (backend; Matrix!()) {
    @("nested.staticChain.structFromTemplateMixin." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            mixin template Decl() {
                struct Reader {
                    int read() { return base + 2; }
                }
            }
            int main() {
                int base = 40;
                mixin Decl;
                return Reader().read() == 42 ? 0 : 1;
            }
        });
    }
}
