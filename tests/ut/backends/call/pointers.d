module ut.backends.call.pointers;


import ut.backends;
import snakebite.backends.backend: Program;
import snakebite.ffi.sysv: callbackEntriesPerChunk;
import snakebite.frontend.compiler: parseSnippets;
import snakebite.frontend.dmd.functions: findFunction;


static foreach (backend; Matrix!()) {
    @("pointers.classReference.dereference." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            class Value { int number = 42; }
            void main() {
                auto value = new Value;
                auto pointer = &value;
                assert(*pointer is value);
                assert((*pointer).number == 42);
                value = null;
                assert(*pointer is null);
            }
        });
    }
}


private alias BoolCallback = extern(D) bool function();


public extern(C) bool snakebite_ut_call_bool_callback(
    BoolCallback callback,
) {
    return callback();
}


private alias IntCallback = extern(D) int function();


public extern(C) int snakebite_ut_call_int_callback(IntCallback callback) {
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


public extern(C) bool snakebite_ut_call_bool_callback_on_thread(
    BoolCallback callback,
) {
    import core.thread: Thread;

    bool result;
    auto thread = new Thread({ result = callback(); });
    thread.start;
    thread.join;
    return result;
}


private alias IntOfIntDelegate = extern(D) int delegate(int);
private alias IntDelegate = extern(D) int delegate();
private alias VoidDelegate = extern(D) void delegate();


// `threads` host threads call `callback` `rounds` times each, at the same
// time, with a distinct argument per call, and the results are summed.
public extern(C) long snakebite_ut_sum_on_threads(
    IntOfIntDelegate callback, int threads, int rounds,
) {
    import core.thread: Thread;
    import std.algorithm: sum;

    auto sums = new long[threads];
    Thread worker(int index) {
        return new Thread({
            foreach (round; 0 .. rounds)
                sums[index] += callback(index * rounds + round);
        });
    }

    Thread[] workers;
    foreach (index; 0 .. threads)
        workers ~= worker(index);
    foreach (thread; workers)
        thread.start;
    foreach (thread; workers)
        thread.join;
    return sums.sum;
}


// The message of the exception `callback` throws on a host thread, caught
// on that same thread by host code.
public extern(C) string snakebite_ut_message_on_thread(
    VoidDelegate callback,
) {
    import core.thread: Thread;

    string message = "no throw";
    auto thread = new Thread({
        try
            callback();
        catch (Exception exception)
            message = exception.msg;
    });
    thread.start;
    thread.join;
    return message;
}


private alias IntOfBoolDelegate = extern(D) int delegate(bool);

// Calls `callback(true)` and `callback(false)` on the same host thread,
// in that order, joining only after both: `true` throws and is caught
// on that thread, `false` does not, and this returns its result -
// whatever state a thrown-through worker leaves behind (finding 3.4)
// must still let that same worker make another call correctly.
public extern(C) int snakebite_ut_call_twice_on_same_thread_after_throw(
    IntOfBoolDelegate callback,
) {
    import core.thread: Thread;

    int result;
    auto thread = new Thread({
        try
            callback(true);
        catch (Exception exception) {}
        result = callback(false);
    });
    thread.start;
    thread.join;
    return result;
}


// Runs `callback` on a host thread and joins it: `Thread.join` throws
// what the callback threw, on the joining thread.
public extern(C) void snakebite_ut_join_thread(VoidDelegate callback) {
    import core.thread: Thread;

    auto thread = new Thread(callback);
    thread.start;
    thread.join;
}


public extern(C) int snakebite_ut_int_callback_on_thread(
    IntDelegate callback,
) {
    import core.thread: Thread;

    int result;
    auto thread = new Thread({ result = callback(); });
    thread.start;
    thread.join;
    return result;
}


private struct ForeignCall {
    IntDelegate callback;
    int result;
    Throwable thrown;
}

private extern(C) void* runForeign(void* argument) {
    auto call = cast(ForeignCall*) argument;
    try
        call.result = call.callback();
    catch (Throwable throwable)
        call.thrown = throwable;
    return null;
}

// Runs `callback` on a thread druntime does not know: one `pthread_create`
// made, the way a C library would. That thread's first guest entry
// attaches it to druntime (ADR-0006), so this holds the
// `ut.threadsync` gate open from before `pthread_create` until guest
// code confirms the attach is done by calling
// `snakebite_ut_signal_foreign_attached` (finding: the thread tests'
// own explicit collects raced this attach when tests ran together).
public extern(C) int snakebite_ut_int_callback_on_foreign_thread(
    IntDelegate callback,
) {
    import core.sys.posix.pthread: pthread_create, pthread_join, pthread_t;
    import ut.threadsync: beginForeignAttach, endForeignAttach;

    beginForeignAttach();
    auto call = new ForeignCall(callback);
    pthread_t thread;
    if (pthread_create(&thread, null, &runForeign, call) != 0) {
        endForeignAttach();
        throw new Exception("pthread_create failed");
    }
    pthread_join(thread, null);
    if (call.thrown !is null)
        throw call.thrown;
    return call.result;
}


// Called from guest code as the first statement after a foreign
// thread's first guest entry, once its attach (automatic or by hand)
// has finished, to close the `ut.threadsync` window
// `snakebite_ut_int_callback_on_foreign_thread` opened.
public extern(C) void snakebite_ut_signal_foreign_attached() {
    import ut.threadsync: endForeignAttach;

    endForeignAttach();
}


// A full collection, run on a thread other than the caller's. Gated
// through `ut.threadsync` so it never overlaps a foreign thread's
// attach, wherever in the process that attach is happening.
public extern(C) void snakebite_ut_collect_on_other_thread() {
    import core.memory: GC;
    import core.thread: Thread;
    import ut.threadsync: beginExplicitCollect, endExplicitCollect;

    beginExplicitCollect();
    scope(exit) endExplicitCollect();

    auto thread = new Thread({
        GC.collect;
        GC.minimize;
    });
    thread.start;
    thread.join;
}


private enum hostCallbackDeclarations = q{
    module ut.backends.call.pointers;

    alias BoolCallback = extern(D) bool function();

    extern(C) bool snakebite_ut_call_bool_callback(BoolCallback);
    alias IntCallback = extern(D) int function();
    extern(C) int snakebite_ut_call_int_callback(IntCallback);
    extern(C) bool snakebite_ut_same_bool_callback(
        BoolCallback, BoolCallback,
    );
    extern(C) bool snakebite_ut_collect_then_call_bool_callback(
        BoolCallback,
    );
    extern(C) bool snakebite_ut_call_bool_callback_on_thread(
        BoolCallback,
    );
    alias IntOfIntDelegate = extern(D) int delegate(int);
    alias IntDelegate = extern(D) int delegate();
    alias VoidDelegate = extern(D) void delegate();
    extern(C) long snakebite_ut_sum_on_threads(
        IntOfIntDelegate, int, int,
    );
    extern(C) string snakebite_ut_message_on_thread(VoidDelegate);
    alias IntOfBoolDelegate = extern(D) int delegate(bool);
    extern(C) int snakebite_ut_call_twice_on_same_thread_after_throw(
        IntOfBoolDelegate,
    );
    extern(C) void snakebite_ut_join_thread(VoidDelegate);
    extern(C) int snakebite_ut_int_callback_on_thread(IntDelegate);
    extern(C) int snakebite_ut_int_callback_on_foreign_thread(IntDelegate);
    extern(C) void snakebite_ut_signal_foreign_attached();
    extern(C) void snakebite_ut_collect_on_other_thread();
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
static foreach (backend; Matrix!()) {
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


static foreach (backend; Matrix!()) {
    @("pointers.dynamicArray.voidArrayToStructPointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Value { int number; }

            void[] storage(Value[] values, ref int calls) {
                ++calls;
                return values;
            }

            void main() {
                Value[] values = [Value(42), Value(7)];
                int calls;
                auto pointer = cast(Value*) storage(values, calls);
                assert(calls == 1);
                assert(pointer is values.ptr);
                assert(pointer[1].number == 7);
                pointer[0].number = 99;
                assert(values[0].number == 99);

                void[] empty = values[1 .. 1];
                assert(cast(Value*) empty is values.ptr + 1);
                void[] absent;
                assert(cast(Value*) absent is null);
            }
        });
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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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


private enum otherThreadCode = q{
    import ut.backends.call.pointers:
        snakebite_ut_call_bool_callback_on_thread;

    static bool yes() {
        return true;
    }

    bool answer() {
        return snakebite_ut_call_bool_callback_on_thread(&yes);
    }
};

// A callback from a host thread the backend never entered before works
// like it does in compiled D (ADR-0006): the thread gets its own guest
// state on its first entry.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't call host code"),
)) {
    @("pointers.functionPointer.boolCallback.otherThread." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        static if (is(backend == Native)) {
            mixin(otherThreadCode);
            answer().should == true;
        } else {
            auto modules = parseSnippets([
                "module bool_callback_thread_root;\n" ~ otherThreadCode,
                hostCallbackDeclarations,
            ]);
            auto function_ = findFunction(modules[0], "answer");
            auto backend_ = new backend(Program([modules[0]]));

            bool result;
            backend_.call(function_, &result, []);

            result.should == true;
        }
    }
}


// Several host threads call one guest delegate at the same time. Each
// call reads a captured variable, allocates, loops and calls another
// guest function, so the threads share every per-function answer the
// backend keeps while each runs on its own frames. The sum only comes
// out right when every call on every thread computed its own result.
private enum concurrentThreadsCode = q{
    import ut.backends.call.pointers: snakebite_ut_sum_on_threads;

    int total(int[] values) {
        int sum;
        foreach (value; values)
            sum += value;
        return sum;
    }

    long answer() {
        int base = 3;

        int work(int x) {
            auto values = new int[](x % 7 + 1);
            foreach (i, ref value; values)
                value = cast(int) i + base + x;
            return total(values);
        }

        return snakebite_ut_sum_on_threads(&work, 8, 500);
    }
};

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't call host code"),
)) {
    @("pointers.delegate.concurrentThreads." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        long expected;
        {
            mixin(concurrentThreadsCode);
            expected = answer();
        }

        static if (!is(backend == Native)) {
            auto modules = parseSnippets([
                "module concurrent_threads_root;\n" ~ concurrentThreadsCode,
                hostCallbackDeclarations,
            ]);
            auto function_ = findFunction(modules[0], "answer");
            auto backend_ = new backend(Program([modules[0]]));

            long result;
            backend_.call(function_, &result, []);

            result.should == expected;
        }
    }
}


// A guest exception thrown by a callback on a worker thread unwinds
// through that thread's host frames untouched (ADR-0004): the host code
// on the worker catches the guest's own `Exception`.
private enum throwOnThreadCode = q{
    import ut.backends.call.pointers: snakebite_ut_message_on_thread;

    string answer() {
        void boom() {
            throw new Exception("thrown on the worker");
        }

        return snakebite_ut_message_on_thread(&boom);
    }
};

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't call host code"),
)) {
    @("pointers.delegate.throwOnThread.hostCatches." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        static if (is(backend == Native)) {
            mixin(throwOnThreadCode);
            answer().should == "thrown on the worker";
        } else {
            auto modules = parseSnippets([
                "module throw_on_thread_root;\n" ~ throwOnThreadCode,
                hostCallbackDeclarations,
            ]);
            auto function_ = findFunction(modules[0], "answer");
            auto backend_ = new backend(Program([modules[0]]));

            string result;
            backend_.call(function_, &result, []);

            result.should == "thrown on the worker";
        }
    }
}


// State after a throw on a worker (finding 3.4): frame pops are RAII
// (`snakebite.framestack.FrameStack`), so a worker that a guest
// exception unwound through, caught by host code on that same worker,
// must still be able to make a normal call afterwards - the same
// worker's frame stack is left exactly as it was before the throwing
// call, not still holding frames the throw's unwind should have
// popped.
private enum throwThenCallSameThreadCode = q{
    import ut.backends.call.pointers:
        snakebite_ut_call_twice_on_same_thread_after_throw;

    int answer() {
        int callTwice(bool shouldThrow) {
            if (shouldThrow)
                throw new Exception("thrown on the worker");
            return 42;
        }

        return snakebite_ut_call_twice_on_same_thread_after_throw(
            &callTwice);
    }
};

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't call host code"),
)) {
    @("pointers.delegate.throwOnThread.sameWorkerCallsAgainAfterThrow."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        static if (is(backend == Native)) {
            mixin(throwThenCallSameThreadCode);
            answer().should == 42;
        } else {
            auto modules = parseSnippets([
                "module throw_then_call_same_thread_root;\n"
                    ~ throwThenCallSameThreadCode,
                hostCallbackDeclarations,
            ]);
            auto function_ = findFunction(modules[0], "answer");
            auto backend_ = new backend(Program([modules[0]]));

            int result;
            backend_.call(function_, &result, []);

            result.should == 42;
        }
    }
}


// The same guest exception, rethrown by `Thread.join` on the thread that
// started the worker, reaches the guest `catch` around the host call
// that started it.
private enum joinRethrowsCode = q{
    import ut.backends.call.pointers: snakebite_ut_join_thread;

    string answer() {
        void boom() {
            throw new Exception("thrown on the worker");
        }

        try
            snakebite_ut_join_thread(&boom);
        catch (Exception exception)
            return "caught: " ~ exception.msg;
        return "no throw";
    }
};

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't call host code"),
)) {
    @("pointers.delegate.throwOnThread.guestCatches." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        static if (is(backend == Native)) {
            mixin(joinRethrowsCode);
            answer().should == "caught: thrown on the worker";
        } else {
            auto modules = parseSnippets([
                "module join_rethrows_root;\n" ~ joinRethrowsCode,
                hostCallbackDeclarations,
            ]);
            auto function_ = findFunction(modules[0], "answer");
            auto backend_ = new backend(Program([modules[0]]));

            string result;
            backend_.call(function_, &result, []);

            result.should == "caught: thrown on the worker";
        }
    }
}


// A guest object allocated on a worker thread, held only in that
// thread's guest frame, survives a collection another thread runs
// (ADR-0005): the worker's frame stack is registered with the GC the
// same way the main thread's is.
private enum collectOnOtherThreadCode = q{
    import ut.backends.call.pointers:
        snakebite_ut_collect_on_other_thread,
        snakebite_ut_int_callback_on_thread;

    class Box {
        int value;
        this(int value) { this.value = value; }
    }

    int answer() {
        int work() {
            auto box = new Box(41);
            snakebite_ut_collect_on_other_thread();
            return box.value + 1;
        }

        return snakebite_ut_int_callback_on_thread(&work);
    }
};

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't call host code"),
)) {
    @("pointers.delegate.allocationSurvivesCollection." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        static if (is(backend == Native)) {
            mixin(collectOnOtherThreadCode);
            answer().should == 42;
        } else {
            auto modules = parseSnippets([
                "module collect_on_other_thread_root;\n"
                    ~ collectOnOtherThreadCode,
                hostCallbackDeclarations,
            ]);
            auto function_ = findFunction(modules[0], "answer");
            auto backend_ = new backend(Program([modules[0]]));

            int result;
            backend_.call(function_, &result, []);

            result.should == 42;
        }
    }
}


// The same, on a bare `pthread` druntime does not know: the backend
// attaches it to druntime on its first entry (ADR-0006), so the
// collection sees its stack too.
private enum collectOnForeignThreadCode = q{
    import ut.backends.call.pointers:
        snakebite_ut_collect_on_other_thread,
        snakebite_ut_int_callback_on_foreign_thread,
        snakebite_ut_signal_foreign_attached;

    class Box {
        int value;
        this(int value) { this.value = value; }
    }

    int answer() {
        int work() {
            // Attach is already done: guest code cannot run before
            // it. Say so before allocating, so the host side knows
            // it can now let an explicit collect elsewhere proceed.
            snakebite_ut_signal_foreign_attached();

            auto box = new Box(41);
            snakebite_ut_collect_on_other_thread();
            return box.value + 1;
        }

        return snakebite_ut_int_callback_on_foreign_thread(&work);
    }
};

// The native oracle for the same scenario cannot run `collectOnForeign
// ThreadCode` unchanged (finding 3.2): a backend attaches a bare
// `pthread` to druntime itself, on that thread's first entry
// (ADR-0006), but compiled D gives such a thread no such automatic
// entry - a caller across the barrier, here the raw `pthread` this
// test's own C-like helper starts, has to attach it itself before any
// D code on it allocates. This is that same attach, done by hand, so
// the oracle's expected answer (42) is still backed by compiled D
// rather than left unchecked.
private enum collectOnForeignThreadNativeCode = q{
    import ut.backends.call.pointers:
        snakebite_ut_collect_on_other_thread,
        snakebite_ut_int_callback_on_foreign_thread,
        snakebite_ut_signal_foreign_attached;
    import core.thread: thread_attachThis, thread_detachThis;

    class Box {
        int value;
        this(int value) { this.value = value; }
    }

    int answer() {
        int work() {
            thread_attachThis();
            scope(exit) thread_detachThis();

            // Say the attach is done before allocating, so the host
            // side knows it can now let an explicit collect elsewhere
            // proceed.
            snakebite_ut_signal_foreign_attached();

            auto box = new Box(41);
            snakebite_ut_collect_on_other_thread();
            return box.value + 1;
        }

        return snakebite_ut_int_callback_on_foreign_thread(&work);
    }
};

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't call host code"),
)) {
    @("pointers.delegate.allocationSurvivesCollection.foreignThread."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        static if (is(backend == Native)) {
            mixin(collectOnForeignThreadNativeCode);
            answer().should == 42;
        } else {
            auto modules = parseSnippets([
                "module collect_on_foreign_thread_root;\n"
                    ~ collectOnForeignThreadCode,
                hostCallbackDeclarations,
            ]);
            auto function_ = findFunction(modules[0], "answer");
            auto backend_ = new backend(Program([modules[0]]));

            int result;
            backend_.call(function_, &result, []);

            result.should == 42;
        }
    }
}


// A module-level variable with neither `shared` nor `__gshared` is
// thread-local, the same as in compiled D (finding 1.3): each thread
// gets its own copy, initialised from the init image on its first use
// on that thread. Two threads that each call `bumpTls` five times, at
// the same time, on no lock of their own, only ever see their own five
// increments starting from zero - 1+2+3+4+5 each - never the other
// thread's. A shared cell every thread raced on instead would lose
// updates to the unsynchronised `++`, so the sum would almost certainly
// come out below 30 (or, on the rare perfectly-serialised interleaving,
// as high as 55 - one thread's five running on top of the other's) -
// either way, essentially never exactly 30.
private enum tlsVariableCode = q{
    import ut.backends.call.pointers: snakebite_ut_sum_on_threads;

    static int counter;

    long answer() {
        int bumpTls(int ignored) {
            return ++counter;
        }

        return snakebite_ut_sum_on_threads(&bumpTls, 2, 5);
    }
};

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't call host code"),
)) {
    @("pointers.staticVariable.threadLocal.separateCopyPerThread."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        static if (is(backend == Native)) {
            mixin(tlsVariableCode);
            answer().should == 30;
        } else {
            auto modules = parseSnippets([
                "module tls_variable_root;\n" ~ tlsVariableCode,
                hostCallbackDeclarations,
            ]);
            auto function_ = findFunction(modules[0], "answer");
            auto backend_ = new backend(Program([modules[0]]));

            long result;
            backend_.call(function_, &result, []);

            result.should == 30;
        }
    }
}


// `__gshared` (and, the same way, `shared`) keeps one copy for every
// thread, the same as in compiled D: three host threads, one after
// another (each joined before the next starts, so this never races),
// each call `bumpShared` once and see the previous thread's increment,
// not a fresh copy of their own.
private enum gsharedVariableCode = q{
    import ut.backends.call.pointers: snakebite_ut_int_callback_on_thread;

    __gshared int counter;

    int answer() {
        int bumpShared() {
            return ++counter;
        }

        snakebite_ut_int_callback_on_thread(&bumpShared);
        snakebite_ut_int_callback_on_thread(&bumpShared);
        return snakebite_ut_int_callback_on_thread(&bumpShared);
    }
};

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't call host code"),
)) {
    @("pointers.staticVariable.gshared.oneCopySharedByEveryThread."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        static if (is(backend == Native)) {
            mixin(gsharedVariableCode);
            answer().should == 3;
        } else {
            auto modules = parseSnippets([
                "module gshared_variable_root;\n" ~ gsharedVariableCode,
                hostCallbackDeclarations,
            ]);
            auto function_ = findFunction(modules[0], "answer");
            auto backend_ = new backend(Program([modules[0]]));

            int result;
            backend_.call(function_, &result, []);

            result.should == 3;
        }
    }
}


// ADR-0006's first test (finding 3.1, partial): a real task pool -
// `std.parallelism`'s, the same kind unit-threaded's own runner uses,
// with no single-threaded setting anywhere - calls many distinct guest
// functions of the one backend at once, none compiled yet. Two workers
// reaching a cold `Program.call` for two different functions at the
// same time is exactly the race finding 1.2 is about; a wrong answer
// (not only a crash) is how a corrupted compile would show up here,
// the same as in `ut.backends.bytecode.concurrency` (`@HiddenTest`
// there; this one is not, and stays small enough that it need not be).
private enum parallelismFunctionCount = 24;

// Just the functions, shared between the guest snippet (prefixed with
// its own `module` line below) and the native oracle (`mixin`ed
// straight into the unittest body, CTFE-evaluated, since this is a
// runtime `string`-returning function, not a `q{}` literal).
private string parallelismFunctionsSource() {
    import std.conv: text;

    string source;
    foreach (i; 0 .. parallelismFunctionCount)
        source ~= text(
            "long test", i, "() { long sum; ",
            "foreach (j; 0 .. ", i, " + 1) sum += j; return sum; }\n",
        );
    return source;
}

// `&test0`, `&test1`, ...: nested functions that capture nothing become
// plain function pointers, not delegates (unlike a captured nested
// function elsewhere in this module), so `auto` picks that up rather
// than a hardcoded delegate type.
private string parallelismFunctionArraySource() {
    import std.conv: text;

    string source = "auto parallelismTestFunctions = [";
    foreach (i; 0 .. parallelismFunctionCount)
        source ~= text("&test", i, ", ");
    return source ~ "];\n";
}

private long expectedParallelismResult(in size_t index) {
    return index * (index + 1) / 2;
}

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE has no notion of a call from any thread but the one " ~
        "that owns its interpreter state"),
)) {
    @("pointers.parallelism.taskPoolCallsManyGuestFunctionsAtOnce."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        import std.algorithm: equal, map;
        import std.parallelism: taskPool;
        import std.range: iota;

        static if (is(backend == Native)) {
            mixin(parallelismFunctionsSource);
            mixin(parallelismFunctionArraySource);

            // `amap!fun` is a member of `TaskPool` (so it already needs
            // `this`); a `fun` that also closes over this unittest's own
            // frame gives it a second context, which DMD 2.108+
            // deprecates ("requires a dual-context"). A `static` nested
            // function takes no frame of its own, so it costs `amap`
            // only the one context it already needs; `__gshared` is what
            // lets a worker thread, not this one, read it.
            __gshared typeof(parallelismTestFunctions)
                sharedParallelismTestFunctions;
            sharedParallelismTestFunctions = parallelismTestFunctions;

            static long callParallelismTestFunction(size_t i) {
                return sharedParallelismTestFunctions[i]();
            }

            auto results = taskPool.amap!callParallelismTestFunction(
                parallelismFunctionCount.iota);
        } else {
            auto modules = parseSnippets([
                "module ut.backends.call.parallelism_guest;\n"
                    ~ parallelismFunctionsSource,
            ]);
            auto functions = new typeof(findFunction(modules[0], "test0"))[
                parallelismFunctionCount];
            foreach (i; 0 .. parallelismFunctionCount) {
                import std.conv: text;

                functions[i] = findFunction(modules[0], text("test", i));
            }
            auto backend_ = new backend(Program([modules[0]]));

            // Same reasoning as the `Native` branch above.
            __gshared typeof(functions) sharedParallelismFunctions;
            sharedParallelismFunctions = functions;
            __gshared backend sharedParallelismBackend;
            sharedParallelismBackend = backend_;

            static long callGuestParallelismFunction(size_t i) {
                long result;
                sharedParallelismBackend.call(
                    sharedParallelismFunctions[i], &result, []);
                return result;
            }

            auto results = taskPool.amap!callGuestParallelismFunction(
                parallelismFunctionCount.iota);
        }

        results.equal(
            parallelismFunctionCount.iota.map!expectedParallelismResult,
        ).should == true;
    }
}


// The pool grows on demand: more distinct guest functions than one chunk
// of entries holds all get a working entry, and the ones past the first
// chunk's capacity are reached through a chunk the pool copied from its
// template at run time (ADR-0003). Each function returns its own number
// so a wrong entry would change the sum.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't call host code"),
)) {
    @("pointers.functionPointer.poolGrowth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        import snakebite.ffi.callback: callbackChunkCount;
        import std.conv: text;
        import std.range: iota;
        import std.algorithm: map, sum;
        import std.array: join;

        enum count = callbackEntriesPerChunk + 2;
        const functions = count.iota
            .map!(i => text("static int f", i, "() { return ", i, "; }"))
            .join("\n");
        const calls = count.iota
            .map!(i => text("sum += snakebite_ut_call_int_callback(&f", i,
                ");"))
            .join("\n");
        const code = "import ut.backends.call.pointers: "
            ~ "snakebite_ut_call_int_callback;\n"
            ~ functions
            ~ "\nint answer() { int sum;\n" ~ calls ~ "\nreturn sum; }";
        enum expected = count * (count - 1) / 2;

        static if (is(backend == Native))
            expected.shouldBeRetOf!(backend, code, "answer");
        else {
            auto modules = parseSnippets([
                "module pool_growth_root;\n" ~ code,
                hostCallbackDeclarations,
            ]);
            auto function_ = findFunction(modules[0], "answer");
            auto backend_ = new backend(Program([modules[0]]));

            int result;
            backend_.call(function_, &result, []);

            result.should == expected;
            callbackChunkCount.shouldBeGreaterThan(1);
        }
    }
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

// `p[0 .. n] = v` broadcasts a scalar into every element of a pointer
// slice, the same fill `staticArray.sliceScalarFill` already covers for a
// static array's own whole slice - but here the target has no
// compile-time element count, since a bare pointer carries no length of
// its own. This is the exact shape `core/internal/newaa.d`'s own
// `allocEntry` uses to zero a freshly allocated associative array entry's
// value: `(cast(ubyte*)&entry.value)[0 .. V.sizeof] = 0` when `V`'s own
// `.init` is not already all zero bits, so the entry's storage - carved
// out of a heap-allocated bucket - must be zeroed by hand instead.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed,
        "the ctfe backend cannot reinterpret-cast a `double*` to a " ~
            "`ubyte*`"),
)) {
    @("pointers.slice.scalarFill." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Holder {
                double value = 1.0;
            }

            void main() {
                auto holder = new Holder;
                auto bytes = (cast(ubyte*) &holder.value);
                bytes[0 .. double.sizeof] = 0;
                assert(holder.value == 0);
            }
        });
    }
}

// The fill's own start need not be the pointer's own first element: `p +
// 2` names the third element onward, so only elements at or past that
// offset are overwritten.
static foreach (backend; Matrix!(
)) {
    @("pointers.slice.scalarFill.nonZeroStart." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            void main() {
                int[5] storage = [1, 2, 3, 4, 5];
                int* p = storage.ptr;
                p[2 .. 5] = 9;
                assert(storage[0] == 1);
                assert(storage[1] == 2);
                assert(storage[2] == 9);
                assert(storage[3] == 9);
                assert(storage[4] == 9);
            }
        });
    }
}

// The same fill, run from inside a nested `@trusted` lambda called
// straight away - `core/internal/newaa.d`'s own `allocEntry` wraps its
// zero-fill in exactly this shape (`() @trusted { ... }();`) since the
// cast from a typed pointer to `ubyte*` is `@system` on its own.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed,
        "the ctfe backend cannot reinterpret-cast a `double*` to a " ~
            "`ubyte*`"),
)) {
    @("pointers.slice.scalarFill.trustedLambda." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Holder {
                double value = 1.0;
            }

            void main() {
                auto holder = new Holder;
                () @trusted {
                    (cast(ubyte*) &holder.value)[0 .. double.sizeof] = 0;
                }();
                assert(holder.value == 0);
            }
        });
    }
}

// A static array's whole-array assign and slice assign both copy a
// pointer element the same way they copy any other fixed-size element.
static foreach (backend; Matrix!(
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
// truncated to `ubyte` rather than `b`'s own 4-bit value, 5. Field access
// through a struct variable is not an lvalue `addressOf` handles yet, so the
// packed byte is built by hand - `a` (3) in the low nibble, `b` (5) in
// the high one, the same layout `S` itself packs `a`/`b` into - and read
// back through a `S*` a pointer cast produces.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot convert `&ubyte` to a packed struct pointer"),
)) {
    @("pointers.dotVar.bitfield." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        ubyte(5).shouldBeRetOf!(backend, q{
            struct S {
                ubyte a : 4;
                ubyte b : 4;
            }

            ubyte readB() {
                ubyte raw = 0x53;
                S* p = cast(S*) &raw;
                return p.b;
            }
        }, "readB");
    }
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

// A guest function pointer's own value is a backend stand-in - the
// `FuncDeclaration` itself in the interpreter, the compiled function in
// the bytecode compiler - that only the backend's own call path can
// resolve. Handed to genuinely native code through the FFI seam -
// `qsort`'s comparator argument here - it cannot leave as it is.
// `qsort` calls `compare` back through the pool entry the function
// pointer became at the barrier (ADR-0003): an `extern(C)` callback with
// two pointer parameters and an `int` result, nothing like the
// `extern(D) bool()` shape the pool once supported alone.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "Ctfe can't do this"),
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
                auto difference = (int a, int b) => a - b;
                int delegate(int) bound = (int x) => x + 2;
                assert(increment(4) == 5);
                assert(difference(11, 4) == 7);
                assert(bound(4) == 6);
                int invoke(bool delegate(byte, out int, double) fetch) {
                    int result;
                    assert(fetch(2, result, 40.0));
                    return result;
                }
                assert(invoke((byte first, out int value, double last) {
                    value = first + cast(int) last;
                    return true;
                }) == 42);
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
static foreach (backend; Matrix!()) {
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


// A non-zero `SymOffExp` offset must not change a `ref` parameter's own
// binding. Reading the parameter after taking the element address must still
// use the original array.
static foreach (backend; Matrix!()) {
    @("pointers.addressOf.staticArrayElement.refParameter."
        ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            int read(ref int[3] values) {
                int* second = &values[1];
                assert(*second == 20);
                assert(values[0] == 10);
                return values[1];
            }

            void main() {
                int[3] values = [10, 20, 30];
                assert(read(values) == 20);
            }
        });
    }
}


// `&s.get` on a struct method is dmd's `DelegateExp`: the delegate's context
// is the struct's own storage, so calling it through the pointer must see
// the same fields the struct held when the address was taken.
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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

static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.unconfirmed,
        "CTFE dispatches a delegate bound through super to the override"),
)) {
    @("pointers.addressOf.boundMethodDispatchAndMutation." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            interface View { int read(); }
            class Base : View {
                int value = 40;
                int read() { return value; }
            }
            class Derived : Base {
                override int read() { return value + 2; }
                int delegate() baseReader() { return &super.read; }
            }
            struct Counter {
                int value;
                int increment() { return ++value; }
            }
            void main() {
                auto object = new Derived;
                Base base = object;
                View view = object;
                int calls;
                Base receiver() { ++calls; return base; }
                auto read = &receiver().read;
                assert(calls == 1);
                assert(read() == 42);
                base = new Base;
                object.value = 50;
                assert(read() == 52);
                auto viaInterface = &view.read;
                assert(viaInterface() == 52);
                assert(object.baseReader()() == 50);
                Counter counter;
                auto increment = &counter.increment;
                assert(increment() == 1);
                assert(increment() == 2 && counter.value == 2);
            }
        });
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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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
static foreach (backend; Matrix!()) {
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


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot read the string literal terminator"),
)) {
    @("pointers.stringLiteralNativePointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            const(char)* choose(bool longer) {
                return longer ? "abc" : ".";
            }
            void main() {
                const(char)* narrow = "abc";
                const(wchar)* wide = "ab";
                const(dchar)* full = "abc";
                assert(narrow[0] == 'a' && narrow[2] == 'c');
                assert(wide[1] == 'b');
                assert(full[2] == 'c');
                assert(narrow[3] == 0 && wide[2] == 0 && full[3] == 0);
                assert(choose(false)[0] == '.');
                assert(choose(true)[2] == 'c');
            }
        });
    }
}


// dmd folds `cast(int*) 42` to an `IntegerExp` whose type is `int*`,
// the same encoding it uses for `null`. A non-zero value is a pointer
// with that address, not a layout the backend refuses.
static foreach (backend; Matrix!()) {
    @("pointers.integerLiteral.nonZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        42L.shouldBeRetOf!(
            backend,
            q{
                long address() {
                    int* ptr = cast(int*) 42;
                    return cast(long) ptr;
                }
            },
            "address",
        );
    }
}
