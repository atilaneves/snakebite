module ut.ffi.callback;


import ut;
import dmd.func: FuncDeclaration;
import snakebite.ffi.callback:
    beginCallbackChunk, callbackChunkCount, CallbackBridge, CallbackCall,
    ChunkStrategy;
import snakebite.ffi.sysv:
    snakebite_ffi_callback_chunk, snakebite_ffi_callback_chunk_end;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;
import std.conv: text;


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
    void* context;
    bool hasContext;
    size_t calls;
}


// A raw handler has no layout of its own, only `call.declaration` - the
// same thing a real backend's `runHostToGuest` asks to decide whether
// `call.arguments[0]` is a hidden context or the first declared
// parameter. There is one argument list either way: a context, when
// there is one, is `arguments[0]`'s own address, not a separate field.
private extern(C) void recordIntOfInt(void* owner, CallbackCall* call) {
    import snakebite.frontend.dmd.delegates: hasHiddenThis;

    auto recorded = cast(Recorded*) owner;
    ++recorded.calls;
    recorded.hasContext = hasHiddenThis(call.declaration);
    const first = recorded.hasContext ? 1 : 0;
    recorded.context = recorded.hasContext
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
private alias TripleOfLong = extern(C) Triple function(long);
private alias LongOfEight = extern(C) long function(
    long, long, long, long, long, long, long, long);


private FuncDeclaration declarationOf(string code, string name) {
    auto module_ = parseSnippet(code);
    auto function_ = findFunction(module_, name);
    assert(function_ !is null, "No function `" ~ name ~ "` in the snippet");
    return function_;
}


private bool inTemplateChunk(const(void)* entry) {
    return entry >= cast(const(void)*) &snakebite_ffi_callback_chunk
        && entry < cast(const(void)*) &snakebite_ffi_callback_chunk_end;
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
    int word;
    bridge.register(&word, function_);

    auto entry = cast(IntOfInt) bridge.entryOf(&word);
    (entry !is null).should == true;
    // The same word always maps to the same entry, and back.
    (bridge.entryOf(&word) is cast(const(void)*) entry).should == true;
    (bridge.wordOf(entry) is cast(const(void)*) &word).should == true;
    (bridge.entryOf(&recorded) is null).should == true;

    entry(20).should == 41;
    entry(-3).should == -5;

    recorded.calls.should == 2;
    recorded.integers.should == [20, -3];
    recorded.hasContext.should == false;
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


// SSE-class arguments and an SSE-class result travel through the entry
// as their own registers, a `float` at its own four-byte width.
@("entry.sse")
unittest {
    auto function_ = declarationOf(
        q{ extern(C) double mixed(double a, long b, float c); }, "mixed");
    Recorded recorded;
    auto bridge = new CallbackBridge(&recordMixed, &recorded);
    int word;
    bridge.register(&word, function_);

    auto entry = cast(DoubleOfMixed) bridge.entryOf(&word);
    entry(1.5, 10, 0.25f).should == 11.75;

    recorded.doubles.should == [1.5, 0.25];
    recorded.integers.should == [10];
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
    bridge.register(&word, function_);

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
    bridge.register(&word, function_);

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
    auto bridge = new CallbackBridge(&recordIntOfInt, &recorded);
    int word;
    bridge.register(&word, function_);

    int delegate(int) callback;
    callback.funcptr = cast(int function(int)) bridge.entryOf(&word);
    int context;
    callback.ptr = &context;

    callback(4).should == 9;
    recorded.hasContext.should == true;
    (recorded.context is &context).should == true;
    recorded.integers.should == [4];

    ubyte[32] object;
    callback.ptr = object.ptr + 16;
    callback.funcptr = cast(int function(int))
        bridge.adjustedEntryOf(&word, function_, -16);
    callback(5).should == 11;
    (recorded.context is object.ptr).should == true;
    (callback.ptr is object.ptr + 16).should == true;
    (bridge.adjustedEntryOf(&word, function_, -16)
        is cast(const(void)*) callback.funcptr).should == true;

    auto native = ContextValue(37);
    auto target = &native.add;
    callback.ptr = cast(ubyte*) target.ptr + 16;
    callback.funcptr = cast(int function(int)) bridge.adjustedEntryOf(
        cast(const(void)*) target.funcptr, function_, -16);
    callback(5).should == 42;
}


// A chunk the pool copied from the template at run time works the same
// as the template: `beginCallbackChunk` forces a fresh chunk made with
// the given strategy, so the entry reserved next lives outside the
// binary's own chunk. The dual-mapping strategy is the fallback for a
// kernel that refuses to make written memory executable; a kernel that
// allows it never takes that path on its own, so this drives it directly.
static foreach (strategy; [ChunkStrategy.protect, ChunkStrategy.dualMapping]) {
    @("chunk." ~ text(strategy))
    unittest {
        auto function_ = declarationOf(
            q{ extern(C) int twice(int x); }, "twice");
        Recorded recorded;
        auto bridge = new CallbackBridge(&recordIntOfInt, &recorded);
        int word;
        bridge.register(&word, function_);

        const chunksBefore = callbackChunkCount;
        beginCallbackChunk(strategy);
        callbackChunkCount.should == chunksBefore + 1;

        auto entry = cast(IntOfInt) bridge.entryOf(&word);
        inTemplateChunk(entry).should == false;

        entry(100).should == 201;
        recorded.integers.should == [100];
    }
}
