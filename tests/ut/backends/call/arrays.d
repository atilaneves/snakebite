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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

// Compiled D throws a `RangeError` for an index outside the array. The
// interpreter propagates that same exception to a host caller, while the
// test above catches it inside guest code.
@("arrays.index.outOfRange.propagates.RangeError.Interpreter")
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
    import core.exception: RangeError;

    interpreter(module_).call(function_, &result, [])
        .shouldThrow!RangeError;
}

// A `null` array is zero-length with a null pointer, so an index into it
// is out of range like any other. Reading it instead would dereference
// null and take down the host process, not the guest.
@("arrays.index.nullArray.propagates.RangeError.Interpreter")
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
    import core.exception: RangeError;

    interpreter(module_).call(function_, &result, [])
        .shouldThrow!RangeError;
}

// Bytecode does not yet have guest try/catch (see the `RangeError` test
// above, omitted for Bytecode), so an out-of-range index still escapes as
// the host-level `AssertError` a bounds check throws. That escape must
// carry its own site - the index expression's own message and source
// location - not a VM-internal array bounds violation and not some other
// assert site's message.
@("arrays.index.outOfRange.throws.attributedAssertError.Bytecode")
@Tags("Bytecode")
unittest {
    import core.exception: AssertError;
    import snakebite.backends.backend: Program;
    import snakebite.backends.bytecode: Bytecode;
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        int oob() {
            int[] a = [1, 2, 3];
            long i = 5;
            return a[i];
        }
    });
    auto function_ = findFunction(module_, "oob");
    auto instance = new Bytecode(Program([module_]));

    AssertError caught;
    int result;
    try
        instance.call(function_, &result, []);
    catch (AssertError error)
        caught = error;

    (caught !is null).should == true;
    caught.msg.should == "bytecode: index out of bounds: `cast(ulong)i`";
}

// The same bounds check, but with an unrelated assertion earlier in the
// same function - one that passes, so it never itself throws. The failure
// must still name the index expression, not the passing assertion's own
// message and line.
@("arrays.index.outOfRange.attributesToTheIndexNotAnUnrelatedAssert.Bytecode")
@Tags("Bytecode")
unittest {
    import core.exception: AssertError;
    import snakebite.backends.backend: Program;
    import snakebite.backends.bytecode: Bytecode;
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        int misattributed() {
            long x = 1;
            assert(x == 1);
            int[] a = [1];
            long i = 9;
            return a[i];
        }
    });
    auto function_ = findFunction(module_, "misattributed");
    auto instance = new Bytecode(Program([module_]));

    AssertError caught;
    int result;
    try
        instance.call(function_, &result, []);
    catch (AssertError error)
        caught = error;

    (caught !is null).should == true;
    caught.msg.should == "bytecode: index out of bounds: `cast(ulong)i`";
}

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
    @("arrays.literal.selfReferentialAssign." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        // `a = [a[1], a[0]]` evaluates its elements against `a`'s old
        // value. An implementation that writes the new length/pointer
        // into `a`'s slot before evaluating the elements would have each
        // element read back through the new, not-yet-initialised block.
        65.shouldBeRetOf!(
            backend,
            q{
                int flipped() {
                    int[] a = [5, 6];
                    a = [a[1], a[0]];
                    return a[0] * 10 + a[1];
                }
            },
            "flipped",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("arrays.literal.returnedThroughGuestCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        6.shouldBeRetOf!(
            backend,
            q{
                int[] make() {
                    return [1, 2, 3];
                }
                int total() {
                    int[] a = make();
                    return a[0] + a[1] + a[2];
                }
            },
            "total",
        );
    }
}

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
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

// `first`'s backing block is reachable only through a frame slot that
// outlives every one of the many further allocations the loop below makes -
// nothing else in the program still references it. A backend that does not
// root array storage a VM activation is the only thing pointing at would
// let the collector reclaim it once enough further allocation pressure
// makes a collection run, and the loop would then read back garbage instead
// of the values written before it started.
static foreach (backend; Matrix!()) {
    @("arrays.new.survivesFurtherAllocations." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        6.shouldBeRetOf!(
            backend,
            q{
                int survivesFurtherAllocations() {
                    int[] first = [1, 2, 3];

                    int[] junk = null;
                    for (int i = 0; i < 50_000; i = i + 1) {
                        junk = new int[](64);
                        junk[0] = i;
                    }

                    return first[0] + first[1] + first[2];
                }
            },
            "survivesFurtherAllocations",
        );
    }
}

static foreach (backend; Matrix!()) {
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

// A runtime `.length` assignment lowers to a native druntime call
// `_d_arraysetlengthT`. Writing and reading the last element proves that
// the runtime growth really happened.
static foreach (backend; Matrix!()) {
    @("arrays.length.runtime.ushort." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1_034.shouldBeRetOf!(
            backend,
            q{
                int growWords() {
                    ushort[] words;
                    words.length = 3;
                    words[2] = 1_031;
                    return cast(int) words.length + words[2];
                }
            },
            "growWords",
        );
    }
}

// Shrinking a runtime `.length` assignment keeps the surviving elements
// in place, unlike growth this only ever narrows the same allocation.
static foreach (backend; Matrix!()) {
    @("arrays.length.runtime.shrink." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        23.shouldBeRetOf!(
            backend,
            q{
                int shrinkWords() {
                    ushort[] words = [10, 11, 12, 13, 14];
                    words.length = 2;
                    return cast(int) words.length + words[0] + words[1];
                }
            },
            "shrinkWords",
        );
    }
}

// `arr.length = 0` is dmd's own optimised lowering for the general
// `.length` assignment (see `expressionsem.d`'s `visitAssign`), rewriting
// it to `arr = arr[0 .. 0]` rather than a call to
// `_d_arraysetlengthT` - a shape distinct enough from an ordinary shrink
// to need its own guest program.
static foreach (backend; Matrix!()) {
    @("arrays.length.runtime.toZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeRetOf!(
            backend,
            q{
                int clearWords() {
                    ushort[] words = [10, 11, 12];
                    words.length = 0;
                    return cast(int) words.length;
                }
            },
            "clearWords",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("arrays.slice.bounded.dynamicArray." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        350.shouldBeRetOf!(
            backend,
            q{
                int tail() {
                    int[] values = [10, 20, 30, 40];
                    size_t dataSize = 1;
                    int[] slice = values[dataSize .. $];
                    return cast(int) slice.length * 100 + slice[0] +
                        slice[1];
                }
            },
            "tail",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("arrays.slice.bounded.outOfBounds." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeStatusOf!(backend, q{
            void main() {
                int[] values = [10, 20, 30, 40];
                int[] invalid = values[3 .. 5];
                assert(invalid.length == 1);
            }
        });
    }
}

@("arrays.slice.bounded.boundsFailures.throwRangeError.Bytecode")
@Tags("Bytecode")
unittest {
    import core.exception: RangeError;
    import snakebite.backends.backend: Program;
    import snakebite.backends.bytecode: Bytecode;
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        int upperTooLarge() {
            int[] values = [10, 20, 30, 40];
            int[] invalid = values[3 .. 5];
            return cast(int) invalid.length;
        }

        int reversedBounds() {
            int[] values = [10, 20, 30, 40];
            size_t lower = 3;
            size_t upper = 2;
            int[] invalid = values[lower .. upper];
            return cast(int) invalid.length;
        }
    });
    auto instance = new Bytecode(Program([module_]));

    foreach (name; ["upperTooLarge", "reversedBounds"]) {
        auto function_ = findFunction(module_, name);
        RangeError caught;
        int result;
        try
            instance.call(function_, &result, []);
        catch (RangeError error)
            caught = error;

        (caught !is null).should == true;
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
    first.should == 20;

    int later;
    interpreter.call(function_, &later, []);
    later.should == 20;
}

// `~=` appending a single element lowers to `_d_arrayappendcTX`, dmd's
// own hook for growing a `T[]` by one element and writing it into the
// slot that growth made - `CatAssignExp.lowering` (`dmd/expression.d`),
// not a node any of `expression`'s own children reach.
static foreach (backend; Matrix!()) {
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

@("arrays.append.elementThroughIndexedSlice.Bytecode")
@Tags("Bytecode")
unittest {
    2.shouldBeRetOf!(Bytecode, q{
        int appended() {
            int[] inner = [1];
            int[][] arrays;
            arrays ~= inner;
            arrays[0] ~= 2;
            return arrays[0][1];
        }
    }, "appended");
}

static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!()) {
    @("arrays.append.dynamicArrayElement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        size_t(7).shouldBeRetOf!(
            backend,
            q{
                size_t messageLength() {
                    string[] messages;
                    messages ~= "failure";
                    return messages[0].length;
                }
            },
            "messageLength",
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
static foreach (backend; Matrix!()) {
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

// Native D raises a range error when a dynamic slice assignment's source
// and destination overlap: an ordinary forward copy would silently
// corrupt the already-written overlap region. Not a pointer-element-only
// case: an integral element must be checked the same way.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "the bytecode compiler does not check a slice assignment's source "
            ~ "and destination for overlap"),
    Omit!(Interpreter, Because.unconfirmed,
        "the interpreter does not check a slice assignment's source and "
            ~ "destination for overlap"),
)) {
    @("arrays.slice.overlappingAssignRaises." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeStatusOf!(backend, q{
            void main() {
                int[3] storage = [1, 2, 3];
                int* p = storage.ptr;
                int[] src = p[0 .. 2];
                int[] dst = p[1 .. 3];
                dst[] = src[];
                assert(storage[1] == 1);
                assert(storage[2] == 2);
            }
        });
    }
}

// `~=` appending a whole slice lowers to `_d_arrayappendT` instead of
// `_d_arrayappendcTX` - a different hook, over the same `lowering` field,
// for a different `CatAssignExp.op` (`concatenateAssign` rather than
// `concatenateElemAssign`).
static foreach (backend; Matrix!()) {
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
    first.should == 1;

    int second;
    interpreter.call(function_, &second, []);
    second.should == 12;
}
