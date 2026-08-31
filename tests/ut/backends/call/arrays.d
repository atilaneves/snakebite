module ut.backends.call.arrays;


import ut.backends;


static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot hold mutable static state across calls"),
)) {
    @("arrays.append.static.repeatedCalls." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        4.shouldBeRetOf!(
            backend,
            q{
                int incAppend() {
                    static int[] arr;
                    if(!arr)
                        arr = [0];
                    else {
                        arr ~= arr[$-1] + 1;
                    }
                    return arr[$-1];
                }
                int kindaMain() {
                    int ret;
                    foreach(i; 0 .. 5) {
                        ret = incAppend;
                    }
                    return ret;
                }
            },
            "kindaMain",
        );
    }
}

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("arrays.length." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // A string literal is a slice of code units the compiler already
        // laid out, so `.length` is the first word of the pair without
        // anything having to allocate.
        size_t(5).shouldBeRetOf!(
            backend,
            q{
                size_t length_() {
                    string text = "hello";
                    return text.length;
                }
            },
            "length_",
        );
    }
}

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("arrays.index." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        'e'.shouldBeRetOf!(
            backend,
            q{
                char second() {
                    string text = "hello";
                    size_t index = 1;
                    return text[index];
                }
            },
            "second",
        );
    }
}

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("arrays.dollar." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // `$` inside an index is a variable of its own that no statement
        // declares: dmd rewrites `text[$ - 1]` into an index over a
        // declaration it makes for the array's length.
        'o'.shouldBeRetOf!(
            backend,
            q{
                char last() {
                    string text = "hello";
                    return text[$ - 1];
                }
            },
            "last",
        );
    }
}

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("arrays.dollar.nested." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // Each index expression has its own `$`. `oneIfLastIsSet` indexes
        // its own array while the outer index in `pick` is still being
        // evaluated, so the inner `$` must stand for `flag`'s length, and
        // the outer one for `text`'s again afterwards.
        'l'.shouldBeRetOf!(
            backend,
            q{
                size_t oneIfLastIsSet(string bytes) {
                    if(bytes[$ - 1])
                        return 1;
                    return 0;
                }

                char pick() {
                    string text = "hello";
                    string flag = "yo";
                    return text[$ - oneIfLastIsSet(flag) - 1];
                }
            },
            "pick",
        );
    }
}

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("arrays.truth.null." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // A `null` slice is false where D asks for a condition, and both
        // words of it are zero.
        1.shouldBeRetOf!(
            backend,
            q{
                int nothing() {
                    string text = null;
                    if(!text)
                        return 1;
                    return 0;
                }
            },
            "nothing",
        );
    }
}

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("arrays.truth.literal." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        2.shouldBeRetOf!(
            backend,
            q{
                int something() {
                    string text = "hello";
                    if(text)
                        return 2;
                    return 0;
                }
            },
            "something",
        );
    }
}

static foreach (backend; Matrix!(
    BytecodeUnconfirmed,
    Omit!(Ctfe, Because.inexpressible,
        "CTFE turns an out-of-range index into a compile-time error, so " ~
        "it cannot be expressed the same way as a runtime throw"),
    Omit!(Interpreter, Because.diverges,
        "the interpreter refuses an out-of-range index instead, since it " ~
        "has no guest try/catch to throw into"),
)) {
    @("arrays.index.outOfRange.throws.RangeError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // An index outside the array is a `RangeError`, which derives from
        // `Error`: compiled D checks every index it cannot prove in range.
        'x'.shouldBeRetOf!(
            backend,
            q{
                char past() {
                    import core.exception: RangeError;

                    string text = "hello";
                    size_t index = 5;

                    try
                        return text[index];
                    catch(RangeError)
                        return 'x';
                }
            },
            "past",
        );
    }
}

// Compiled D throws a `RangeError` for an index outside the array, which
// needs guest exceptions the interpreter does not have. It refuses the
// index rather than reading the host address the guest asked for, so this
// pins a refusal where the test above pins the throw.
@("arrays.index.outOfRange.refused.Interpreter")
@Tags("Interpreter")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        char past() {
            string text = "hello";
            size_t index = 5;
            return text[index];
        }
    });
    auto function_ = findFunction(module_, "past");

    char result;
    interpreter(module_).call(function_, &result, [])
        .shouldThrow;
}

// A `null` array is zero-length with a null pointer, so an index into it
// is out of range like any other. Reading it instead would dereference
// null and take down the host process, not the guest.
@("arrays.index.nullArray.refused.Interpreter")
@Tags("Interpreter")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        char nothing() {
            string text = null;
            size_t index = 0;
            return text[index];
        }
    });
    auto function_ = findFunction(module_, "nothing");

    char result;
    interpreter(module_).call(function_, &result, [])
        .shouldThrow;
}

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("arrays.literal.index." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        20.shouldBeRetOf!(
            backend,
            q{
                int second() {
                    int[] a = [10, 20, 30];
                    return a[1];
                }
            },
            "second",
        );
    }
}

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("arrays.literal.length." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        size_t(3).shouldBeRetOf!(
            backend,
            q{
                size_t length_() {
                    int[] a = [1, 2, 3];
                    return a.length;
                }
            },
            "length_",
        );
    }
}

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("arrays.literal.nonConstantElements." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // `x + 1` rules out an implementation that only copies constant-
        // folded bytes dmd already computed instead of evaluating each
        // element.
        11.shouldBeRetOf!(
            backend,
            q{
                int sum() {
                    int x = 3;
                    int[] a = [x, x + 1];
                    return a[0] + a[1] * 2;
                }
            },
            "sum",
        );
    }
}

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("arrays.literal.single." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                int only() {
                    int[] a = [42];
                    return a[0];
                }
            },
            "only",
        );
    }
}

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("arrays.literal.empty.length." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        size_t(0).shouldBeRetOf!(
            backend,
            q{
                size_t length_() {
                    int[] a = [];
                    return a.length;
                }
            },
            "length_",
        );
    }
}

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("arrays.new.runtimeLength.initialiseAndWrite." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7.shouldBeRetOf!(
            backend,
            q{
                int useNewArray() {
                    size_t n = 3;
                    bool[] values = new bool[n];
                    const initiallyFalse = !values[0] && !values[2];
                    values[1] = true;
                    return cast(int) values.length + initiallyFalse * 3
                        + values[1];
                }
            },
            "useNewArray",
        );
    }
}

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("arrays.new.uint.initialiseAndWrite." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        uint(3_008).shouldBeRetOf!(
            backend,
            q{
                uint useNewArray() {
                    size_t n = 3_000;
                    uint[] values = new uint[n];
                    const initiallyZero = values[2_999] == 0;
                    values[17] = 7;
                    return cast(uint) values.length + initiallyZero
                        + values[17];
                }
            },
            "useNewArray",
        );
    }
}

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("arrays.new.scalar.nativeLayouts.initialiseAndWrite." ~
        backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                ubyte[] bytes = new ubyte[2];
                ushort[] words = new ushort[2];
                int[] ints = new int[2];
                long[] longs = new long[2];
                float[] floats = new float[2];
                double[] doubles = new double[2];

                assert(bytes[0] == ubyte.init);
                assert(words[0] == ushort.init);
                assert(ints[0] == int.init);
                assert(longs[0] == long.init);
                assert(floats[0] != floats[0]);
                assert(doubles[0] != doubles[0]);

                bytes[1] = 17;
                words[1] = 1_031;
                ints[1] = -32_047;
                longs[1] = 1_000_000_000_007L;
                floats[1] = 1.25F;
                doubles[1] = -2.5;

                assert(bytes[1] == 17);
                assert(words[1] == 1_031);
                assert(ints[1] == -32_047);
                assert(longs[1] == 1_000_000_000_007L);
                assert(floats[1] == 1.25F);
                assert(doubles[1] == -2.5);
            }
        });
    }
}

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("arrays.new.nestedStruct.zeroInitialises." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                struct Point {
                    int x;
                    long y;
                }

                auto points = new Point[](2);
                assert(points[0].x == 0);
                assert(points[0].y == 0);

                points[1] = Point(3, 4);
                assert(points[1].x == 3);
                assert(points[1].y == 4);
            }
        });
    }
}

// A literal assigned to a `static` slice is built once, on whichever call
// first reaches it - its elements must still be readable on a later call
// to the same function, after the frame that built them has long since
// been popped.
@("arrays.literal.static.outlivesFrame.Interpreter")
@Tags("Interpreter")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        int second() {
            static int[] arr;
            if (!arr)
                arr = [10, 20, 30];
            return arr[1];
        }
    });
    auto function_ = findFunction(module_, "second");
    auto interpreter = interpreter(module_);

    int first;
    interpreter.call(function_, &first, []);
    first.shouldEqual(20);

    int later;
    interpreter.call(function_, &later, []);
    later.shouldEqual(20);
}

// `~=` appending a single element lowers to `_d_arrayappendcTX`, dmd's
// own hook for growing a `T[]` by one element and writing it into the
// slot that growth made - `CatAssignExp.lowering` (`dmd/expression.d`),
// not a node any of `expression`'s own children reach.
static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("arrays.append.element." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        2.shouldBeRetOf!(
            backend,
            q{
                int second() {
                    int[] a = [1];
                    a ~= 2;
                    return a[1];
                }
            },
            "second",
        );
    }
}

static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("arrays.append.element.length." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        size_t(2).shouldBeRetOf!(
            backend,
            q{
                size_t length_() {
                    int[] a = [1];
                    a ~= 2;
                    return a.length;
                }
            },
            "length_",
        );
    }
}

// Appending one element at a time past the literal's own capacity forces
// at least one real reallocation - `_d_arrayappendcTX`'s own lowering
// asks the GC to grow the block in place first and only calls
// `GC.malloc` when that fails, so a loop long enough to outgrow the
// first block's capacity is what actually exercises the move, not just
// the append. Reading the first element back afterwards is what pins
// that the move copied the old contents rather than losing them.
static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("arrays.append.element.loop.survivesReallocation." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // a[0] == 100, a[1] == 101, a[50] == 150, a.length == 101.
        452.shouldBeRetOf!(
            backend,
            q{
                int grown() {
                    int[] a = [100];
                    foreach (i; 1 .. 101)
                        a ~= 100 + i;
                    return a[0] + a[1] + a[50] + cast(int) a.length;
                }
            },
            "grown",
        );
    }
}

// `~=` appending a whole slice lowers to `_d_arrayappendT` instead of
// `_d_arrayappendcTX` - a different hook, over the same `lowering` field,
// for a different `CatAssignExp.op` (`concatenateAssign` rather than
// `concatenateElemAssign`).
static foreach (backend; Matrix!(BytecodeUnconfirmed)) {
    @("arrays.append.slice." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // a[2] == 3, a.length == 3.
        303.shouldBeRetOf!(
            backend,
            q{
                int appended() {
                    int[] a = [1];
                    int[] b = [2, 3];
                    a ~= b;
                    return a[2] * 100 + cast(int) a.length;
                }
            },
            "appended",
        );
    }
}

// A `static` slice appended to on one call must still hold what an
// earlier call appended to it: the slice is one variable per program,
// not one per call, the same as `arrays.literal.static.outlivesFrame`
// pins for a literal assignment rather than an append.
@("arrays.append.static.acrossCalls.Interpreter")
@Tags("Interpreter")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        int accumulate() {
            static int[] arr;
            arr ~= arr.length ? 2 : 1;
            return arr.length == 1 ? arr[0] : arr[0] * 10 + arr[1];
        }
    });
    auto function_ = findFunction(module_, "accumulate");
    auto interpreter = interpreter(module_);

    int first;
    interpreter.call(function_, &first, []);
    first.shouldEqual(1);

    int second;
    interpreter.call(function_, &second, []);
    second.shouldEqual(12);
}
