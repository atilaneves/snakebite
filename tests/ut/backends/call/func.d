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


static foreach (backend; Matrix!()) {
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
}

static foreach (backend; Matrix!()) {
    @("struct.dynamicArrayFieldIdentity.null." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        true.shouldBeRetOf!(
            backend,
            q{
                struct Cerealiser {
                    ubyte[] _bytes;

                    bool empty() {
                        return this._bytes is null;
                    }
                }

                bool answer() {
                    auto cerealiser = Cerealiser();
                    return cerealiser.empty();
                }
            },
            "answer",
        );
    }
}

static foreach (backend; Matrix!()) {
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
}

static foreach (backend; Matrix!()) {
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
}

static foreach (backend; Matrix!()) {
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
}

static foreach (backend; Matrix!()) {
    @("struct.implicitFieldAssign." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        9.shouldBeRetOf!(
            backend,
            q{
                struct Counter {
                    int padding;
                    int value;

                    void set(int next) {
                        value = next;
                    }
                }

                int drive() {
                    auto counter = Counter();
                    counter.set(9);
                    return counter.padding + counter.value;
                }
            },
            "drive",
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

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot convert a local variable's address to an integer"),
)) {
    @("call.alignedRealLocal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42L.shouldBeRetOf!(backend, q{
            long read(ubyte prefix, long input) {
                real value = input;
                assert(cast(size_t) &value % real.alignof == 0);
                return prefix + cast(long) value;
            }

            long answer() {
                return read(2, 40);
            }
        }, "answer");
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


static foreach (backend; Matrix!()) {
    @("call.manyArguments." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        496.shouldBeRetOf!(backend, q{
            int sum(
                int a0, int a1, int a2, int a3,
                int a4, int a5, int a6, int a7,
                int a8, int a9, int a10, int a11,
                int a12, int a13, int a14, int a15,
                int a16, int a17, int a18, int a19,
                int a20, int a21, int a22, int a23,
                int a24, int a25, int a26, int a27,
                int a28, int a29, int a30,
            ) {
                return a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8
                    + a9 + a10 + a11 + a12 + a13 + a14 + a15 + a16
                    + a17 + a18 + a19 + a20 + a21 + a22 + a23 + a24
                    + a25 + a26 + a27 + a28 + a29 + a30;
            }
            int answer() {
                return sum(
                    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
                    16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28,
                    29, 30, 31,
                );
            }
        }, "answer");
    }
}


static foreach (backend; Matrix!()) {
    @("call.manyArguments.hiddenContext." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        236.shouldBeRetOf!(backend, q{
            struct Offset {
                int value;
                int sum(
                    int a0, int a1, int a2, int a3,
                    int a4, int a5, int a6, int a7,
                    int a8, int a9, int a10, int a11,
                    int a12, int a13, int a14, int a15,
                ) {
                    return value + a0 + a1 + a2 + a3 + a4 + a5 + a6
                        + a7 + a8 + a9 + a10 + a11 + a12 + a13 + a14
                        + a15;
                }
            }
            int answer() {
                auto offset = Offset(100);
                return offset.sum(
                    1, 2, 3, 4, 5, 6, 7, 8,
                    9, 10, 11, 12, 13, 14, 15, 16,
                );
            }
        }, "answer");
    }
}


// A direct call to a guest C variadic function with a body reads its
// extra arguments with `va_arg` on `_argptr`.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot run C-style variadic functions"),
)) {
    @("call.variadicC.directArgptr." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        115.shouldBeRetOf!(backend, q{
            import core.stdc.stdarg: va_arg;
            extern(C) int sum(int count, ...) {
                int total = 100;
                foreach (i; 0 .. count)
                    total += va_arg!int(_argptr);
                return total;
            }
            int answer() { return sum(3, 4, 5, 6); }
        }, "answer");
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot run C-style variadic functions"),
)) {
    @("call.variadicC.startArg.int." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        15.shouldBeRetOf!(backend, q{
            import core.stdc.stdarg: va_arg, va_end, va_list, va_start;
            extern(C) int sum(int count, ...) {
                va_list args;
                va_start(args, count);
                int total;
                foreach (i; 0 .. count)
                    total += va_arg!int(args);
                va_end(args);
                return total;
            }
            int answer() { return sum(3, 4, 5, 6); }
        }, "answer");
    }
}
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot run C-style variadic functions"),
)) {
    @("call.variadicC.startArg.long." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        6000000007.shouldBeRetOf!(backend, q{
            import core.stdc.stdarg: va_arg, va_end, va_list, va_start;
            extern(C) long sum(int count, ...) {
                va_list args;
                va_start(args, count);
                long total;
                foreach (i; 0 .. count)
                    total += va_arg!long(args);
                va_end(args);
                return total;
            }
            long answer() { return sum(2, 3_000_000_000L, 3_000_000_007L); }
        }, "answer");
    }
}
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot run C-style variadic functions"),
)) {
    @("call.variadicC.startArg.double." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7.5.shouldBeRetOf!(backend, q{
            import core.stdc.stdarg: va_arg, va_end, va_list, va_start;
            extern(C) double sum(int count, ...) {
                va_list args;
                va_start(args, count);
                double total = 0;
                foreach (i; 0 .. count)
                    total += va_arg!double(args);
                va_end(args);
                return total;
            }
            double answer() { return sum(3, 1.5, 2.0, 4.0); }
        }, "answer");
    }
}
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot run C-style variadic functions"),
)) {
    @("call.variadicC.startArg.pointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(backend, q{
            import core.stdc.stdarg: va_arg, va_end, va_list, va_start;
            extern(C) int first(int count, ...) {
                va_list args;
                va_start(args, count);
                auto pointer = va_arg!(int*)(args);
                va_end(args);
                return *pointer;
            }
            int answer() {
                int value = 42;
                return first(1, &value);
            }
        }, "answer");
    }
}
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot run C-style variadic functions"),
)) {
    @("call.variadicC.startArg.struct." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1234.shouldBeRetOf!(backend, q{
            import core.stdc.stdarg: va_arg, va_end, va_list, va_start;
            struct Pair { int first; int second; }
            extern(C) int firstPair(int count, ...) {
                va_list args;
                va_start(args, count);
                const pair = va_arg!Pair(args);
                va_end(args);
                return pair.first * 100 + pair.second;
            }
            int answer() { return firstPair(1, Pair(12, 34)); }
        }, "answer");
    }
}
// `va_arg(ap, ref T)` stores the next extra argument in the variable.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot run C-style variadic functions"),
)) {
    @("call.variadicC.startArg.ref." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        9.shouldBeRetOf!(backend, q{
            import core.stdc.stdarg: va_arg, va_end, va_list, va_start;
            extern(C) int sum(int count, ...) {
                va_list args;
                va_start(args, count);
                int total;
                foreach (i; 0 .. count) {
                    int next;
                    va_arg(args, next);
                    total += next;
                }
                va_end(args);
                return total;
            }
            int answer() { return sum(2, 4, 5); }
        }, "answer");
    }
}


// A second `va_start` starts again from the first extra argument.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot run C-style variadic functions"),
)) {
    @("call.variadicC.startRestart." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        18.shouldBeRetOf!(backend, q{
            import core.stdc.stdarg: va_arg, va_end, va_list, va_start;
            extern(C) int twice(int count, ...) {
                va_list args;
                int total;
                foreach (pass; 0 .. 2) {
                    va_start(args, count);
                    foreach (i; 0 .. count)
                        total += va_arg!int(args);
                    va_end(args);
                }
                return total;
            }
            int answer() { return twice(3, 1, 3, 5); }
        }, "answer");
    }
}
// A `va_copy` has its own position: reading it leaves the original alone.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot run C-style variadic functions"),
)) {
    @("call.variadicC.copy." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        18.shouldBeRetOf!(backend, q{
            import core.stdc.stdarg: va_arg, va_copy, va_end, va_list, va_start;
            extern(C) int sumTwice(int count, ...) {
                va_list args;
                va_start(args, count);
                va_list copy;
                va_copy(copy, args);
                int total;
                foreach (i; 0 .. count)
                    total += va_arg!int(args);
                foreach (i; 0 .. count)
                    total += va_arg!int(copy);
                va_end(copy);
                va_end(args);
                return total;
            }
            int answer() { return sumTwice(3, 1, 3, 5); }
        }, "answer");
    }
}


// A `va_list` parameter refers to the caller's cursor, so the callee reads
// the caller's extra arguments.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot run C-style variadic functions"),
)) {
    @("call.variadicC.toGuest." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        12.shouldBeRetOf!(backend, q{
            import core.stdc.stdarg: va_arg, va_end, va_list, va_start;
            static int vsum(int count, va_list args) {
                int total;
                foreach (i; 0 .. count)
                    total += va_arg!int(args);
                return total;
            }
            extern(C) int sum(int count, ...) {
                va_list args;
                va_start(args, count);
                const total = vsum(count, args);
                va_end(args);
                return total;
            }
            int answer() { return sum(3, 3, 4, 5); }
        }, "answer");
    }
}


// A `va_list` can be passed to a C function such as `vsnprintf`.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot run C-style variadic functions"),
)) {
    @("call.variadicC.toHost." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeRetOf!(backend, q{
            import core.stdc.stdarg: va_end, va_list, va_start;
            import core.stdc.stdio: vsnprintf;
            extern(C) int format(const(char)* pattern, ...) {
                char[32] buffer;
                va_list args;
                va_start(args, pattern);
                const length = vsnprintf(buffer.ptr, buffer.length, pattern, args);
                va_end(args);
                return length == 11 && buffer[0 .. 11] == "12 3.5 word" ? 1 : 0;
            }
            int answer() { return format("%d %.1f %s", 12, 3.5, "word".ptr); }
        }, "answer");
    }
}


// The compiler turns a call to `alloca` into stack allocation, so the
// memory lasts until the calling function returns and has no host symbol.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot call alloca"),
)) {
    @("call.alloca." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(backend, q{
            import core.stdc.stdlib: alloca;
            int answer() {
                auto numbers = cast(int*) alloca(2 * int.sizeof);
                numbers[0] = 40;
                numbers[1] = 2;
                return numbers[0] + numbers[1];
            }
        }, "answer");
    }
}


// Alloca memory is stack memory, which the GC scans: it can hold the
// only pointer to a GC object.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot call alloca"),
)) {
    @("call.alloca.holdsGcPointers." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        8028.shouldBeRetOf!(backend, q{
            import core.memory: GC;
            import core.stdc.stdlib: alloca;
            static void fill(int** slots) {
                foreach (i; 0 .. 8) {
                    slots[i] = new int;
                    *slots[i] = 1000 + i;
                }
            }
            static void churn(int** slots) {
                foreach (i; 0 .. 100_000) {
                    auto other = new int;
                    *other = -1;
                }
            }
            int answer() {
                auto slots = cast(int**) alloca(8 * (int*).sizeof);
                fill(slots);
                GC.collect;
                churn(slots);
                int total;
                foreach (i; 0 .. 8)
                    total += *slots[i];
                return total;
            }
        }, "answer");
    }
}


// The compiler finds `alloca` by its symbol name. A function with that
// identifier and a different symbol is a normal host function.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot call host code"),
)) {
    @("call.alloca.otherSymbol." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        5.shouldBeRetOf!(backend, q{
            pragma(mangle, "abs") extern(C) int alloca(int);
            int answer() { return alloca(-5); }
        }, "answer");
    }
}
