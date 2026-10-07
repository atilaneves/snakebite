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


// Each register class and each size of a small aggregate result of the
// System V x86-64 ABI, in the two directions.
private struct SmallType {
    string name;
    string kind;
    string fields;
    size_t bytes;
}

private enum SmallType[] smallTypes = [
    SmallType("I1", "struct", "ubyte[1] a;", 1),
    SmallType("I2", "struct", "ubyte[2] a;", 2),
    SmallType("I3", "struct", "ubyte[3] a;", 3),
    SmallType("I4", "struct", "ubyte[4] a;", 4),
    SmallType("I5", "struct", "ubyte[5] a;", 5),
    SmallType("I6", "struct", "ubyte[6] a;", 6),
    SmallType("I7", "struct", "ubyte[7] a;", 7),
    SmallType("I8", "struct", "ubyte[8] a;", 8),
    SmallType("I9", "struct", "ubyte[9] a;", 9),
    SmallType("I10", "struct", "ubyte[10] a;", 10),
    SmallType("I11", "struct", "ubyte[11] a;", 11),
    SmallType("I12", "struct", "ubyte[12] a;", 12),
    SmallType("I13", "struct", "ubyte[13] a;", 13),
    SmallType("I14", "struct", "ubyte[14] a;", 14),
    SmallType("I15", "struct", "ubyte[15] a;", 15),
    SmallType("I16", "struct", "ubyte[16] a;", 16),
    SmallType("S1", "struct", "ubyte a;", 1),
    SmallType("S2", "struct", "ushort a;", 2),
    SmallType("S4", "struct", "uint a;", 4),
    SmallType("S8", "struct", "ulong a;", 8),
    SmallType("S16", "struct", "ulong a; ulong b;", 16),
    SmallType("W6", "struct", "ushort[3] a;", 6),
    SmallType("W10", "struct", "ushort[5] a;", 10),
    SmallType("W14", "struct", "ushort[7] a;", 14),
    SmallType("L12", "struct", "uint[3] a;", 12),
    SmallType("LI12", "struct", "ulong a; uint b;", 12),
    SmallType("F4", "struct", "float a;", 4),
    SmallType("F8", "struct", "float a; float b;", 8),
    SmallType("F12", "struct", "float a; float b; float c;", 12),
    SmallType("F16", "struct", "float a; float b; float c; float d;", 16),
    SmallType("FA12", "struct", "float[3] a;", 12),
    SmallType("D8", "struct", "double a;", 8),
    SmallType("D16", "struct", "double a; double b;", 16),
    SmallType("DA16", "struct", "double[2] a;", 16),
    SmallType("DF12", "struct", "double a; float b;", 12),
    SmallType("ID16", "struct", "long a; double b;", 16),
    SmallType("DI12", "struct", "double a; int b;", 12),
    SmallType("DL16", "struct", "double a; long b;", 16),
    SmallType("FI8", "struct", "float a; int b;", 8),
    SmallType("FB5", "struct", "float a; ubyte b;", 5),
    SmallType("FFB9", "struct", "float a; float b; ubyte c;", 9),
    SmallType("DB11", "struct", "double a; ubyte[3] b;", 11),
    SmallType("BD16", "struct", "ubyte[3] a; double b;", 16),
    SmallType("P3", "struct", "align(1): ushort a; ubyte b;", 3),
    SmallType("P5", "struct", "align(1): float a; ubyte b;", 5),
    SmallType("P5I", "struct", "align(1): uint a; ubyte b;", 5),
    SmallType("P6", "struct", "align(1): uint a; ushort b;", 6),
    SmallType("P7", "struct", "align(1): uint a; ushort b; ubyte c;", 7),
    SmallType("P9", "struct", "align(1): double a; ubyte b;", 9),
    SmallType("P13", "struct", "align(1): double a; float b; ubyte c;", 13),
    SmallType("P6U", "struct", "align(1): ushort a; uint b;", 6),
    SmallType("P11U", "struct", "align(1): ubyte a; double b; ushort c;", 11),
    SmallType("U5", "union", "ubyte[5] a; ubyte b;", 5),
    SmallType("U7", "union", "ubyte[7] a; ushort b;", 7),
    SmallType("UF8", "union", "ubyte[5] a; float b;", 5),
    SmallType("UD16", "union", "ubyte[13] a; double b;", 13),
];

private int smallExpected(in size_t bytes) {
    int sum;
    foreach (i; 0 .. bytes)
        sum += cast(ubyte) (3 + i) * cast(int) (i + 1);
    return sum;
}

private string smallBytes(in size_t bytes) {
    import std.conv: text;
    return text(bytes);
}

static foreach (type; smallTypes) {
    mixin("private " ~ type.kind ~ " Small" ~ type.name ~ " { " ~ type.fields ~ " }");
    mixin("public extern(C) Small" ~ type.name ~ " snakebite_ut_small_make_" ~ type.name
        ~ "(ubyte seed) { Small" ~ type.name ~ " r; foreach (i; 0 .. " ~ smallBytes(type.bytes)
        ~ ") (cast(ubyte*) &r)[i] = cast(ubyte) (seed + i); return r; }");
    mixin("public extern(C) int snakebite_ut_small_sum_" ~ type.name
        ~ "(Small" ~ type.name ~ " function(ubyte) callback, ubyte seed) { auto r = callback(seed);"
        ~ " int sum; foreach (i; 0 .. " ~ smallBytes(type.bytes)
        ~ ") sum += (cast(ubyte*) &r)[i] * cast(int) (i + 1); return sum; }");

    static foreach (backend; Matrix!(
        Omit!(Ctfe, Because.inexpressible, "CTFE cannot call an external function without source"),
    )) {
        @("smallResult.fromNative." ~ type.name ~ "." ~ backend.stringof)
        @Tags(backend.stringof)
        unittest {
            smallExpected(type.bytes).shouldBeRetOf!(backend,
                type.kind ~ " T { " ~ type.fields ~ " }\n"
                ~ "pragma(mangle, \"snakebite_ut_small_make_" ~ type.name ~ "\")\n"
                ~ "extern(C) T nativeMake(ubyte);\n"
                ~ "int answer() { auto r = nativeMake(3); int sum; foreach (i; 0 .. "
                ~ smallBytes(type.bytes) ~ ") sum += (cast(ubyte*) &r)[i] * cast(int) (i + 1);"
                ~ " return sum; }\n",
                "answer");
        }

        @("smallResult.fromGuestCallback." ~ type.name ~ "." ~ backend.stringof)
        @Tags(backend.stringof)
        unittest {
            smallExpected(type.bytes).shouldBeRetOf!(backend,
                type.kind ~ " T { " ~ type.fields ~ " }\n"
                ~ "alias Callback = extern(C) T function(ubyte);\n"
                ~ "pragma(mangle, \"snakebite_ut_small_sum_" ~ type.name ~ "\")\n"
                ~ "extern(C) int nativeSum(Callback, ubyte);\n"
                ~ "extern(C) T make(ubyte seed) { T r; foreach (i; 0 .. "
                ~ smallBytes(type.bytes) ~ ") (cast(ubyte*) &r)[i] = cast(ubyte) (seed + i); return r; }\n"
                ~ "int answer() { return nativeSum(&make, 3); }\n",
                "answer");
        }
    }
}


private struct VoidBlob {
    void[8] bytes;
}


public extern(C) VoidBlob snakebite_ut_aggregates_void_blob_echo(
    VoidBlob value,
) {
    return value;
}


public extern(C) void[8] snakebite_ut_aggregates_void_array_echo(
    void[8] value,
) {
    return value;
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot call an external function without source"),
)) {
    @("voidArrayField.echoedByValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7.shouldBeRetOf!(backend, q{
            struct VoidBlob {
                void[8] bytes;
            }
            pragma(mangle, "snakebite_ut_aggregates_void_blob_echo")
            extern(C) VoidBlob nativeEcho(VoidBlob);
            int answer() {
                VoidBlob value = void;
                auto bytes = cast(ubyte*) value.bytes.ptr;
                foreach (i; 0 .. 8)
                    bytes[i] = cast(ubyte) i;
                auto echoed = nativeEcho(value);
                return (cast(ubyte*) echoed.bytes.ptr)[7];
            }
        }, "answer");
    }
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot call an external function without source"),
)) {
    @("voidStaticArray.echoedByValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7.shouldBeRetOf!(backend, q{
            pragma(mangle, "snakebite_ut_aggregates_void_array_echo")
            extern(C) void[8] nativeEcho(void[8]);
            int answer() {
                void[8] value = void;
                auto bytes = cast(ubyte*) value.ptr;
                foreach (i; 0 .. 8)
                    bytes[i] = cast(ubyte) i;
                auto echoed = nativeEcho(value);
                return (cast(ubyte*) echoed.ptr)[7];
            }
        }, "answer");
    }
}


public extern(C) real[1] snakebite_ut_aggregates_real_array_echo(
    real[1] value,
) {
    return value;
}


static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible,
        "CTFE cannot call an external function without source"),
)) {
    @("realStaticArray.echoedByValue." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        7.shouldBeRetOf!(backend, q{
            pragma(mangle, "snakebite_ut_aggregates_real_array_echo")
            extern(C) real[1] nativeEcho(real[1]);
            int answer() {
                real[1] value = [7.0L];
                return cast(int) nativeEcho(value)[0];
            }
        }, "answer");
    }
}
