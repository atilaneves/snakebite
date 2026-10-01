module ut.ffi.aggregates;


import ut.backends;


private struct LargeMemory {
    ulong[102] words;
}


private struct LargerMemory {
    ulong[8193] words;
}


public extern(C) int snakebite_ut_aggregates_large_memory(
    int a, int b, int c, int d, int e, int f, int g,
    LargeMemory value, LargerMemory larger, int tail,
) {
    foreach (i, word; value.words)
        if (word != i + 17)
            return 1;
    foreach (i, word; larger.words)
        if (word != i + 31)
            return 2;
    value.words[101] = 0;
    larger.words[8192] = 0;
    return a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + tail;
}


// 816 bytes matches Reggae's GeneratorSettings. The second argument also
// checks that source offsets above 65535 do not wrap. A scalar on each
// side of the aggregates checks their positions in the stack area.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot call an external function without source"),
)) {
    @("memoryClassParameter.largeArguments." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        151.shouldBeRetOf!(backend, q{
            struct LargeMemory {
                ulong[102] words;
            }
            struct LargerMemory {
                ulong[8193] words;
            }
            pragma(mangle, "snakebite_ut_aggregates_large_memory")
            extern(C) int nativeLargeMemory(
                int, int, int, int, int, int, int,
                LargeMemory, LargerMemory, int,
            );
            int answer() {
                LargeMemory value;
                LargerMemory larger;
                foreach (i, ref word; value.words)
                    word = i + 17;
                foreach (i, ref word; larger.words)
                    word = i + 31;
                const result = nativeLargeMemory(
                    1, 2, 3, 4, 5, 6, 7, value, larger, 11,
                );
                if (value.words[101] != 118 || larger.words[8192] != 8223)
                    return -1;
                return result;
            }
        }, "answer");
    }
}


private struct Owned {
    long value;
    ~this() {}
}

private alias OwnedCallback = extern(C) long function(Owned);


public extern(C) long snakebite_ut_aggregates_owned_roundtrip(
    long a, long b, long c, long d, long e, long f,
    Owned value, OwnedCallback callback,
) {
    return a + b + c + d + e + f + callback(value);
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot call host code"),
)) {
    @("nonPod.spilledArgumentAndCallback." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            struct Value {
                long number;
                ~this() {}
            }
            alias Callback = extern(C) long function(Value);
            pragma(mangle, "snakebite_ut_aggregates_owned_roundtrip")
            extern(C) long snakebite_ut_aggregates_owned_roundtrip(
                long, long, long, long, long, long,
                Value, Callback,
            );
            extern(C) long read(Value value) {
                return value.number * 2;
            }
            void main() {
                assert(snakebite_ut_aggregates_owned_roundtrip(
                    1, 2, 3, 4, 5, 6, Value(42), &read,
                ) == 105);
            }
        });
    }
}


private struct FiveBytes {
    ubyte[5] bytes;
}


public extern(C) FiveBytes snakebite_ut_aggregates_five_bytes(ubyte seed) {
    FiveBytes result;
    foreach (i, ref value; result.bytes)
        value = cast(ubyte) (seed + i);
    return result;
}


public extern(C) int snakebite_ut_aggregates_five_bytes_callback(
    FiveBytes function(ubyte) callback, ubyte seed,
) {
    int sum;
    foreach (value; callback(seed).bytes)
        sum += value;
    return sum;
}


// An aggregate of five bytes comes back in one register, and only its five
// low bytes belong to the result.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot call an external function without source"),
)) {
    @("registerResult.fiveBytesFromNative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        25.shouldBeRetOf!(backend, q{
            struct FiveBytes {
                ubyte[5] bytes;
            }
            pragma(mangle, "snakebite_ut_aggregates_five_bytes")
            extern(C) FiveBytes nativeFiveBytes(ubyte);
            int answer() {
                int sum;
                const result = nativeFiveBytes(3);
                foreach (value; result.bytes)
                    sum += value;
                return sum;
            }
        }, "answer");
    }
}


// Native code reads the five bytes that a guest function returns.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot call host code"),
)) {
    @("registerResult.fiveBytesFromGuestCallback." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        25.shouldBeRetOf!(backend, q{
            struct FiveBytes {
                ubyte[5] bytes;
            }
            alias Callback = extern(C) FiveBytes function(ubyte);
            pragma(mangle, "snakebite_ut_aggregates_five_bytes_callback")
            extern(C) int nativeSum(Callback, ubyte);
            extern(C) FiveBytes make(ubyte seed) {
                FiveBytes result;
                foreach (i, ref value; result.bytes)
                    value = cast(ubyte) (seed + i);
                return result;
            }
            int answer() {
                return nativeSum(&make, 3);
            }
        }, "answer");
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot open native files"),
)) {
    @("fileAssignment." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        0.shouldBeStatusOf!(backend, q{
            import std.stdio: File;

            void main() {
                auto first = File.tmpfile;
                auto second = File.tmpfile;
                first = second;
                assert(first.fileno == second.fileno);
            }
        });
    }
}
