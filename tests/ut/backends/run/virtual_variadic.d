module ut.backends.run.virtual_variadic;


import ut.backends;

// An untyped D variadic receives the call's `TypeInfo` tuple before its
// declared parameters, and the extra arguments after them.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed,
        "CTFE has no D-style variadic functions"),
)) {
    @("virtualVariadic.classOverrideReadsExtraArguments."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.vararg;
            class Base {
                int sum(int first, ...) { return -1; }
            }
            class Derived: Base {
                override int sum(int first, ...) {
                    int total = first;
                    foreach (type; _arguments) {
                        assert(type == typeid(int));
                        total += va_arg!int(_argptr);
                    }
                    return total;
                }
            }
            void main() {
                Base base = new Derived;
                assert(base.sum(3) == 3);
                assert(base.sum(3, 4) == 7);
                assert(base.sum(3, 4, 5, 6) == 18);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed,
        "CTFE has no D-style variadic functions"),
)) {
    @("virtualVariadic.interfaceDispatchReadsExtraArguments."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.vararg;
            interface Summer {
                int sum(int first, ...);
            }
            class Implementation: Summer {
                int sum(int first, ...) {
                    int total = first;
                    foreach (type; _arguments)
                        total += va_arg!int(_argptr);
                    return total;
                }
            }
            void main() {
                Summer summer = new Implementation;
                assert(summer.sum(1) == 1);
                assert(summer.sum(1, 2, 3) == 6);
            }
        });
    }
}

// Each receiver and argument is evaluated once, left to right.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed,
        "CTFE has no D-style variadic functions"),
)) {
    @("virtualVariadic.evaluatesReceiverAndArgumentsOnceInOrder."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.vararg;
            class C {
                int sum(int first, ...) {
                    int total = first;
                    foreach (type; _arguments)
                        total += va_arg!int(_argptr);
                    return total;
                }
            }
            void main() {
                int log;
                int step(int value) { log = log * 10 + value; return value; }
                C receiver() { log = log * 10 + 9; return new C; }
                assert(receiver.sum(step(1), step(2), step(3)) == 6);
                assert(log == 9123);
            }
        });
    }
}

static foreach (backend; Matrix!()) {
    @("virtualVariadic.typesafeArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Base {
                int sum(int[] values...) { return -1; }
            }
            class Derived: Base {
                override int sum(int[] values...) {
                    int total;
                    foreach (value; values)
                        total += value;
                    return total;
                }
            }
            void main() {
                Base base = new Derived;
                assert(base.sum() == 0);
                assert(base.sum(1, 2, 3) == 6);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed,
        "CTFE has no D-style variadic functions"),
)) {
    @("virtualVariadic.mixedTypes." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.vararg;
            class C {
                double f(int first, ...) {
                    double total = first;
                    foreach (type; _arguments) {
                        if (type == typeid(int))
                            total += va_arg!int(_argptr);
                        else if (type == typeid(double))
                            total += va_arg!double(_argptr);
                    }
                    return total;
                }
            }
            void main() {
                C c = new C;
                assert(c.f(1, 2, 2.5, 3) == 8.5);
            }
        });
    }
}

// An interface's vtable slot adjusts the interface reference back to the
// object before the method body reads a field through `this`.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot run D-style variadic functions"),
)) {
    @("virtualVariadic.interfaceDispatchAdjustsReceiver."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.vararg;
            interface Summer {
                int sum(int first, ...);
            }
            class Implementation: Summer {
                int bias = 1000;
                int sum(int first, ...) {
                    int total = first + bias;
                    foreach (type; _arguments)
                        total += va_arg!int(_argptr);
                    return total;
                }
            }
            void main() {
                Summer summer = new Implementation;
                assert(summer.sum(1) == 1001);
                assert(summer.sum(1, 2, 3) == 1006);
            }
        });
    }
}
