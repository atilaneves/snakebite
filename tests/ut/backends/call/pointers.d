module ut.backends.call.pointers;


import ut.backends;
import snakebite.backends.backend: Program;
import snakebite.ffi: boolFunctionEntryCount;
import snakebite.frontend.compiler: parseSnippets;
import snakebite.frontend.dmd.functions: findFunction;


private alias BoolCallback = extern(D) bool function();


public extern(C) bool snakebite_ut_call_bool_callback(
    BoolCallback callback,
) {
    return callback();
}


public extern(C) bool snakebite_ut_same_bool_callback(
    BoolCallback first,
    BoolCallback second,
) {
    return first == second;
}


public extern(C) bool snakebite_ut_is_null_object(Object object_)
{
    return object_ is null;
}


public extern(C) bool snakebite_ut_collect_then_call_bool_callback(
    BoolCallback callback,
) {
    import core.memory: GC;

    GC.collect;
    return callback();
}


public extern(C) string snakebite_ut_call_bool_callback_on_thread(
    BoolCallback callback,
) {
    import core.thread: Thread;

    string message;
    auto thread = new Thread({
        try
            callback();
        catch (Throwable throwable)
            message = throwable.msg;
    });
    thread.start;
    thread.join;
    return message;
}


private enum hostCallbackDeclarations = q{
    module ut.backends.call.pointers;

    alias BoolCallback = extern(D) bool function();

    extern(C) bool snakebite_ut_call_bool_callback(BoolCallback);
    extern(C) bool snakebite_ut_same_bool_callback(
        BoolCallback, BoolCallback,
    );
    extern(C) bool snakebite_ut_collect_then_call_bool_callback(
        BoolCallback,
    );
    extern(C) string snakebite_ut_call_bool_callback_on_thread(
        BoolCallback,
    );
};


private enum boolCallbackCode = q{
    import ut.backends.call.pointers:
        snakebite_ut_call_bool_callback,
        snakebite_ut_collect_then_call_bool_callback,
        snakebite_ut_same_bool_callback;

    static bool yes() {
        return true;
    }

    static bool no() {
        return false;
    }

    int answer() {
        assert(snakebite_ut_call_bool_callback(&yes));
        assert(!snakebite_ut_call_bool_callback(&no));
        assert(snakebite_ut_call_bool_callback(() => true));
        assert(snakebite_ut_same_bool_callback(&yes, &yes));
        assert(!snakebite_ut_same_bool_callback(&yes, &no));

        int[] values = [17, 31, 47];
        assert(snakebite_ut_collect_then_call_bool_callback(&yes));
        return values[0] + values[1] + values[2];
    }
};


private enum boolCallbackExceptionCode = q{
    import ut.backends.call.pointers: snakebite_ut_call_bool_callback;

    static int zero() {
        return 0;
    }

    static bool fail() {
        assert(zero());
        return false;
    }

    int answer() {
        snakebite_ut_call_bool_callback(&fail);
        return 0;
    }
};


// `new T` allocates storage with `T.init` before the program writes through
// the returned pointer. The integer checks its default state; a long uses a
// scalar initial value and the floating-point write proves no struct is needed.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "bytecode does not initialize a scalar `new` argument"),
)) {
    @("pointers.new.scalar." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                int answer() {
                    auto integer = new int;
                    auto parenthesized = new short();
                    auto initialized = new long(8);
                    auto floating = new double;
                    assert(*integer == int.init);
                    assert(*parenthesized == short.init);
                    assert(*initialized == 8);
                    *integer = 31;
                    *floating = 11.0;
                    assert(*floating == 11.0);
                    return *integer + 11;
                }
            },
            "answer",
        );
    }
}


// `&b` is dmd's `SymOffExp`, not a general `&expression`: taking a local's
// address and reading back through it is the simplest lvalue-to-pointer
// round trip there is.
static foreach (backend; Matrix!()) {
    @("pointers.addressOf.read." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        3.shouldBeRetOf!(
            backend,
            q{
                int deref() {
                    int b = 3;
                    int* p = &b;
                    return *p;
                }
            },
            "deref",
        );
    }
}


// Subtracting pointers gives the distance in elements, not bytes.
static foreach (backend; Matrix!()) {
    @("pointers.dynamicArray.pointerDifference." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        2L.shouldBeRetOf!(
            backend,
            q{
                long distance() {
                    ubyte[] arr = [1, 2, 3];
                    auto start = arr.ptr;
                    auto end = start + 2;
                    return end - start;
                }
            },
            "distance",
        );
    }
}


// `arr.ptr` and an explicit `cast(ubyte*) arr` both read a dynamic
// array's pointer word - the element size (one byte here) does not
// change which word that is.
static foreach (backend; Matrix!()) {
    @("pointers.dynamicArray.ubyteArrayToPointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        102.shouldBeRetOf!(
            backend,
            q{
                int sum() {
                    ubyte[] arr = [1, 2, 3];
                    ubyte* viaDotPtr = arr.ptr;
                    ubyte* viaCast = cast(ubyte*) arr;
                    return *viaDotPtr + *viaCast
                        + (viaDotPtr is viaCast ? 100 : 0);
                }
            },
            "sum",
        );
    }
}


// The same round trip as above, for an element wider than one byte -
// `cast(int*) arr` still reads the array's pointer word, not `arr[0]`'s
// address plus some byte offset.
static foreach (backend; Matrix!()) {
    @("pointers.dynamicArray.intArrayToPointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        120.shouldBeRetOf!(
            backend,
            q{
                int sum() {
                    int[] arr = [10, 20, 30];
                    int* viaDotPtr = arr.ptr;
                    int* viaCast = cast(int*) arr;
                    return *viaDotPtr + *viaCast
                        + (viaDotPtr is viaCast ? 100 : 0);
                }
            },
            "sum",
        );
    }
}


// Pointer subtraction divides by the pointee's own size, not always one
// byte: an `int*` difference of two elements is `2`, not `8` (the byte
// distance), whichever direction is later, so the sign follows too. The
// two pointers come from slicing a dynamic array into named variables
// first - the same shape `sliceOfSameArrayDifference` below uses - not
// `&arr[i]` on a static one, which is dmd's own `SymOffExp` with a
// non-zero offset, a separate, unconfirmed gap this compiler has for
// address-of a non-first static-array element, out of scope here.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "the interpreter divides a pointer difference by the wrong "
            ~ "stride once the pointee is wider than one byte"),
)) {
    @("pointers.intPointer.differenceBothSigns." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[] arr = [10, 20, 30, 40];
                int[] lowSlice = arr[1 .. $];
                int[] highSlice = arr[3 .. $];
                int* low = lowSlice.ptr;
                int* high = highSlice.ptr;
                assert(high - low == 2);
                assert(low - high == -2);
            }
        });
    }
}


// The same signed difference for a struct pointer, whose element size
// (two `int` fields, eight bytes) is neither one nor `size_t.sizeof`.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "the interpreter divides a pointer difference by the wrong "
            ~ "stride once the pointee is wider than one byte"),
)) {
    @("pointers.structPointer.differenceBothSigns." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Pair {
                int a;
                int b;
            }

            void main() {
                Pair[] arr = [Pair(1, 2), Pair(3, 4), Pair(5, 6), Pair(7, 8)];
                Pair[] lowSlice = arr[1 .. $];
                Pair[] highSlice = arr[3 .. $];
                Pair* low = lowSlice.ptr;
                Pair* high = highSlice.ptr;
                assert(high - low == 2);
                assert(low - high == -2);
            }
        });
    }
}


// Two slices of the same array share its allocation, so their `.ptr`
// words differ only by the element offset between where each slice
// starts - exactly what `_d_arrayshrinkfit` computes for a shrunk slice
// against the block `gc_getArrayUsed` still remembers as full length.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "the interpreter divides a pointer difference by the wrong "
            ~ "stride once the pointee is wider than one byte"),
)) {
    @("pointers.dynamicArray.sliceOfSameArrayDifference." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[] arr = [1, 2, 3, 4, 5];
                int[] low = arr[1 .. 3];
                int[] high = arr[3 .. 5];
                assert(high.ptr - low.ptr == 2);
            }
        });
    }
}


// The shape `cerealed` actually runs into: shrink a dynamic array down to
// an empty slice of its own allocation (`arr = arr[0 .. 0]`), then tell
// the runtime the rest of that allocation is free to reuse
// (`assumeSafeAppend`). `_d_arrayshrinkfit` reads that reuse back through
// `arr.ptr - curArr.ptr`, the pointer subtraction fixed above. Appending
// afterwards reuses the emptied slice's own start - the same address
// `arr[0 .. 0]` already pointed at - so the first byte becomes the newly
// appended one, not the one the empty slice let go of.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "`gc_getArrayUsed` has no CTFE-interpretable source"),
)) {
    @("pointers.dynamicArray.assumeSafeAppendAfterEmptySlice."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        9.shouldBeRetOf!(
            backend,
            q{
                int first() {
                    ubyte[] arr;
                    arr ~= 7;
                    arr ~= 8;
                    arr = arr[0 .. 0];
                    arr.assumeSafeAppend();
                    arr ~= 9;
                    return arr[0];
                }
            },
            "first",
        );
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot call host code"),
    Omit!(Interpreter, Because.unconfirmed,
        "pragma(mangle) native declarations are not routed through FFI"),
)) {
    @("pointers.null.classArgument." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeRetOf!(
            backend,
            q{
                pragma(mangle, "snakebite_ut_is_null_object")
                extern(C) bool nativeIsNullObject(Object);

                int isNull() {
                    return nativeIsNullObject(null);
                }
            },
            "isNull",
        );
    }
}


// A plain function pointer has no context word. When host code calls it, its
// code address alone must select the right guest function. Calling two
// functions proves the address does not select one process-global target;
// comparing a repeated conversion proves one guest function keeps one native
// identity. The collection happens while the outer guest frame holds the only
// remaining pointer to `values`, so reading the array afterward also proves
// that re-entry does not hide that frame from the collector.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't call host code"),
)) {
    @("pointers.functionPointer.boolCallback." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        static if (is(backend == Native))
            95.shouldBeRetOf!(backend, boolCallbackCode, "answer");
        else {
            auto modules = parseSnippets([
                "module bool_callback_root;\n" ~ boolCallbackCode,
                hostCallbackDeclarations,
            ]);
            auto function_ = findFunction(modules[0], "answer");
            auto backend_ = new backend(Program([modules[0]]));

            int result;
            backend_.call(function_, &result, []);

            result.should == 95;
        }
    }
}


// A guest throw remains a guest throw while it crosses the compiled helper's
// frame. `Backend.call` sees the original `AssertError`, not an FFI error or
// an interpreter implementation exception.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't call host code"),
)) {
    @("pointers.functionPointer.boolCallback.exception." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        import core.exception: AssertError;

        AssertError caught;
        static if (is(backend == Native)) {
            mixin(boolCallbackExceptionCode);
            try
                answer();
            catch (AssertError error)
                caught = error;
        } else {
            auto modules = parseSnippets([
                "module bool_callback_exception_root;\n"
                    ~ boolCallbackExceptionCode,
                hostCallbackDeclarations,
            ]);
            auto function_ = findFunction(modules[0], "answer");
            auto backend_ = new backend(Program([modules[0]]));

            int result;
            try
                backend_.call(function_, &result, []);
            catch (AssertError error)
                caught = error;
        }

        (caught !is null).should == true;
    }
}


// Worker-thread execution is owned by issue #40. The callback rejects the
// worker before it reads or writes the evaluator that its creator thread
// owns, so an unsupported call is a diagnostic instead of a data race.
@("pointers.functionPointer.boolCallback.wrongThread.Interpreter")
@Tags("Interpreter")
unittest {
    auto modules = parseSnippets([
        q{
            module bool_callback_thread_root;
            import ut.backends.call.pointers:
                snakebite_ut_call_bool_callback_on_thread;

            static bool yes() {
                return true;
            }

            bool rejected() {
                return snakebite_ut_call_bool_callback_on_thread(&yes) ==
                    "interpreter callback called on a thread that does not "
                    ~ "own its evaluator (see issue #40)";
            }
        },
        hostCallbackDeclarations,
    ]);
    auto function_ = findFunction(modules[0], "rejected");
    auto interpreter = new Interpreter(Program([modules[0]]));

    bool result;
    interpreter.call(function_, &result, []);

    result.should == true;
}


// Capacity belongs to the process, so the child runs without callback entries
// held by other parallel tests. Each evaluator reserves one entry. The 65th
// evaluator must fail clearly, then succeed after one owner is destroyed.
@("pointers.functionPointer.boolCallback.poolCapacity.Interpreter")
@Tags("Interpreter")
unittest {
    import std.file: thisExePath;
    import std.process: environment, execute;

    enum marker = "SNAKEBITE_CALLBACK_POOL_CAPACITY_CHILD";
    enum testName = "ut.backends.call.pointers.pointers.functionPointer."
        ~ "boolCallback.poolCapacity.Interpreter";
    if (environment.get(marker) is null) {
        auto childEnvironment = environment.toAA;
        childEnvironment[marker] = "1";
        const child = execute([thisExePath, testName], childEnvironment);
        assert(child.status == 0, child.output);
        return;
    }

    auto modules = parseSnippets([
        q{
            module bool_callback_capacity_root;
            import ut.backends.call.pointers:
                snakebite_ut_call_bool_callback;

            static bool yes() {
                return true;
            }

            bool call() {
                return snakebite_ut_call_bool_callback(&yes);
            }
        },
        hostCallbackDeclarations,
    ]);
    auto function_ = findFunction(modules[0], "call");
    auto program = Program([modules[0]]);
    Interpreter[boolFunctionEntryCount] interpreters;
    Interpreter overflow = new Interpreter(program);
    scope(exit) {
        foreach (instance; interpreters)
            if (instance !is null)
                destroy(instance);
        if (overflow !is null)
            destroy(overflow);
    }

    foreach (ref instance; interpreters) {
        instance = new Interpreter(program);
        bool result;
        instance.call(function_, &result, []);
        result.should == true;
    }

    bool result;
    const exhausted = overflow.call(function_, &result, []).shouldThrow;
    exhausted.msg.should == "ffi bool function callback pool is exhausted";

    destroy(interpreters[0]);
    interpreters[0] = null;
    overflow.call(function_, &result, []);
    result.should == true;
}


// Writing through the pointer changes the variable it points at, not a
// copy of it: `p` and `b` name the same storage.
static foreach (backend; Matrix!()) {
    @("pointers.write.throughPointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7.shouldBeRetOf!(
            backend,
            q{
                int write() {
                    int b = 3;
                    int* p = &b;
                    *p = 7;
                    return b;
                }
            },
            "write",
        );
    }
}

// `p[0 .. n] = q[]` copies element by element the same way any other
// dynamic slice assignment does, whether the element itself is an integral
// or, as here, a pointer: a pointer element is exactly as copyable in bulk
// as any other fixed-size value.
static foreach (backend; Matrix!()) {
    @("pointers.slice.pointerElementBulkAssign." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int a = 1;
                int b = 2;
                int c = 3;
                int d = 4;
                int*[4] storage = [&a, &b, &a, &b];
                int*[2] source = [&c, &d];
                int** ptr = storage.ptr;
                ptr[0 .. 2] = source[];
                assert(*storage[0] == 3);
                assert(*storage[1] == 4);
                assert(*storage[2] == 1);
                assert(*storage[3] == 2);
            }
        });
    }
}

// A static array's whole-array assign and slice assign both copy a
// pointer element the same way they copy any other fixed-size element.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "the interpreter cannot lay out a static array of pointers wider "
            ~ "than one machine word as a single native integral"),
    Omit!(Ctfe, Because.unconfirmed,
        "the ctfe backend cannot assign a static array of pointers"),
)) {
    @("pointers.slice.pointerElementStaticArrayAssign." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int a = 1;
                int b = 2;
                int*[2] src = [&a, &b];
                int*[2] dst;
                dst = src;
                dst[] = src[];
                assert(*dst[0] == 1);
                assert(*dst[1] == 2);
            }
        });
    }
}

// Native D raises a range error when a dynamic slice assignment's source
// and destination overlap, whatever the element type is: assigning through
// an ordinary forward copy would silently corrupt the already-written
// overlap region.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "the bytecode compiler does not check a slice assignment's source "
            ~ "and destination for overlap"),
    Omit!(Interpreter, Because.unconfirmed,
        "the interpreter does not check a slice assignment's source and "
            ~ "destination for overlap"),
)) {
    @("pointers.slice.overlappingAssignRaises." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeStatusOf!(backend, q{
            void main() {
                int a = 1;
                int b = 2;
                int c = 3;
                int*[3] storage = [&a, &b, &c];
                int** p = storage.ptr;
                int*[] src = p[0 .. 2];
                int*[] dst = p[1 .. 3];
                dst[] = src[];
                assert(*storage[1] == 1);
                assert(*storage[2] == 2);
            }
        });
    }
}

// A pointer argument carries the address a `&local` evaluated to, not a
// copy of the pointee: the callee writes through it and the caller's own
// local changes.
static foreach (backend; Matrix!()) {
    @("pointers.pass.writesCaller." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        9.shouldBeRetOf!(
            backend,
            q{
                void set(int* p) {
                    *p = 9;
                }

                int write() {
                    int b = 3;
                    set(&b);
                    return b;
                }
            },
            "write",
        );
    }
}

// A pointer argument also lets the callee hand a value back without a
// `return`, the read side of the same address the write tests exercise.
static foreach (backend; Matrix!()) {
    @("pointers.pass.readsCaller." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        4.shouldBeRetOf!(
            backend,
            q{
                int read(int* p) {
                    return *p + 1;
                }

                int call() {
                    int b = 3;
                    return read(&b);
                }
            },
            "call",
        );
    }
}

// `static` storage lives outside any frame - `&count` still answers the one
// address every call shares, so a write through the pointer is visible to
// a later read of `count` itself.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "dmd's CTFE interpreter refuses to take the address of a " ~
        "thread-local variable at compile time"),
)) {
    @("pointers.addressOf.static_." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        5.shouldBeRetOf!(
            backend,
            q{
                int bump() {
                    static int count = 1;
                    int* p = &count;
                    *p = *p + 4;
                    return count;
                }
            },
            "bump",
        );
    }
}

// `field.offset` in `visit(DotVarExp)` is read as a whole-byte offset. A
// bitfield is also a `VarDeclaration`, but its storage is a sub-byte
// slice of that byte - a plain `memcpy` from it reads the whole packed
// byte instead of masking and shifting out just the bitfield, so a
// memcpy-based read of `b` below would answer the packed byte `0x53`
// truncated to `ubyte` rather than `b`'s own 4-bit value, 5. Refused
// rather than run to that wrong answer. Field assignment through a
// struct variable is not an lvalue `addressOf` handles yet, so the
// packed byte is built by hand - `a` (3) in the low nibble, `b` (5) in
// the high one, the same layout `S` itself packs `a`/`b` into - and read
// back through a `S*` a pointer cast produces.
@("pointers.dotVar.bitfield.refused.Interpreter")
@Tags("Interpreter")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        struct S {
            ubyte a : 4;
            ubyte b : 4;
        }

        ubyte readB() {
            ubyte raw = 0x53;
            S* p = cast(S*) &raw;
            return p.b;
        }
    });
    auto function_ = findFunction(module_, "readB");

    ubyte result;
    interpreter(module_).call(function_, &result, [])
        .shouldThrowWithMessage(
            "interpreter cannot evaluate `(*p).b`: reading a bitfield is " ~
                "not supported");
}

// `&factorial` on a module-level function is dmd's `SymOffExp` too, the
// same node a local's address takes above - the difference is `var` names
// a `FuncDeclaration`, not a `VarDeclaration`, so there is no frame slot to
// find. The value it takes the address of is a plain function pointer (no
// context word), unlike `&nested` on a nested function, which dmd instead
// lowers to a `DelegateExp`. `factorial` is declared alongside `main`
// rather than nested inside it, the same way `shouldBeStatusOf` renders any
// top-level declaration, so its address is a plain function pointer both
// natively and in the guest.
static foreach (backend; Matrix!()) {
    @("pointers.functionPointer.moduleLevel.call." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            uint factorial(uint n) {
                return n <= 1 ? 1 : n * factorial(n - 1);
            }

            int main() {
                uint function(uint) fn = &factorial;
                assert(fn(5) == 120);
                return 0;
            }
        });
    }
}

// A function pointer is an ordinary value once taken: passing it into
// another function and calling it there reaches the same guest function as
// calling it directly would.
static foreach (backend; Matrix!()) {
    @("pointers.functionPointer.moduleLevel.passAsArgument." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            uint answer() {
                return 42;
            }

            uint invoke(uint function() fn) {
                return fn();
            }

            int main() {
                assert(invoke(&answer) == 42);
                return 0;
            }
        });
    }
}

// A guest function pointer travels as `visit(SymOffExp)`'s stand-in - the
// `FuncDeclaration` itself, since this backend has no machine code of its
// own for an interpreted function (see the comment there). That stand-in
// is only ever resolved back by this evaluator's own `calleeOf`, on a call
// this evaluator itself makes. Handed instead to genuinely native code
// through the FFI seam - `qsort`'s comparator argument here - the bits
// leave as an ordinary function pointer value and native code jumps to
// them directly.
//
// Native compiles `compare` to real machine code, so the same program runs
// correctly there: `qsort` calls it back and the array comes out sorted.
// The interpreter has no machine code to jump to, so it cannot let this
// reach `qsort` at all; that is pinned separately below, in
// `pointers.functionPointer.nativeCallback.refused.Interpreter`, since
// `shouldBeRetOf` cannot express "throws on this backend, succeeds on
// that one" in a single assertion.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
    Omit!(Interpreter, Because.diverges,
        "pinned in " ~
        "pointers.functionPointer.nativeCallback.refused.Interpreter: " ~
        "the callback's extern(C) int signature is outside the " ~
        "extern(D) bool signature supported by issue #168"),
    // `qsort` is reached and `xs` (a static array, now supported) is laid
    // out and sliced correctly, but `&compare`'s own callback bridge
    // (`guestFunctionPointer`/`supportsBoolFunction`) only accepts a
    // guest function returning `bool` - the same `extern(D) bool`
    // restriction issue #168 already names for `Interpreter` above.
    // `compare` returns `extern(C) int`, so this compiler refuses the
    // call before `qsort` ever runs, unrelated to static arrays.
    Omit!(Bytecode, Because.unconfirmed,
        "`&compare`'s signature is `extern(C) int(scope const void*, " ~
        "scope const void*)`, not the `bool()` callback this backend " ~
        "supports handing to native code"),
)) {
    @("pointers.functionPointer.nativeCallback." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeRetOf!(
            backend,
            q{
                extern(C) int compare(scope const void* a, scope const void* b) {
                    return *cast(const int*) a - *cast(const int*) b;
                }

                int answer() {
                    import core.stdc.stdlib: qsort;

                    int[3] xs = [3, 1, 2];
                    qsort(xs.ptr, xs.length, int.sizeof, &compare);
                    return xs[0];
                }
            },
            "answer",
        );
    }
}

// The sibling of the Matrix test above, for the one backend it could not
// express: the interpreter refuses to hand `qsort` a callback whose
// signature is not supported, with a message naming the signature and the
// remaining issue #9 work instead of letting the host call a declaration.
@("pointers.functionPointer.nativeCallback.refused.Interpreter")
@Tags("Interpreter")
unittest {
    import snakebite.frontend.compiler: parseSnippet;
    import snakebite.frontend.dmd.functions: findFunction;

    auto module_ = parseSnippet(q{
        extern(C) int compare(scope const void* a, scope const void* b) {
            return *cast(const int*) a - *cast(const int*) b;
        }

        int answer() {
            import core.stdc.stdlib: qsort;

            int[3] xs = [3, 1, 2];
            qsort(xs.ptr, xs.length, int.sizeof, &compare);
            return xs[0];
        }
    });
    auto function_ = findFunction(module_, "answer");

    int result;
    interpreter(module_).call(function_, &result, [])
        .shouldThrowWithMessage(
            "interpreter cannot call `qsort` with `compare` as a function " ~
                "pointer argument: callback signature `extern (C) " ~
                "int(scope const(void*) a, scope const(void*) b)` is not " ~
                "supported (see issue #9)");
}

// `FrameLayout.ofParameters` packs a `ref` parameter the same way
// `FrameLayout.of` does (both go through `packParameter`), so a call
// through a function pointer can hand a `ref` parameter its argument's
// address the same way a direct call does.
static foreach (backend; Matrix!()) {
    @("pointers.functionPointer.refParameter.call." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void increment(ref int x) {
                x = x + 1;
            }

            int main() {
                void function(ref int) fp = &increment;
                int v = 3;
                fp(v);
                assert(v == 4);
                return 0;
            }
        });
    }
}

// A lambda written without `function` or `delegate` and bound to `auto`
// keeps dmd's `TOK.reserved`: semantic proved it reads no enclosing local,
// so its type is a plain function pointer, but the context slot dmd
// declared while that was still undecided stays on the declaration. Calling
// through the pointer must still hand `x` to the slot the callee's own body
// reads it from.
static foreach (backend; Matrix!()) {
    @("pointers.functionPointer.inferredLambda.call." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int main() {
                auto increment = (int x) => x + 1;
                assert(increment(4) == 5);
                return 0;
            }
        });
    }
}

// A `ref` return hands back the returned storage's address, whatever the
// declared return type's own width is. Read through a function pointer,
// where only the pointer's `TypeFunction` says the return is `ref`, the
// value must still come from that address rather than from its bytes.
static foreach (backend; Matrix!()) {
    @("pointers.functionPointer.refReturn.read." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            ref int first(int[] a) {
                return a[0];
            }

            int main() {
                int[] xs = [7, 8];
                auto fp = &first;
                int v = fp(xs);
                assert(v == 7);
                return 0;
            }
        });
    }
}


// `&sarr[1]` is dmd's `SymOffExp` with a non-zero offset: the address is
// the array's own storage plus one element's width, not the array's start.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "bytecode compiler cannot compile `(& sarr + 4)` in `deref`"),
)) {
    @("pointers.addressOf.staticArrayElement." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        2.shouldBeRetOf!(
            backend,
            q{
                int deref() {
                    int[3] sarr = [1, 2, 3];
                    int* p = &sarr[1];
                    return *p;
                }
            },
            "deref",
        );
    }
}


// `&s.get` on a struct method is dmd's `DelegateExp`: the delegate's context
// is the struct's own storage, so calling it through the pointer must see
// the same fields the struct held when the address was taken.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "bytecode compiler cannot compile `&s.get` in `deref`"),
    Omit!(Interpreter, Because.unconfirmed,
        "interpreter cannot evaluate `&s.get`: its delegate declaration " ~
        "is unsupported"),
)) {
    @("pointers.addressOf.structMethod." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                struct S {
                    int value;
                    int get() { return value + 1; }
                }
                int deref() {
                    S s = S(41);
                    int delegate() dg = &s.get;
                    return dg();
                }
            },
            "deref",
        );
    }
}


// A pointee whose size is not a power of two: the byte distance between
// the two pointers (24 here) is still an exact multiple of the element
// size (12), so the element distance is exact in both directions.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "the interpreter divides a pointer difference by the wrong "
            ~ "stride once the pointee is wider than one byte"),
)) {
    @("pointers.structPointer.twelveByteStrideBothSigns." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Triple {
                int a;
                int b;
                int c;
            }

            void main() {
                Triple[] arr = [Triple(1, 2, 3), Triple(4, 5, 6),
                    Triple(7, 8, 9), Triple(10, 11, 12)];
                Triple[] lowSlice = arr[1 .. $];
                Triple[] highSlice = arr[3 .. $];
                Triple* low = lowSlice.ptr;
                Triple* high = highSlice.ptr;
                assert(high - low == 2);
                assert(low - high == -2);
            }
        });
    }
}


// `&c.get` on a class method is dmd's `DelegateExp` too, with the object
// reference as context instead of a struct's inline storage.
static foreach (backend; Matrix!(
    Omit!(Bytecode, Because.unconfirmed,
        "bytecode compiler cannot compile `&c.get` in `deref`"),
    Omit!(Interpreter, Because.unconfirmed,
        "interpreter cannot evaluate `&c.get`: its delegate declaration " ~
        "is unsupported"),
)) {
    @("pointers.addressOf.classMethod." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42.shouldBeRetOf!(
            backend,
            q{
                class C {
                    int value;
                    this(int v) { value = v; }
                    int get() { return value + 1; }
                }
                int deref() {
                    auto c = new C(41);
                    int delegate() dg = &c.get;
                    return dg();
                }
            },
            "deref",
        );
    }
}


// `void*` has a pointee size of one, so its difference is the plain byte
// distance, signed either way round.
static foreach (backend; Matrix!()) {
    @("pointers.voidPointer.differenceBothSigns." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[] arr = [1, 2, 3, 4];
                int[] lowSlice = arr[1 .. $];
                int[] highSlice = arr[3 .. $];
                void* low = lowSlice.ptr;
                void* high = highSlice.ptr;
                assert(high - low == 8);
                assert(low - high == -8);
            }
        });
    }
}


// The pointer operands' qualifiers do not change the difference: two
// `const(int)*` values (converted from mutable pointers) subtract like
// `int*` ones.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "the interpreter divides a pointer difference by the wrong "
            ~ "stride once the pointee is wider than one byte"),
)) {
    @("pointers.constPointer.differenceBothSigns." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[] arr = [1, 2, 3, 4];
                int[] lowSlice = arr[1 .. $];
                int[] highSlice = arr[3 .. $];
                int* lowMutable = lowSlice.ptr;
                int* highMutable = highSlice.ptr;
                const(int)* low = lowMutable;
                const(int)* high = highMutable;
                assert(high - low == 2);
                assert(low - high == -2);
            }
        });
    }
}


// A pointer difference is a signed integer, so a negative one compares
// below zero, and `p - p` is zero and therefore false as a condition.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "the interpreter divides a pointer difference by the wrong "
            ~ "stride once the pointee is wider than one byte"),
)) {
    @("pointers.pointerDifference.asCondition." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7.shouldBeRetOf!(
            backend,
            q{
                int f() {
                    int[] arr = [1, 2, 3, 4];
                    int[] lowSlice = arr[1 .. $];
                    int[] highSlice = arr[3 .. $];
                    int* low = lowSlice.ptr;
                    int* high = highSlice.ptr;
                    int r;
                    if (low - low) r += 100;
                    if (low - low == 0) r += 1;
                    if (low - high < 0) r += 2;
                    if (high - low > 0) r += 4;
                    if (low - high >= 0) r += 200;
                    return r;
                }
            },
            "f",
        );
    }
}


// The difference is a `ptrdiff_t` value like any other: it stores into a
// `long`, takes part in further arithmetic, converts to `size_t`, and
// narrows to `int` with its sign intact. An odd distance (three `long`
// elements) checks that the byte count divides exactly by the stride.
static foreach (backend; Matrix!(
    Omit!(Interpreter, Because.unconfirmed,
        "the interpreter divides a pointer difference by the wrong "
            ~ "stride once the pointee is wider than one byte"),
)) {
    @("pointers.pointerDifference.asInteger." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                long[] arr = [1, 2, 3, 4, 5];
                long[] lowSlice = arr[0 .. $];
                long[] highSlice = arr[3 .. $];
                long* low = lowSlice.ptr;
                long* high = highSlice.ptr;
                long d = low - high;
                assert(d == -3);
                ptrdiff_t e = (high - low) * 2 + 1;
                assert(e == 7);
                size_t u = high - low;
                assert(u == 3);
                int narrow = cast(int) (low - high);
                assert(narrow == -3);
            }
        });
    }
}
