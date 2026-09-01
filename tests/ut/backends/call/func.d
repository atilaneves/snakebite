module ut.backends.call.func;


import ut.backends;
import snakebite.backends.backend: Program;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;


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
    @("ret.int.fullWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1_234_567_890.shouldBeRetOf!(
            backend,
            q{
                int answer() {
                    return 1_234_567_890;
                }
            },
            "answer",
        );
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot run mutable struct methods through interpreter frames"),
)) {
    @("struct.cerealiser.defaultArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        size_t(0).shouldBeRetOf!(
            backend,
            q{
                struct Cerealiser {
                    ubyte[] _bytes;

                    const(ubyte)[] bytes() const {
                        return _bytes;
                    }
                }

                size_t empty() {
                    auto cerealiser = Cerealiser();
                    return cerealiser.bytes.length;
                }
            },
            "empty",
        );
    }

    @("struct.decerealiser.constructorArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        ubyte(7).shouldBeRetOf!(
            backend,
            q{
                struct Decerealiser {
                    const(ubyte)[] _bytes;

                    this(in ubyte[] bytes) {
                        _bytes = bytes;
                    }

                    const(ubyte)[] bytes() const {
                        return _bytes;
                    }
                }

                ubyte supplied() {
                    auto decoder = Decerealiser([3, 7]);
                    return decoder.bytes[1];
                }
            },
            "supplied",
        );
    }

    @("struct.mutableMethod.dynamicArrayField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        size_t(1).shouldBeRetOf!(
            backend,
            q{
                struct Buffer {
                    ubyte[] _bytes;

                    void append() {
                        _bytes ~= 1;
                    }
                }

                size_t filled() {
                    auto buffer = Buffer();
                    buffer.append();
                    return buffer._bytes.length;
                }
            },
            "filled",
        );
    }

    @("struct.thisAndRefField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7.shouldBeRetOf!(
            backend,
            q{
                struct Counter {
                    int value;

                    void set(int next) {
                        this.value = next;
                    }

                    ref int slot() {
                        return this.value;
                    }
                }

                int drive() {
                    auto counter = Counter();
                    counter.set(3);
                    counter.slot() = 7;
                    return counter.value;
                }
            },
            "drive",
        );
    }

    @("struct.implicitFieldAssign." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        9.shouldBeRetOf!(
            backend,
            q{
                struct Counter {
                    int value;

                    void set(int next) {
                        value = next;
                    }
                }

                int drive() {
                    auto counter = Counter();
                    counter.set(9);
                    return counter.value;
                }
            },
            "drive",
        );
    }
}

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
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

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
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

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
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

// Every D integral width, both signednesses, `bool` and a character type,
// all in one parameter list - a backend that got any one parameter's
// offset, width or signedness wrong reads back a different value for it.
// A separate reader per parameter, the same shape `call.alignment` above
// pins alignment with, since there is no arithmetic here to combine them
// into one answer.
static foreach (backend; Matrix!()) {
    @("call.parameters.everyIntegralWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        enum code = q{
            byte readA(byte a, ubyte b, short c, ushort d, int e, uint f,
                    long g, ulong h, bool i, char j) {
                return a;
            }
            ubyte readB(byte a, ubyte b, short c, ushort d, int e, uint f,
                    long g, ulong h, bool i, char j) {
                return b;
            }
            short readC(byte a, ubyte b, short c, ushort d, int e, uint f,
                    long g, ulong h, bool i, char j) {
                return c;
            }
            ushort readD(byte a, ubyte b, short c, ushort d, int e, uint f,
                    long g, ulong h, bool i, char j) {
                return d;
            }
            int readE(byte a, ubyte b, short c, ushort d, int e, uint f,
                    long g, ulong h, bool i, char j) {
                return e;
            }
            uint readF(byte a, ubyte b, short c, ushort d, int e, uint f,
                    long g, ulong h, bool i, char j) {
                return f;
            }
            long readG(byte a, ubyte b, short c, ushort d, int e, uint f,
                    long g, ulong h, bool i, char j) {
                return g;
            }
            ulong readH(byte a, ubyte b, short c, ushort d, int e, uint f,
                    long g, ulong h, bool i, char j) {
                return h;
            }
            bool readI(byte a, ubyte b, short c, ushort d, int e, uint f,
                    long g, ulong h, bool i, char j) {
                return i;
            }
            char readJ(byte a, ubyte b, short c, ushort d, int e, uint f,
                    long g, ulong h, bool i, char j) {
                return j;
            }

            byte driveA() {
                return readA(-1, 2, -3, 4, -5, 6, -7, 8, true, 'z');
            }
            ubyte driveB() {
                return readB(-1, 2, -3, 4, -5, 6, -7, 8, true, 'z');
            }
            short driveC() {
                return readC(-1, 2, -3, 4, -5, 6, -7, 8, true, 'z');
            }
            ushort driveD() {
                return readD(-1, 2, -3, 4, -5, 6, -7, 8, true, 'z');
            }
            int driveE() {
                return readE(-1, 2, -3, 4, -5, 6, -7, 8, true, 'z');
            }
            uint driveF() {
                return readF(-1, 2, -3, 4, -5, 6, -7, 8, true, 'z');
            }
            long driveG() {
                return readG(-1, 2, -3, 4, -5, 6, -7, 8, true, 'z');
            }
            ulong driveH() {
                return readH(-1, 2, -3, 4, -5, 6, -7, 8, true, 'z');
            }
            bool driveI() {
                return readI(-1, 2, -3, 4, -5, 6, -7, 8, true, 'z');
            }
            char driveJ() {
                return readJ(-1, 2, -3, 4, -5, 6, -7, 8, true, 'z');
            }
        };

        (cast(byte) -1).shouldBeRetOf!(backend, code, "driveA");
        (cast(ubyte) 2).shouldBeRetOf!(backend, code, "driveB");
        (cast(short) -3).shouldBeRetOf!(backend, code, "driveC");
        (cast(ushort) 4).shouldBeRetOf!(backend, code, "driveD");
        (-5).shouldBeRetOf!(backend, code, "driveE");
        (6u).shouldBeRetOf!(backend, code, "driveF");
        (-7L).shouldBeRetOf!(backend, code, "driveG");
        (8UL).shouldBeRetOf!(backend, code, "driveH");
        true.shouldBeRetOf!(backend, code, "driveI");
        ('z').shouldBeRetOf!(backend, code, "driveJ");
    }
}

// `size_t`/`ptrdiff_t` are pointer-sized integral aliases, not their own
// native layout - a parameter and a local of one both round-trip through
// exactly the width/signedness rules an `ulong`/`long` already does.
static foreach (backend; Matrix!()) {
    @("call.parameters.pointerSized." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        size_t(7).shouldBeRetOf!(
            backend,
            q{
                size_t identity(size_t n) {
                    size_t copy = n;
                    return copy;
                }

                size_t seven() {
                    return identity(7);
                }
            },
            "seven",
        );
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
    @("call.unreachableAfterReturn." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // dmd keeps an `if` after an unconditional `return` in the body
        // (it only warns about it with `-w`), so a backend must accept a
        // function with a statement kind it does not otherwise support,
        // as long as nothing ever runs it. Laying out a frame is not the
        // same question as running the body: a pass that inspects every
        // statement the parser kept, rather than only the ones a call
        // would actually execute, must not refuse the function over one
        // it would never reach.
        42.shouldBeRetOf!(
            backend,
            q{
                int answer() {
                    return 42;
                    if (1) { }
                }
            },
            "answer",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("call.void." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // A `void` function's own `return` can wrap a call to another
        // `void` function: there is no destination to write the result
        // into, only `inner`'s effects to run.
        enum code = q{
            void inner() {
            }

            void outer() {
                return inner();
            }
        };

        // Pins that the void call path runs to completion without
        // throwing. The subset it exercises has no observable effects
        // yet, so nothing stronger can be asserted here until it does.
        // `shouldBeRetOf` needs a return value to compare, so this drives
        // the call directly on either arm.
        static if (is(backend == Native)) {
            mixin(code);
            outer;
        } else {
            auto guestModule = parseSnippet(code);
            auto function_ = findFunction(guestModule, "outer");
            assert(function_ !is null,
                "No function `outer` in the guest program");

            (new backend(Program([guestModule]))).call(function_, null, []);
        }
    }
}
