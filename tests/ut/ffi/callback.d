module ut.ffi.callback;


import ut;
import dmd.func: FuncDeclaration;
import snakebite.ffi.callback:
    CallbackBridge, CallbackCall, ChunkStrategy;
import snakebite.ffi.sysv:
    snakebite_ffi_callback_chunk, snakebite_ffi_callback_chunk_end;
import snakebite.ffi.plan: nativeSignatureOf;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;
import std.conv: text, to;


// These tests drive the callback pool (`snakebite.ffi.callback`, ADR-0003)
// with no backend behind it: a `CallbackBridge` whose handler is a plain
// host function that records what the pool unpacked and writes the
// result it is asked for. The guest side is only a body-less declaration
// with the signature under test, parsed so the bridge can classify it;
// the "guest function word" is any distinct pointer. Host code then calls
// the entry through a matching function pointer type, exactly as `qsort`
// or druntime would.


// What one callback delivered: the arguments the handler read, in the
// shape it read them, and the context word.
private struct Recorded {
    long[] integers;
    double[] doubles;
    real[] reals;
    void* context;
    // Set by the test before the call: whether the signature has a
    // hidden context. A raw handler has no layout to ask.
    bool expectsContext;
    size_t calls;
}


// A raw handler has no layout of its own, so the test says through
// `Recorded.expectsContext` whether `call.arguments[0]` is a hidden
// context or the first declared parameter. There is one argument list
// either way: a context, when there is one, is `arguments[0]`'s own
// address, not a separate field.
private extern(C) void recordIntOfInt(void* owner, CallbackCall* call) {
    auto recorded = cast(Recorded*) owner;
    ++recorded.calls;
    const first = recorded.expectsContext ? 1 : 0;
    recorded.context = recorded.expectsContext
        ? *cast(void**) call.arguments[0] : null;
    recorded.integers ~= *cast(const int*) call.arguments[first];
    *cast(int*) call.returnPlace = cast(int) (recorded.integers[$ - 1] * 2 + 1);
}


private struct Triple {
    long a;
    long b;
    long c;
}

private struct ContextValue {
    int value;
    int add(int x) { return value + x; }
}


private alias IntOfInt = extern(C) int function(int);
private alias DoubleOfMixed = extern(C) double function(double, long, float);
private alias RealOfReal = extern(C) real function(real);
private alias ReverseReal = extern(D) real function(long, real);
private alias TripleOfLong = extern(C) Triple function(long);
private alias LongOfEight = extern(C) long function(
    long, long, long, long, long, long, long, long);
private alias Vector4 = __vector(float[4]);
private alias Vector4OfVector4 = extern(C) Vector4 function(Vector4);
private alias CVariadicInt = extern(C) int function(int, ...);

private extern(C) void recordVector4(void*, CallbackCall* call) {
    import core.stdc.string: memcpy;
    memcpy(call.returnPlace, call.arguments[0], 16);
}

private extern(C) void recordCVariadicInt(void*, CallbackCall* call) {
    import core.stdc.stdarg: va_arg, va_list;

    auto args = cast(va_list) call.variadicCursor;
    *cast(int*) call.returnPlace =
        *cast(const int*) call.arguments[0] + va_arg!int(args);
}


private FuncDeclaration declarationOf(string code, string name) {
    auto module_ = parseSnippet(code);
    auto function_ = findFunction(module_, name);
    assert(function_ !is null, "No function `" ~ name ~ "` in the snippet");
    return function_;
}


// The registration a backend makes: the signature comes from the
// declaration.
private void registerFunction(
    CallbackBridge* bridge, const(void)* word, FuncDeclaration function_,
) {
    bridge.register(word, nativeSignatureOf(function_));
}


private const(void)* adjustedFunctionEntryOf(
    CallbackBridge* bridge, const(void)* word, FuncDeclaration function_,
    ptrdiff_t adjustment,
) {
    return bridge.adjustedEntryOf(
        word, nativeSignatureOf(function_), adjustment);
}


private bool inTemplateChunk(const(void)* entry) {
    return entry >= cast(const(void)*) &snakebite_ffi_callback_chunk
        && entry < cast(const(void)*) &snakebite_ffi_callback_chunk_end;
}

@("entry.vector4ArgumentAndReturn")
unittest {
    auto function_ = declarationOf(
        q{ extern(C) __vector(float[4]) echo(__vector(float[4]) x); },
        "echo",
    );
    auto bridge = new CallbackBridge(&recordVector4, null);
    int word;
    bridge.registerFunction(&word, function_);
    auto entry = cast(Vector4OfVector4) bridge.entryOf(&word);
    float[4] input = [1.0f, 2.0f, 3.0f, 4.0f];
    auto output = entry(cast(Vector4) input);
    (cast(float[4]) output).should == input;
}

@("entry.variadicC.integerRegister")
unittest {
    auto function_ = declarationOf(
        q{ extern(C) int addExtra(int x, ...); }, "addExtra");
    auto bridge = new CallbackBridge(&recordCVariadicInt, null);
    int word;
    bridge.registerFunction(&word, function_);
    auto entry = cast(CVariadicInt) bridge.entryOf(&word);

    entry(13, 29).should == 42;
}


// An entry from the template chunk: the pool's first chunk is the one
// linked into the binary, so the first entries this bridge asks for come
// from it, and calling one reaches the handler with the argument the
// host passed and hands the host the handler's result.
@("entry.intOfInt")
unittest {
    auto function_ = declarationOf(q{ extern(C) int twice(int x); }, "twice");
    Recorded recorded;
    auto bridge = new CallbackBridge(&recordIntOfInt, &recorded);
    int[5] words;
    bridge.registerFunction(&words[2], function_);

    auto entry = cast(IntOfInt) bridge.entryOf(&words[2]);
    (entry !is null).should == true;
    // The same word always maps to the same entry, and back.
    (bridge.entryOf(&words[2]) is cast(const(void)*) entry).should == true;
    (bridge.wordOf(entry) is cast(const(void)*) &words[2]).should == true;
    (bridge.entryOf(&recorded) is null).should == true;

    entry(20).should == 41;
    entry(-3).should == -5;

    recorded.calls.should == 2;
    recorded.integers.should == [20, -3];

    foreach (index; [4, 0]) {
        (bridge.entryOf(&words[index]) is null).should == true;
        bridge.registerFunction(&words[index], function_);
        auto added = cast(IntOfInt) bridge.entryOf(&words[index]);
        (added !is null).should == true;
        added(10).should == 21;
        (bridge.wordOf(added) is cast(const(void)*) &words[index]).should == true;
    }
    (bridge.entryOf(&words[1]) is null).should == true;
    (bridge.entryOf(&words[3]) is null).should == true;
}


private extern(C) void recordMixed(void* owner, CallbackCall* call) {
    auto recorded = cast(Recorded*) owner;
    ++recorded.calls;
    recorded.doubles ~= *cast(const double*) call.arguments[0];
    recorded.integers ~= *cast(const long*) call.arguments[1];
    recorded.doubles ~= *cast(const float*) call.arguments[2];
    *cast(double*) call.returnPlace =
        recorded.doubles[$ - 2] + recorded.integers[$ - 1]
        + recorded.doubles[$ - 1];
}


private extern(C) void recordReal(void* owner, CallbackCall* call) {
    auto recorded = cast(Recorded*) owner;
    ++recorded.calls;
    const value = *cast(const real*) call.arguments[0];
    recorded.reals ~= value;
    *cast(real*) call.returnPlace = value + real.epsilon;
}


private extern(C) void recordReverseReal(
    void* owner, CallbackCall* call,
) {
    auto recorded = cast(Recorded*) owner;
    ++recorded.calls;
    const integer = *cast(const long*) call.arguments[0];
    const value = *cast(const real*) call.arguments[1];
    recorded.integers ~= integer;
    recorded.reals ~= value;
    *cast(real*) call.returnPlace = value + integer;
}


// SSE-class arguments and an SSE-class result travel through the entry
// as their own registers, a `float` at its own four-byte width.
@("entry.sse")
unittest {
    auto function_ = declarationOf(
        q{ extern(C) double mixed(double a, long b, float c); }, "mixed");
    Recorded recorded;
    auto bridge = new CallbackBridge(&recordMixed, &recorded);
    int word;
    bridge.registerFunction(&word, function_);

    auto entry = cast(DoubleOfMixed) bridge.entryOf(&word);
    entry(1.5, 10, 0.25f).should == 11.75;

    recorded.doubles.should == [1.5, 0.25];
    recorded.integers.should == [10];
}


@("entry.scalarReal")
unittest {
    auto function_ = declarationOf(
        q{ extern(C) real realCallback(real value); }, "realCallback");
    Recorded recorded;
    auto bridge = new CallbackBridge(&recordReal, &recorded);
    int word;
    bridge.registerFunction(&word, function_);

    auto entry = cast(RealOfReal) bridge.entryOf(&word);
    const value = 1.0L + real.epsilon;
    entry(value).should == value + real.epsilon;

    recorded.calls.should == 1;
    recorded.reals.should == [value];
}


@("entry.scalarReal.reverseD")
unittest {
    auto function_ = declarationOf(q{
        extern(D) real reverseReal(long integer, real value);
    }, "reverseReal");
    Recorded recorded;
    auto bridge = new CallbackBridge(&recordReverseReal, &recorded);
    int word;
    bridge.registerFunction(&word, function_);

    auto entry = cast(ReverseReal) bridge.entryOf(&word);
    const value = 1.0L + real.epsilon;
    entry(3, value).should == value + 3;

    recorded.calls.should == 1;
    recorded.integers.should == [3];
    recorded.reals.should == [value];
}


private extern(C) void recordTriple(void* owner, CallbackCall* call) {
    auto recorded = cast(Recorded*) owner;
    ++recorded.calls;
    const seed = *cast(const long*) call.arguments[0];
    recorded.integers ~= seed;
    *cast(Triple*) call.returnPlace = Triple(seed, seed * 2, seed * 3);
}


// A MEMORY-class result travels through the hidden pointer the host
// passes in the first integer register: the handler writes straight into
// the host's own result storage, and the host reads it back from there.
@("entry.memoryReturn")
unittest {
    auto function_ = declarationOf(q{
        struct Triple { long a; long b; long c; }
        extern(C) Triple triple(long seed);
    }, "triple");
    Recorded recorded;
    auto bridge = new CallbackBridge(&recordTriple, &recorded);
    int word;
    bridge.registerFunction(&word, function_);

    auto entry = cast(TripleOfLong) bridge.entryOf(&word);
    entry(7).should == Triple(7, 14, 21);
    recorded.integers.should == [7];
}


private extern(C) void recordEight(void* owner, CallbackCall* call) {
    auto recorded = cast(Recorded*) owner;
    ++recorded.calls;
    long weighted;
    foreach (i, argument; call.arguments) {
        const value = *cast(const long*) argument;
        recorded.integers ~= value;
        weighted += (i + 1) * value;
    }
    *cast(long*) call.returnPlace = weighted;
}


// Eight integer arguments: six in registers and two on the host's stack,
// which the entry reaches through the caller's frame. Weighted by
// position, so a misplaced argument changes the answer.
@("entry.stackArguments")
unittest {
    auto function_ = declarationOf(q{
        extern(C) long eight(
            long a, long b, long c, long d, long e, long f, long g, long h);
    }, "eight");
    Recorded recorded;
    auto bridge = new CallbackBridge(&recordEight, &recorded);
    int word;
    bridge.registerFunction(&word, function_);

    auto entry = cast(LongOfEight) bridge.entryOf(&word);
    entry(1, 2, 3, 4, 5, 6, 7, 8).should == 204;
    recorded.integers.should == [1, 2, 3, 4, 5, 6, 7, 8];
}


// An `extern(D)` delegate: the host passes the context word first and,
// on dmd, the declared parameters in reverse register order. The entry
// keeps the context word untouched and hands it back with the arguments.
@("entry.delegateContext")
unittest {
    import snakebite.frontend.dmd.functions: findStruct;

    // A body, never run: dmd only gives a method its hidden `this`
    // declaration when it analyses a body, and the bridge classifies the
    // signature from that declaration.
    auto module_ = parseSnippet(q{
        struct Holder {
            int twice(int x) { return x; }
        }
    });
    auto function_ = findFunction(findStruct(module_, "Holder"), "twice");
    assert(function_ !is null, "No method `twice` in the snippet");
    Recorded recorded;
    recorded.expectsContext = true;
    auto bridge = new CallbackBridge(&recordIntOfInt, &recorded);
    int word;
    bridge.registerFunction(&word, function_);

    int delegate(int) callback;
    callback.funcptr = cast(int function(int)) bridge.entryOf(&word);
    int context;
    callback.ptr = &context;

    callback(4).should == 9;
    (recorded.context is &context).should == true;
    recorded.integers.should == [4];

    ubyte[32] object;
    callback.ptr = object.ptr + 16;
    callback.funcptr = cast(int function(int))
        bridge.adjustedFunctionEntryOf(&word, function_, -16);
    callback(5).should == 11;
    (recorded.context is object.ptr).should == true;
    (callback.ptr is object.ptr + 16).should == true;
    (bridge.adjustedFunctionEntryOf(&word, function_, -16)
        is cast(const(void)*) callback.funcptr).should == true;

    auto native = ContextValue(37);
    auto target = &native.add;
    callback.ptr = cast(ubyte*) target.ptr + 16;
    callback.funcptr = cast(int function(int)) bridge.adjustedFunctionEntryOf(
        cast(const(void)*) target.funcptr, function_, -16);
    callback(5).should == 42;
}


// Every chunk of a bridge is a copy of the template: `beginChunk` forces a
// fresh chunk made with the given strategy, so the entry reserved next lives
// outside the binary's own template bytes. The dual-mapping strategy is the
// fallback for a kernel that refuses to make written memory executable; a
// kernel that allows it never takes that path on its own, so this drives it
// directly.
static foreach (strategy; [ChunkStrategy.protect, ChunkStrategy.dualMapping]) {
    @("chunk." ~ text(strategy))
    unittest {
        auto function_ = declarationOf(
            q{ extern(C) int twice(int x); }, "twice");
        Recorded recorded;
        auto bridge = new CallbackBridge(&recordIntOfInt, &recorded);
        int word;
        bridge.registerFunction(&word, function_);

        const chunksBefore = bridge.chunkCount;
        bridge.beginChunk(strategy);
        bridge.chunkCount.should == chunksBefore + 1;

        auto entry = cast(IntOfInt) bridge.entryOf(&word);
        inTemplateChunk(entry).should == false;

        entry(100).should == 201;
        recorded.integers.should == [100];
    }
}


// A released bridge gives back its chunks: it has none left, however many it
// had. That every chunk is also unmapped is measured on the whole process in
// `bin/at` (`at.runtime.registration`), where no other thread maps memory.
static foreach (strategy; [ChunkStrategy.protect, ChunkStrategy.dualMapping]) {
    @("release.givesBackChunks." ~ text(strategy))
    unittest {
        auto function_ = declarationOf(
            q{ extern(C) int twice(int x); }, "twice");
        int word;
        Recorded recorded;

        auto bridge = new CallbackBridge(&recordIntOfInt, &recorded);
        bridge.register(&word, nativeSignatureOf(function_));
        auto entry = cast(IntOfInt) bridge.entryOf(&word);
        bridge.beginChunk(strategy);
        bridge.chunkCount.should == 2;
        entry(3).should == 7;

        bridge.release;

        bridge.chunkCount.should == 0;
    }
}


// `guestTarget` answers for the entries of its own bridge only: another
// bridge, with its own table of guest functions, gets nothing for an address
// that is not its entry, whichever chunk the entry is in.
static foreach (freshChunk; [false, true]) {
    @("guestTarget.otherBridgeGetsNothing." ~ text(freshChunk))
    unittest {
        auto function_ = declarationOf(
            q{ extern(C) int twice(int x); }, "twice");
        Recorded recorded;
        auto owner = new CallbackBridge(&recordIntOfInt, &recorded);
        auto other = new CallbackBridge(&recordIntOfInt, &recorded);
        int word;
        owner.registerFunction(&word, function_);
        if (freshChunk)
            owner.beginChunk(ChunkStrategy.protect);
        const entry = owner.entryOf(&word);

        owner.guestTarget(entry).word.should == &word;
        other.guestTarget(entry).word.should == null;
    }
}


// A bridge that took the place of a released one, at the same address, does
// not find the released bridge's functions behind entries that nobody has
// reserved again.
static foreach (freshChunk; [false, true]) {
    @("guestTarget.releasedEntryNamesNothing." ~ text(freshChunk))
    unittest {
        auto function_ = declarationOf(
            q{ extern(C) int twice(int x); }, "twice");
        Recorded recorded;
        auto bridge = new CallbackBridge(&recordIntOfInt, &recorded);
        int word;
        bridge.registerFunction(&word, function_);
        if (freshChunk)
            bridge.beginChunk(ChunkStrategy.protect);
        const entry = bridge.entryOf(&word);
        bridge.guestTarget(entry).word.should == &word;

        bridge.release;
        *bridge = CallbackBridge(&recordIntOfInt, &recorded);

        bridge.guestTarget(entry).word.should == null;
    }
}


// A bridge that has more chunks than its reserved address range holds still
// names the guest function behind an entry of a chunk outside the range.
@("guestTarget.chunkOutsideTheRange")
unittest {
    auto function_ = declarationOf(
        q{ extern(C) int twice(int x); }, "twice");
    Recorded recorded;
    auto bridge = new CallbackBridge(&recordIntOfInt, &recorded);
    int word;
    bridge.register(&word, nativeSignatureOf(function_));
    foreach (_; 0 .. 300)
        bridge.beginChunk(ChunkStrategy.protect);

    const entry = bridge.entryOf(&word);

    bridge.guestTarget(entry).word.should == &word;
    (cast(IntOfInt) entry)(100).should == 201;
}


// An entry that adjusts the receiver names its target together with the
// adjustment, so a guest call through it passes the adjusted receiver on.
static foreach (freshChunk; [false, true]) {
    @("guestTarget.adjustedEntryNamesItsAdjustment." ~ text(freshChunk))
    unittest {
        import snakebite.frontend.dmd.functions: findStruct;

        auto module_ = parseSnippet(q{
            struct Holder {
                int twice(int x) { return x; }
            }
        });
        auto function_ = findFunction(findStruct(module_, "Holder"), "twice");
        assert(function_ !is null, "No method `twice` in the snippet");
        Recorded recorded;
        auto bridge = new CallbackBridge(&recordIntOfInt, &recorded);
        int word;
        bridge.registerFunction(&word, function_);
        if (freshChunk)
            bridge.beginChunk(ChunkStrategy.protect);

        const entry = bridge.adjustedFunctionEntryOf(&word, function_, -16);

        const target = bridge.guestTarget(entry);
        target.word.should == &word;
        target.adjustment.should == -16;
    }
}
