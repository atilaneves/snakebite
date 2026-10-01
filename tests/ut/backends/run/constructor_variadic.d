module ut.backends.run.constructor_variadic;


import ut.backends;
import core.vararg;

// An untyped D variadic constructor receives the call's `TypeInfo` tuple
// before its declared parameters, and the extra arguments after them,
// whether `new` allocates a class or a struct.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot run D-style variadic functions"),
)) {
    @("constructorVariadic.newClassReadsExtraArguments." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.vararg;
            class Summer {
                int total;
                this(int first, ...) {
                    total = first;
                    foreach (type; _arguments) {
                        assert(type == typeid(int));
                        total += va_arg!int(_argptr);
                    }
                }
            }
            void main() {
                assert((new Summer(1)).total == 1);
                assert((new Summer(1, 2, 3)).total == 6);
            }
        });
    }
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot run D-style variadic functions"),
)) {
    @("constructorVariadic.newStructReadsExtraArguments." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import core.vararg;
            struct Summer {
                int total;
                this(int first, ...) {
                    total = first;
                    foreach (type; _arguments) {
                        assert(type == typeid(int));
                        total += va_arg!int(_argptr);
                    }
                }
            }
            void main() {
                assert((new Summer(1)).total == 1);
                assert((new Summer(1, 2, 3)).total == 6);
            }
        });
    }
}
