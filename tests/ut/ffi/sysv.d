module ut.ffi.sysv;


import ut;
import snakebite.ffi.sysv: CallFrame, call;


// These tests hand-fill a `CallFrame` and drive `snakebite_ffi_call_
// sysv_amd64` directly, the way `snakebite.ffi.plan.CallPlan.callGeneric`
// will from step 2 of issue #334 onward. Nothing here goes through a
// `PlanCache` or a dmd `Type`: each test works out its callee's real
// System V AMD64 argument and return classification by hand, and states
// it in the callee's own declaration so the classification is checkable
// by inspection.
private size_t bitsOf(in double value) @trusted pure nothrow @nogc {
    return *cast(const size_t*) &value;
}


private int noArgumentsCalls;


private extern(C) void snakebite_ut_sysv_noop() {
    ++noArgumentsCalls;
}


@("noArguments")
unittest {
    noArgumentsCalls = 0;
    CallFrame frame;

    call(cast(const void*) &snakebite_ut_sysv_noop, frame);

    noArgumentsCalls.should == 1;
}


private extern(C) int snakebite_ut_sysv_addOne(int value) {
    return value + 1;
}


@("oneInt.returnsInt")
unittest {
    CallFrame frame;
    frame.integer[0] = 41;

    call(cast(const void*) &snakebite_ut_sysv_addOne, frame);

    (cast(int) frame.integerResult[0]).should == 42;
}


private extern(C) int snakebite_ut_sysv_sum6(
    int a, int b, int c, int d, int e, int f,
) {
    return a + b + c + d + e + f;
}


@("sixInts.allInRegisters")
unittest {
    CallFrame frame;
    frame.integer = [1, 2, 3, 4, 5, 6];

    call(cast(const void*) &snakebite_ut_sysv_sum6, frame);

    (cast(int) frame.integerResult[0]).should == 21;
}


private extern(C) int snakebite_ut_sysv_sum8(
    int a, int b, int c, int d, int e, int f, int g, int h,
) {
    return a + b + c + d + e + f + g + h;
}


@("eightInts.twoOnTheStack")
unittest {
    CallFrame frame;
    frame.integer = [1, 2, 3, 4, 5, 6];
    size_t[2] stack = [7, 8];
    frame.stack = stack.ptr;
    frame.stackWords = 2;

    call(cast(const void*) &snakebite_ut_sysv_sum8, frame);

    (cast(int) frame.integerResult[0]).should == 36;
}


private extern(C) double snakebite_ut_sysv_sum4d(
    double a, double b, double c, double d,
) {
    return a + b + c + d;
}


@("fourDoubles.allInRegisters")
unittest {
    CallFrame frame;
    frame.sse = [1.5, 2.5, 3.5, 4.5, 0, 0, 0, 0];
    frame.sseCount = 4;

    call(cast(const void*) &snakebite_ut_sysv_sum4d, frame);

    frame.sseResult[0].should == 12.0;
}


private extern(C) double snakebite_ut_sysv_sum10d(
    double a, double b, double c, double d, double e, double f, double g,
    double h, double i, double j,
) {
    return a + b + c + d + e + f + g + h + i + j;
}


@("tenDoubles.twoOnTheStack")
unittest {
    CallFrame frame;
    frame.sse = [1, 2, 3, 4, 5, 6, 7, 8];
    frame.sseCount = 8;
    size_t[2] stack = [bitsOf(9), bitsOf(10)];
    frame.stack = stack.ptr;
    frame.stackWords = 2;

    call(cast(const void*) &snakebite_ut_sysv_sum10d, frame);

    frame.sseResult[0].should == 55.0;
}


// One integer and one SSE argument both spill: `g` is the 7th integer
// argument, declared before the 9th SSE argument `x8`, so the stub must
// place `g` at stack word 0 and `x8` at stack word 1 - declaration order,
// not grouped by class. A stub that grouped them (as the class-grouped
// path in `snakebite.ffi.abi.invoke` currently must refuse to, since it
// cannot recover the interleaving) would hand the callee `x8`'s bits
// where it expects `g`'s, and vice versa.
private extern(C) double snakebite_ut_sysv_mixedStack(
    int a, int b, int c, int d, int e, int f,
    double x0, double x1, double x2, double x3, double x4, double x5,
    double x6, double x7,
    int g,
    double x8,
) {
    return a + b + c + d + e + f + g
        + x0 + x1 + x2 + x3 + x4 + x5 + x6 + x7 + x8;
}


@("mixedIntsAndDoubles.stackWordsInDeclarationOrder")
unittest {
    CallFrame frame;
    frame.integer = [1, 2, 3, 4, 5, 6];
    frame.sse = [10, 20, 30, 40, 50, 60, 70, 80];
    frame.sseCount = 8;
    size_t[2] stack = [7, bitsOf(90)];
    frame.stack = stack.ptr;
    frame.stackWords = 2;

    call(cast(const void*) &snakebite_ut_sysv_mixedStack, frame);

    // (1+..+7) + (10+..+80) + 90 = 28 + 360 + 90
    frame.sseResult[0].should == 478.0;
}


private extern(C) void* snakebite_ut_sysv_identityPointer(void* value) {
    return value;
}


@("returnPointer")
unittest {
    int probe = 17;
    CallFrame frame;
    frame.integer[0] = cast(size_t) &probe;

    call(cast(const void*) &snakebite_ut_sysv_identityPointer, frame);

    frame.integerResult[0].should == cast(size_t) &probe;
}


// Two `long` fields: both eightbytes classify INTEGER, so the ABI
// returns the struct in `%rax:%rdx` with no hidden pointer.
private struct TwoWordStruct {
    long first;
    long second;
}


private extern(C) TwoWordStruct snakebite_ut_sysv_twoWordStruct(
    long a, long b,
) {
    return TwoWordStruct(a, b);
}


@("returnTwoWordStruct.raxRdx")
unittest {
    CallFrame frame;
    frame.integer[0] = 17;
    frame.integer[1] = 31;

    call(cast(const void*) &snakebite_ut_sysv_twoWordStruct, frame);

    frame.integerResult[0].should == 17;
    frame.integerResult[1].should == 31;
}


// Two `double` fields: both eightbytes classify SSE, so the ABI returns
// the struct in `%xmm0:%xmm1`.
private struct TwoDoubleStruct {
    double first;
    double second;
}


private extern(C) TwoDoubleStruct snakebite_ut_sysv_twoDoubleStruct(
    double a, double b,
) {
    return TwoDoubleStruct(a, b);
}


@("returnTwoDoubles.xmm0Xmm1")
unittest {
    CallFrame frame;
    frame.sse[0] = 1.25;
    frame.sse[1] = 2.75;
    frame.sseCount = 2;

    call(cast(const void*) &snakebite_ut_sysv_twoDoubleStruct, frame);

    frame.sseResult[0].should == 1.25;
    frame.sseResult[1].should == 2.75;
}


// One `long` eightbyte (INTEGER) and one `double` eightbyte (SSE): the
// ABI returns the struct in `%rax:%xmm0` - each class keeps its own
// register count, so the SSE eightbyte lands in `%xmm0`, not `%xmm1`,
// even though it is the struct's second eightbyte.
private struct MixedStruct {
    long integer;
    double floating;
}


private extern(C) MixedStruct snakebite_ut_sysv_mixedStruct(
    long a, double b,
) {
    return MixedStruct(a, b);
}


@("returnMixedStruct.raxXmm0")
unittest {
    CallFrame frame;
    frame.integer[0] = 99;
    frame.sse[0] = 6.5;
    frame.sseCount = 1;

    call(cast(const void*) &snakebite_ut_sysv_mixedStruct, frame);

    frame.integerResult[0].should == 99;
    frame.sseResult[0].should == 6.5;
}


private extern(C) void snakebite_ut_sysv_throws() {
    throw new Exception("thrown across the barrier");
}


// Wrapped in a `@system`, void-returning function for the same reason
// `ut.framestack` wraps its own throwing calls: `shouldThrowWithMessage`
// evaluates its argument inside a `@safe` wrapper when it can, and
// nothing here needs to cross back out of it.
private void callThrows() @system {
    CallFrame frame;
    call(cast(const void*) &snakebite_ut_sysv_throws, frame);
}


// The whole point of the stub's `.cfi_` directives (ADR-0004): a
// `Throwable` raised by the callee has to unwind through this hand-written
// frame exactly as it would through a compiler-generated one. If the CFI
// were missing or wrong, this would terminate the process instead of
// landing in the `catch` below `shouldThrowWithMessage` drives.
@("exceptionUnwindsThroughTheStub")
unittest {
    callThrows.shouldThrowWithMessage("thrown across the barrier");
}


// `snprintf` is C's own variadic callee: its declared parameters are
// `char*, size_t, const char*`, all INTEGER class, so they fill
// `%rdi, %rsi, %rdx`. The format string's own `%d` and `%.1f` are read
// through `va_arg` from wherever the fixed arguments left off - the
// next INTEGER register (`%rcx`) for `%d`, and `%xmm0`, the first SSE
// register, for `%.1f`. `%al` has to report one SSE register used, or
// glibc's own variadic prologue skips saving `%xmm0` into its register
// save area and `%.1f` reads garbage instead.
@("variadicCallee.snprintf")
unittest {
    import core.stdc.stdio: snprintf;
    import std.string: fromStringz;

    char[64] buffer;
    immutable(char)[8] format = "%d %.1f\0";

    CallFrame frame;
    frame.integer[0] = cast(size_t) buffer.ptr;
    frame.integer[1] = buffer.length;
    frame.integer[2] = cast(size_t) format.ptr;
    frame.integer[3] = 7;
    frame.sse[0] = 3.5;
    frame.sseCount = 1;

    call(cast(const void*) &snprintf, frame);

    buffer.ptr.fromStringz.should == "7 3.5";
}


private extern(C) ubyte snakebite_ut_sysv_narrowUbyte(ubyte value) {
    return cast(ubyte) (value + 1);
}


private extern(C) short snakebite_ut_sysv_narrowShort(short value) {
    return cast(short) (value + 1);
}


// The upper bits of `%rax` are unspecified for a narrower-than-register
// return (ADR-0002's own reasoning for why the guest frame's return slot
// is always at least register width). Both values here wrap, so the
// assertion only passes if the read masks down to the return type's own
// width instead of trusting the rest of `integerResult[0]`.
@("narrowIntegralReturn.masksToTheReturnWidth")
unittest {
    CallFrame ubyteFrame;
    ubyteFrame.integer[0] = 255;
    call(cast(const void*) &snakebite_ut_sysv_narrowUbyte, ubyteFrame);
    (cast(ubyte) ubyteFrame.integerResult[0]).should == 0;

    CallFrame shortFrame;
    shortFrame.integer[0] = short.max;
    call(cast(const void*) &snakebite_ut_sysv_narrowShort, shortFrame);
    (cast(short) shortFrame.integerResult[0]).should == short.min;
}
