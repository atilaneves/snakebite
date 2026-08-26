module ut.backends.call.func;


import ut.backends;


static foreach (backend; Matrix!()) {
    @("ret.int." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                int answer() {
                    return 42;
                }
            },
            "answer",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("ret.double." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        33.3.shouldBeRetOf!(
            backend,
            q{
                double answer() {
                    return 33.3;
                }
            },
            "answer",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("call." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        11.1.shouldBeRetOf!(
            backend,
            q{
                // `identity` first: the native oracle mixes this snippet's
                // functions into a local delegate scope, and nested D
                // functions (unlike module-scope ones) do not see a sibling
                // declared later in the same scope. The guest side parses
                // this as a whole module, where declaration order does not
                // affect name resolution, so this ordering does not change
                // what is being tested.
                double identity(double d) {
                    return d;
                }

                double func() {
                    return identity(identity(11.1));
                }
            },
            "func",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("call.alignment." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // Mixed alignment - `int`, `double`, `long` - pins the
        // offset/padding math for every parameter, not just the trivial
        // single-`double`-at-offset-0 case above: `b` needs 8-byte
        // alignment after `a`'s 4 bytes, so the layout has real padding
        // to get right, and `c` must land after that padding, not right
        // after `a`.
        enum code = q{
            int readA(int a, double b, long c) {
                return a;
            }

            double readB(int a, double b, long c) {
                return b;
            }

            long readC(int a, double b, long c) {
                return c;
            }

            int driveA() {
                return readA(5, 2.5, 99);
            }

            double driveB() {
                return readB(5, 2.5, 99);
            }

            long driveC() {
                return readC(5, 2.5, 99);
            }
        };

        5.shouldBeRetOf!(backend, code, "driveA");
        2.5.shouldBeRetOf!(backend, code, "driveB");
        99L.shouldBeRetOf!(backend, code, "driveC");
    }
}

static foreach (backend; Matrix!()) {
    @("call.fallthrough." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // Execution must stop at the first `ReturnStatement` it runs.
        // dmd accepts the unreachable `return 2;` (it only warns with
        // `-w`), so a backend that keeps walking past the first `return`
        // would silently overwrite 1 with 2 instead of rejecting the
        // program.
        1.shouldBeRetOf!(
            backend,
            q{
                int f() {
                    return 1;
                    return 2;
                }
            },
            "f",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("call.void." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        import snakebite.frontend.compiler: parseSnippet;
        import snakebite.frontend.dmd.functions: findFunction;

        auto guestModule = parseSnippet(q{
            void inner() {
            }

            // A `void` function's own `return` can wrap a call to
            // another `void` function: there is no destination to
            // write the result into, only `inner`'s effects to run.
            void outer() {
                return inner();
            }
        });
        auto function_ = findFunction(guestModule, "outer");
        assert(function_ !is null,
            "No function `outer` in the guest program");

        // Pins that the void guest-call path runs to completion without
        // throwing. The guest subset it exercises has no observable
        // effects yet, so nothing stronger can be asserted here until it
        // does.
        (new backend).call(function_, null, []);
    }
}
