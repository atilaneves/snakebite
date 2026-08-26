void encode(T)(T val, ref ubyte[] output) {
    static if (is(T == float))
        encode(*cast(uint*) &val, output);
    else static if (is(T == double))
        encode(*cast(ulong*) &val, output);
    else
        static foreach(i; 0 .. T.sizeof)
            output ~= cast(ubyte)(val >> (i * 8));
}

T decode(T)(in ubyte[] input, ref size_t pos) {
    static if (is(T == float)) {
        uint bits = decode!uint(input, pos);
        return *cast(float*) &bits;
    } else static if (is(T == double)) {
        ulong bits = decode!ulong(input, pos);
        return *cast(double*) &bits;
    } else {
        if (pos + T.sizeof > input.length)
            throw new OutOfBytesError("Minicereal.decode: not enough bytes");

        T result = 0;

        static foreach(i; 0 .. T.sizeof)
            result |= cast(T)(input[pos++]) << (i * 8);

        return result;
    }
}

struct Minicereal {
    ubyte[] bytes;

    void put(T)(T val) {
        encode(val, bytes);
    }

    T get(T)(ref size_t pos) {
        return decode!T(bytes, pos);
    }
}

class MinicerealError : Exception {
    this(string msg) {
        super(msg);
    }
}

class OutOfBytesError : MinicerealError {
    this(string msg) {
        super(msg);
    }
}

unittest {
    ubyte[] input;
    size_t pos = 0;
    bool caught;

    try {
        decode!uint(input, pos);
    } catch (MinicerealError e) {
        caught = true;
    }

    assert(caught);
}

unittest {
    ubyte[] input;
    size_t pos = 0;
    string message;

    try {
        decode!ulong(input, pos);
    } catch (MinicerealError e) {
        auto specific = cast(OutOfBytesError) e;
        message = specific.msg;
    }

    assert(message == "Minicereal.decode: not enough bytes");
}

unittest {
    ubyte[] input;
    size_t pos = 0;
    bool caught;
    bool finallyRan;

    try {
        decode!int(input, pos);
    } catch (Exception e) {
        caught = true;
    } finally {
        finallyRan = true;
    }

    assert(caught);
    assert(finallyRan);
}

unittest {
    ubyte[] input = [0x2au];
    size_t pos = 0;
    bool finallyRan;
    ubyte value;

    try {
        value = decode!ubyte(input, pos);
    } finally {
        finallyRan = true;
    }

    assert(value == 0x2au);
    assert(finallyRan);
}

unittest {
    string caughtAs;

    void attempt(ubyte[] input) {
        size_t pos = 0;
        try {
            decode!uint(input, pos);
        } catch (OutOfBytesError e) {
            caughtAs = "outOfBytes";
        } catch (MinicerealError e) {
            caughtAs = "minicereal";
        }
    }

    attempt([]);
    assert(caughtAs == "outOfBytes");
}

unittest {
    bool outerCaught;

    void inner(ubyte[] input, ref size_t pos) {
        try {
            decode!int(input, pos);
        } catch (MinicerealError e) {
            throw e;
        }
    }

    ubyte[] input;
    size_t pos = 0;
    try {
        inner(input, pos);
    } catch (MinicerealError e) {
        outerCaught = true;
    }

    assert(outerCaught);
}

unittest {
    ubyte[] buf;
    encode!ubyte(0x2au, buf);
    assert(buf.length == 1);
    assert(buf[0] == 0x2au);
}

unittest {
    ubyte[] input = [0x2au];
    size_t pos = 0;
    assert(decode!ubyte(input, pos) == 0x2au);
    assert(pos == 1);
}

unittest {
    ubyte value = 0x2au;
    ubyte[] buf;
    encode(value, buf);
    size_t pos = 0;
    assert(decode!ubyte(buf, pos) == value);
    assert(pos == 1);
}

unittest {
    ubyte[] buf;
    encode!byte(cast(byte) -42, buf);
    ubyte[] expected = [0xd6u];
    assert(buf == expected);
}

unittest {
    ubyte[] input = [0xd6u];
    size_t pos = 0;
    assert(decode!byte(input, pos) == cast(byte) -42);
    assert(pos == 1);
}

unittest {
    byte value = cast(byte) -42;
    ubyte[] buf;
    encode(value, buf);
    size_t pos = 0;
    assert(decode!byte(buf, pos) == value);
    assert(pos == 1);
}

unittest {
    ubyte[] buf;
    encode!ushort(0x1234u, buf);
    ubyte[] expected = [0x34u, 0x12u];
    assert(buf == expected);
}

unittest {
    ubyte[] input = [0x34u, 0x12u];
    size_t pos = 0;
    assert(decode!ushort(input, pos) == 0x1234u);
    assert(pos == 2);
}

unittest {
    ushort value = 0x1234u;
    ubyte[] buf;
    encode(value, buf);
    size_t pos = 0;
    assert(decode!ushort(buf, pos) == value);
    assert(pos == 2);
}

unittest {
    ubyte[] buf;
    encode!short(cast(short) -42, buf);
    ubyte[] expected = [0xd6u, 0xffu];
    assert(buf == expected);
}

unittest {
    ubyte[] input = [0xd6u, 0xffu];
    size_t pos = 0;
    assert(decode!short(input, pos) == cast(short) -42);
    assert(pos == 2);
}

unittest {
    short value = cast(short) -42;
    ubyte[] buf;
    encode(value, buf);
    size_t pos = 0;
    assert(decode!short(buf, pos) == value);
    assert(pos == 2);
}

unittest {
    ubyte[] buf;
    encode!uint(0x01020304u, buf);
    ubyte[] expected = [4u, 3u, 2u, 1u];
    assert(buf == expected);
}

unittest {
    ubyte[] input = [4u, 3u, 2u, 1u];
    size_t pos = 0;
    assert(decode!uint(input, pos) == 0x01020304u);
    assert(pos == 4);
}

unittest {
    uint value = 0x01020304u;
    ubyte[] buf;
    encode(value, buf);
    size_t pos = 0;
    assert(decode!uint(buf, pos) == value);
    assert(pos == 4);
}

unittest {
    ubyte[] buf;
    encode!int(-42, buf);
    ubyte[] expected = [0xd6u, 0xffu, 0xffu, 0xffu];
    assert(buf == expected);
}

unittest {
    ubyte[] input = [0xd6u, 0xffu, 0xffu, 0xffu];
    size_t pos = 0;
    assert(decode!int(input, pos) == -42);
    assert(pos == 4);
}

unittest {
    int value = -42;
    ubyte[] buf;
    encode(value, buf);
    size_t pos = 0;
    assert(decode!int(buf, pos) == value);
    assert(pos == 4);
}

unittest {
    ubyte[] buf;
    encode!ulong(0x8070605040302010UL, buf);
    ubyte[] expected = [
        0x10u,
        0x20u,
        0x30u,
        0x40u,
        0x50u,
        0x60u,
        0x70u,
        0x80u,
    ];
    assert(buf == expected);
}

unittest {
    ubyte[] input = [
        0x10u,
        0x20u,
        0x30u,
        0x40u,
        0x50u,
        0x60u,
        0x70u,
        0x80u,
    ];
    size_t pos = 0;
    assert(decode!ulong(input, pos) == 0x8070605040302010UL);
    assert(pos == 8);
}

unittest {
    ulong value = 0x8070605040302010UL;
    ubyte[] buf;
    encode(value, buf);
    size_t pos = 0;
    assert(decode!ulong(buf, pos) == value);
    assert(pos == 8);
}

unittest {
    ubyte[] buf;
    encode!long(-42L, buf);
    ubyte[] expected = [
        0xd6u,
        0xffu,
        0xffu,
        0xffu,
        0xffu,
        0xffu,
        0xffu,
        0xffu,
    ];
    assert(buf == expected);
}

unittest {
    ubyte[] input = [
        0xd6u,
        0xffu,
        0xffu,
        0xffu,
        0xffu,
        0xffu,
        0xffu,
        0xffu,
    ];
    size_t pos = 0;
    assert(decode!long(input, pos) == -42L);
    assert(pos == 8);
}

unittest {
    long value = -42L;
    ubyte[] buf;
    encode(value, buf);
    size_t pos = 0;
    assert(decode!long(buf, pos) == value);
    assert(pos == 8);
}

unittest {
    ubyte[] buf;
    encode!float(1.5f, buf);
    ubyte[] expected = [0x00u, 0x00u, 0xc0u, 0x3fu];
    assert(buf == expected);
}

unittest {
    ubyte[] input = [0x00u, 0x00u, 0xc0u, 0x3fu];
    size_t pos = 0;
    assert(decode!float(input, pos) == 1.5f);
    assert(pos == 4);
}

unittest {
    float value = -2.25f;
    ubyte[] buf;
    encode(value, buf);
    size_t pos = 0;
    assert(decode!float(buf, pos) == value);
    assert(pos == 4);
}

unittest {
    ubyte[] buf;
    encode!double(1.5, buf);
    ubyte[] expected = [0x00u, 0x00u, 0x00u, 0x00u, 0x00u, 0x00u, 0xf8u, 0x3fu];
    assert(buf == expected);
}

unittest {
    ubyte[] input = [0x00u, 0x00u, 0x00u, 0x00u, 0x00u, 0x00u, 0xf8u, 0x3fu];
    size_t pos = 0;
    assert(decode!double(input, pos) == 1.5);
    assert(pos == 8);
}

unittest {
    double value = -2.25;
    ubyte[] buf;
    encode(value, buf);
    size_t pos = 0;
    assert(decode!double(buf, pos) == value);
    assert(pos == 8);
}

unittest {
    Minicereal cereal;
    cereal.put!double(3.5);
    cereal.put!float(-1.25f);
    size_t pos = 0;
    assert(cereal.get!double(pos) == 3.5);
    assert(cereal.get!float(pos) == -1.25f);
    assert(pos == cereal.bytes.length);
}

unittest {
    Minicereal cereal;
    cereal.put(0x01020304);
    size_t pos = 0;
    assert(cereal.get!int(pos) == 0x01020304);
    assert(pos == 4);
}

unittest {
    Minicereal cereal;
    assert(cereal.bytes.length == 0);
}

unittest {
    Minicereal cereal;
    cereal.bytes ~= 0x2au;
    assert(cereal.bytes.length == 1);
    assert(cereal.bytes[0] == 0x2au);
}

unittest {
    Minicereal cereal;
    cereal.bytes ~= cast(ubyte) 42;
    size_t pos = 0;
    assert(cereal.get!ubyte(pos) == 42);
    assert(pos == 1);
}

unittest {
    Minicereal cereal;
    cereal.bytes = [0];
    cereal.bytes[0] = cast(ubyte) 42;
    size_t pos = 0;
    assert(cereal.get!ubyte(pos) == 42);
}

unittest {
    Minicereal cereal;
    cereal.put!ubyte(0x2au);
    assert(cereal.bytes.length == 1);
    assert(cereal.bytes[0] == 0x2au);
}

unittest {
    Minicereal cereal;
    cereal.put!ubyte(0x2au);
    ubyte[] expected = [0x2au];
    assert(cereal.bytes == expected);
}

unittest {
    Minicereal cereal;
    cereal.put!ubyte(0x2au);
    cereal.put!ushort(0x1234u);
    ubyte[] expected = [0x2au, 0x34u, 0x12u];
    assert(cereal.bytes == expected);
}

unittest {
    Minicereal cereal;
    cereal.put(0x01020304);
    ubyte[] expected = [4u, 3u, 2u, 1u];
    assert(cereal.bytes[] == expected);
}

unittest {
    Minicereal cereal;
    cereal.put!ubyte(0x99u);
    cereal.put!ushort(0x1234u);
    ubyte[] expected = [0x34u, 0x12u];
    assert(cereal.bytes[1 .. 3] == expected);
}

unittest {
    Minicereal cereal;
    cereal.bytes = [1, 2, 3, 4];
    ubyte[] expected = [2, 3];
    assert(cereal.bytes[1 .. 3] == expected[]);
}

unittest {
    Minicereal cereal;
    cereal.put!ubyte(0x99u);
    cereal.put(0x01020304);
    ubyte[] expected = [4u, 3u, 2u, 1u];
    assert(cereal.bytes[$ - 4 .. $] == expected);
}

unittest {
    Minicereal cereal;
    cereal.put!ubyte(0x2au);
    size_t pos = 0;
    assert(cereal.get!ubyte(pos) == 0x2au);
    assert(pos == 1);
}

unittest {
    Minicereal cereal;
    cereal.put(42);
    size_t pos = 0;
    assert(cereal.get!int(pos) == 42);
    assert(pos == 4);
}

unittest {
    Minicereal cereal;
    cereal.bytes = [4u, 3u, 2u, 1u];
    size_t pos = 0;
    assert(cereal.get!int(pos) == 0x01020304);
    assert(pos == 4);
}

unittest {
    const value = 0x8070605040302010UL;
    Minicereal cereal;
    cereal.put(value);
    size_t pos = 0;
    const decoded = cereal.get!ulong(pos);
    assert(decoded == value);
    assert(decoded > 0UL);
    assert(pos == 8);
}

unittest {
    Minicereal cereal;
    cereal.put!ubyte(0x2au);
    cereal.put!byte(cast(byte) -42);
    cereal.put!ushort(0x1234u);
    cereal.put!short(cast(short) -1234);
    cereal.put!uint(0x01020304u);
    cereal.put!int(-0x01020304);
    cereal.put!ulong(0x8070605040302010UL);
    cereal.put!long(-0x0102030405060708L);

    size_t pos = 0;
    assert(cereal.get!ubyte(pos) == 0x2au);
    assert(cereal.get!byte(pos) == cast(byte) -42);
    assert(cereal.get!ushort(pos) == 0x1234u);
    assert(cereal.get!short(pos) == cast(short) -1234);
    assert(cereal.get!uint(pos) == 0x01020304u);
    assert(cereal.get!int(pos) == -0x01020304);
    assert(cereal.get!ulong(pos) == 0x8070605040302010UL);
    assert(cereal.get!long(pos) == -0x0102030405060708L);
    assert(pos == cereal.bytes.length);
}

unittest {
    Minicereal cereal;
    cereal.bytes = [2u, 4u, 6u, 8u];

    uint weightedSum;
    foreach (i, value; cereal.bytes)
        weightedSum += cast(uint)(i + 1) * value;

    assert(weightedSum == 60);
}

unittest {
    uint sum;
    uint skipped;

    for (uint value = 0; value < 6; ++value) {
        if (value % 2 == 0) {
            ++skipped;
            continue;
        }

        sum += value;
    }

    assert(sum == 9);
    assert(skipped == 3);
}

unittest {
    uint matched;
    uint fellThrough;

    foreach (value; [0u, 1u, 3u]) {
        switch (value) {
        case 0:
            matched += 10;
            break;
        case 1:
            matched += 20;
            break;
        default:
            fellThrough += value;
            break;
        }
    }

    assert(matched == 30);
    assert(fellThrough == 3);
}

unittest {
    uint[] values = [0u, 1u];
    uint observed;

    assert(((values[0] != 0) && (++observed == 1)) == false);
    assert(observed == 0);

    assert(((values[1] != 0) && (++observed == 1)) == true);
    assert(observed == 1);

    assert(((values[1] != 0) || (++observed == 2)) == true);
    assert(observed == 1);

    assert(((values[0] != 0) || (++observed == 2)) == true);
    assert(observed == 2);
}

unittest {
    uint[] values = [0x00f0u, 0x0f0fu, 0xff00u];

    uint masked = values[0] & values[1];
    assert(masked == 0u);

    uint combined = values[0] | values[1];
    assert(combined == 0x0fffu);

    uint toggled = combined ^ values[2];
    assert(toggled == 0xf0ffu);

    uint shifted = (toggled << 4) >> 8;
    assert(shifted == 0x0f0fu);

    ushort narrowedWord = cast(ushort) toggled;
    assert(narrowedWord == 0xf0ffu);

    ubyte narrowedByte = cast(ubyte) shifted;
    assert(narrowedByte == 0x0fu);

    byte signedByte = cast(byte) narrowedWord;
    assert(signedByte == cast(byte) -1);

    short signedWord = cast(short) narrowedWord;
    assert(signedWord == cast(short) -3841);

    assert(cast(ubyte) ~narrowedByte == 0xf0u);
}

class Header {
    int magic = 0x2a;
}

class VersionedHeader : Header {
    int schema = 1;
    int length = 0;

    this(int len) {
        length = len;
    }
}

unittest {
    auto plain = new Header;
    assert(plain.magic == 0x2a);

    auto versioned = new VersionedHeader(16);
    assert(versioned.magic == 0x2a);
    assert(versioned.schema == 1);
    assert(versioned.length == 16);
}

class Counter {
    int value;
}

void setTo(ref int x, int value) {
    x = value;
}

unittest {
    auto counter = new Counter;
    setTo(counter.value, 88);
    assert(counter.value == 88);
}

void addTo(ref int target, int amount) {
    target = target + amount;
}

void addThroughPointer(T)(ref T val, int amount) {
    addTo(*val, amount);
}

unittest {
    int value = 5;
    int* pointer = &value;

    addThroughPointer(pointer, 37);

    assert(value == 42);
}

interface Codec {
    int transform();
}

class DoublingCodec : Codec {
    int val_;

    this(int val) {
        val_ = val;
    }

    int transform() {
        return val_ * 2;
    }
}

class IncrementingCodec : Codec {
    int val_;

    this(int val) {
        val_ = val;
    }

    int transform() {
        return val_ + 1;
    }
}

int runDoubling(int val) {
    Codec doubler = new DoublingCodec(val);
    return doubler.transform();
}

int runIncrementing(int val) {
    Codec incrementer = new IncrementingCodec(val);
    return incrementer.transform();
}

unittest {
    assert(runDoubling(20) == 40);
}

unittest {
    assert(runIncrementing(20) == 21);
}

int accumulate(int seed) {
    int total = seed + 2;

    int add(int amount) {
        total += amount;
        return total;
    }

    int delegate(int) adder = &add;

    return adder(5) + adder(1);
}

unittest {
    assert(accumulate(3) == 21);
}

int weightedTotal(int base) {
    int total = base;

    int scaleBy(int factor) {
        total = total * factor;
        return total;
    }

    int delegate(int) scaler = &scaleBy;

    scaler(2);
    scaler(3);

    return total;
}

unittest {
    assert(weightedTotal(5) == 30);
}

struct Cursor {
    size_t offset;

    size_t readOffset() {
        auto nested = () => offset;
        return nested();
    }
}

unittest {
    auto cursor = Cursor(7);
    assert(cursor.readOffset() == 7);
}

struct Tag {
    int code;

    int readCode() {
        return (() => code)();
    }
}

unittest {
    auto tag = Tag(9);
    assert(tag.readCode() == 9);
}

unittest {
    int[string] fieldOffsets;
    fieldOffsets["magic"] = 0;
    fieldOffsets["schema"] = 4;

    int offsetSum;
    int nameLengthSum;
    foreach (name, offset; fieldOffsets) {
        assert(fieldOffsets[name] == offset);
        offsetSum += offset;
        nameLengthSum += cast(int) name.length;
    }
    assert(offsetSum == 4);
    assert(nameLengthSum == 11);
}

struct FieldId {
    int recordId;
    int fieldIndex;
}

unittest {
    int[FieldId] widths;
    widths[FieldId(1, 0)] = 4;

    FieldId id = FieldId(1, 1);
    widths[id] = 8;

    assert((FieldId(1, 0) in widths) !is null);
    assert(widths[FieldId(1, 0)] == 4);
    assert(widths[id] == 8);
    assert(widths.length == 2);

    int sum;
    foreach (k, v; widths)
        sum += k.recordId + k.fieldIndex + v;
    assert(sum == 15);
}

unittest {
    int[int] table = [1: 10, 2: 20, 3: 30];
    int keySum;
    int valueSum;

    foreach (key; table.keys)
        keySum += key;

    foreach (value; table.values)
        valueSum += value;

    assert(keySum == 6);
    assert(valueSum == 60);
}

struct Span {
    int offset;
    int length;

    int grow() {
        return length += 1;
    }
}

unittest {
    Span[string] spans;
    spans["header"] = Span(0, 4);
    assert(spans["header"].offset == 0);

    spans["header"].offset = 8;
    assert(spans["header"].offset == 8);
    assert(spans["header"].length == 4);

    spans["header"].grow();
    assert(spans["header"].length == 5);
}

unittest {
    int i;
    int sum;

    do {
        ++i;

        if (i == 2)
            continue;

        if (i == 5)
            break;

        sum += i;
    } while (i < 6);

    assert(sum == 8);
}

unittest {
    int outerLimit = 1;
    ++outerLimit;
    int innerLimit = 2;
    ++innerLimit;
    int count;

outer:
    for (int i = 0; i < outerLimit; ++i) {
        for (int j = 0; j < innerLimit; ++j) {
            ++count;

            if (i == 0 && j == 1)
                break outer;
        }
    }

    assert(count == 2);
}

int loopBound(int value) {
    return value;
}

unittest {
    int count;

outer:
    for (int i = 0; i < loopBound(3); ++i) {
        for (int j = 0; j < loopBound(4); ++j) {
            if (j == i + 1)
                continue outer;

            ++count;
        }

        count += loopBound(10);
    }

    assert(count == 6);
}

unittest {
    int value = 1;
    int result;

    switch (value) {
        case 1:
            result += 10;
            goto case 2;

        case 2:
            result += 20;
            break;

        default:
            result += 30;
            break;
    }

    assert(result == 30);
}

unittest {
    int value = 1;
    int result;

    switch (value) {
        case 1:
            result += 10;
            goto default;

        case 2:
            result += 20;
            break;

        default:
            result += 30;
            break;
    }

    assert(result == 40);
}

string paletteName(int n) {
    return n == 1 ? "red" : "green";
}

int paletteScore(string s) {
    switch (s) {
        case "red":
            return 10;

        case "green":
            return 20;

        default:
            return 0;
    }
}

unittest {
    assert(paletteScore(paletteName(1)) == 10);
    assert(paletteScore(paletteName(2)) == 20);
}

enum Shade {
    red,
    green,
    blue,
}

Shade shadeFor(int n) {
    return n == 0 ? Shade.red : n == 1 ? Shade.green : Shade.blue;
}

int weightOf(Shade shade) {
    final switch (shade) {
        case Shade.red:
            return 10;

        case Shade.green:
            return 20;

        case Shade.blue:
            return 30;
    }
}

unittest {
    assert(weightOf(shadeFor(0)) == 10);
    assert(weightOf(shadeFor(1)) == 20);
    assert(weightOf(shadeFor(2)) == 30);
}

int bucket(int n) {
    return n;
}

int classifyBucket(int n) {
    switch (n) {
        case 0: .. case 3:
            return 10;

        case 5, 7:
            return 20;

        default:
            return 30;
    }
}

unittest {
    assert(classifyBucket(bucket(0)) == 10);
    assert(classifyBucket(bucket(3)) == 10);
    assert(classifyBucket(bucket(5)) == 20);
    assert(classifyBucket(bucket(7)) == 20);
    assert(classifyBucket(bucket(4)) == 30);
}

uint factorial(uint i) {
    return i == 0 ? 1 : i * factorial(i - 1);
}

unittest {
    assert(factorial(5) == 120);
    assert(factorial(10) == 3_628_800);
}

uint fibonacci(uint i) {
    if(i == 0) return 0;
    if(i == 1) return 1;
    return fibonacci(i - 1) + fibonacci(i - 2);
}

unittest {
    assert(fibonacci(1) == 1);
    assert(fibonacci(2) == 1);
    assert(fibonacci(3) == 2);
    assert(fibonacci(4) == 3);
    assert(fibonacci(5) == 5);
    assert(fibonacci(6) == 8);
    assert(fibonacci(20) == 6765);
}

float scaleFloat(float lower, float upper, float factor) {
    return (upper - lower) * factor;
}

double scaleDouble(double lower, double upper, double factor) {
    return (upper - lower) * factor;
}

unittest {
    float factor = 3.0f;
    double doubleFactor = 3.0;

    assert(scaleFloat(1.0f, 3.0f, factor) == 6.0f);
    assert(scaleDouble(1.0, 3.0, doubleFactor) == 6.0);
}

float divideFloat(float numerator, float denominator) {
    return numerator / denominator;
}

double divideDouble(double numerator, double denominator) {
    return numerator / denominator;
}

unittest {
    float floatDenominator = 3.0f;
    double doubleDenominator = 3.0;

    assert(divideFloat(6.0f, floatDenominator) == 2.0f);
    assert(divideDouble(6.0, doubleDenominator) == 2.0);
}

float moduloFloat(float numerator, float denominator) {
    return numerator % denominator;
}

double moduloDouble(double numerator, double denominator) {
    return numerator % denominator;
}

unittest {
    float floatDenominator = 4.0f;
    double doubleDenominator = 4.0;

    assert(moduloFloat(6.0f, floatDenominator) == 2.0f);
    assert(moduloDouble(-6.0, doubleDenominator) == -2.0);
}

real addReal(real lhs, real rhs) {
    return lhs + rhs;
}

real subtractReal(real lhs, real rhs) {
    return lhs - rhs;
}

real multiplyReal(real lhs, real rhs) {
    return lhs * rhs;
}

real divideReal(real lhs, real rhs) {
    return lhs / rhs;
}

real moduloReal(real lhs, real rhs) {
    return lhs % rhs;
}

unittest {
    real lhs = 6.0L;
    real rhs = 4.0L;

    assert(addReal(lhs, rhs) == 10.0L);
    assert(subtractReal(lhs, rhs) == 2.0L);
    assert(multiplyReal(lhs, rhs) == 24.0L);
    assert(divideReal(lhs, rhs) == 1.5L);
    assert(moduloReal(lhs, rhs) == 2.0L);

    real negativeLhs = -6.0L;
    assert(moduloReal(negativeLhs, rhs) == -2.0L);
}

unittest {
    ulong value = 0;
    assert(~value > 0);
    assert(~value == 0xffffffffffffffffUL);
}

unittest {
    int[3][2] a;
    a[0] = [bucket(1), bucket(2), bucket(3)];
    a[1] = [bucket(4), bucket(5), bucket(6)];

    int[3][2] b;
    b[0] = [bucket(1), bucket(2), bucket(3)];
    b[1] = [bucket(4), bucket(5), bucket(6)];

    assert(a == b);
    assert(!(a != b));

    b[1][2] = bucket(99);
    assert(a != b);
    assert(!(a == b));
}

unittest {
    int first = bucket(2);
    int second = bucket(first + 1);
    int[] a = [first, second];
    int[] b = [first + 10, second + 20];

    int[] product = [0, 0];
    product[] = a[] * b[];

    int[] difference = [0, 0];
    difference[] = b[] - a[];

    int[] compoundArray = [first, second];
    compoundArray[] += b[];

    assert(product[0] == first * (first + 10));
    assert(product[1] == second * (second + 20));
    assert(difference[0] == 10);
    assert(difference[1] == 20);
    assert(compoundArray[0] == first + (first + 10));
    assert(compoundArray[1] == second + (second + 20));
}

struct ArrayKey {
    int[] xs;
}

unittest {
    int[ArrayKey] counts;
    counts[ArrayKey([1, 2])] = 1;

    assert((ArrayKey([1, 2]) in counts) !is null);
    assert(counts[ArrayKey([1, 2])] == 1);
}

struct LabelledField {
    string name;
    int index;
}

unittest {
    auto field = LabelledField("foo", 5);
    auto map = [field: 105];
    assert(map[field] == 105);
}

dchar pick(dchar value) {
    return value;
}

unittest {
    char[] ascii;
    ascii ~= pick('A');
    assert(ascii.length == 1);
    assert(ascii[0] == 'A');

    char[] twoByte;
    twoByte ~= pick('α');
    assert(twoByte.length == 2);
    assert(cast(ubyte) twoByte[0] == 0xCE);
    assert(cast(ubyte) twoByte[1] == 0xB1);
}

void callThroughNested(alias Func)() {
    void inner() {
        Func();
    }
    inner;
}

void checkCaptured() {
    uint captured = 42u;
    callThroughNested!({
        if (captured != 42u)
            throw new Exception("bad value");
    });
}

unittest {
    checkCaptured;
}

unittest {
    enum Direction : ubyte {
        north = 0,
        south = 1,
    }

    ubyte[] raw = [0, 1];
    size_t index;

    Direction first = cast(Direction) raw[index++];
    Direction second = cast(Direction) raw[index++];

    assert(first == Direction.north);
    assert(second == Direction.south);
}

unittest {
    uint function(uint) fn = &factorial;
    assert(fn(5) == 120);
}

struct FieldCtorPart {
    size_t count;
    ubyte first;

    this(ubyte[] bytes) {
        count = bytes.length;
        first = bytes[0];
    }
}

struct FieldCtorWhole {
    ubyte tag;
    FieldCtorPart part;
}

unittest {
    ubyte[] payload = [9, 7, 6];
    auto whole = FieldCtorWhole(2, FieldCtorPart(payload));

    assert(whole.tag == 2);
    assert(whole.part.count == 3);
    assert(whole.part.first == 9);
}

struct FieldCtorWholeFirst {
    FieldCtorPart part;
    ubyte tag;
}

unittest {
    ubyte[] payload = [9, 7, 6];
    auto whole = FieldCtorWholeFirst(FieldCtorPart(payload), 2);

    assert(whole.part.count == 3);
    assert(whole.part.first == 9);
    assert(whole.tag == 2);
}

struct FieldCtorMiddle {
    FieldCtorPart part;
}

struct FieldCtorOuterNested {
    ubyte tag;
    FieldCtorMiddle middle;
}

unittest {
    ubyte[] payload = [9, 7, 6];
    auto whole = FieldCtorOuterNested(2, FieldCtorMiddle(FieldCtorPart(payload)));

    assert(whole.middle.part.count == 3);
    assert(whole.middle.part.first == 9);
}

FieldCtorPart makeFieldCtorPart(ubyte[] bytes) {
    return FieldCtorPart(bytes);
}

unittest {
    ubyte[] payload = [9, 7, 6];
    auto whole = FieldCtorWhole(2, makeFieldCtorPart(payload));

    assert(whole.part.count == 3);
    assert(whole.part.first == 9);
}

unittest {
    ubyte[] payload = [9, 7, 6];
    auto existing = FieldCtorPart(payload);
    auto whole = FieldCtorWhole(2, existing);

    assert(whole.part.count == 3);
    assert(whole.part.first == 9);
}

unittest {
    ubyte[] longer = [9, 7, 6];
    ubyte[] shorter = [1, 2];
    bool pickLonger = longer.length > shorter.length;
    auto whole = FieldCtorWhole(
        2, pickLonger ? FieldCtorPart(longer) : FieldCtorPart(shorter),
    );

    assert(whole.part.count == 3);
    assert(whole.part.first == 9);
}

bool isPositive(T)(auto ref T value) {
    return *value > 0;
}

bool isPositiveForwarded(T)(auto ref T value) {
    return isPositive(value);
}

unittest {
    int number = 42;

    assert(isPositiveForwarded(&number));
}

struct Coordinates {
    ubyte row;
    ushort column;
}

Coordinates makeCoordinates(ubyte row, ushort column) {
    Coordinates result;
    result.row = row;
    result.column = column;
    return result;
}

bool matches(V, E)(auto ref V value, auto ref E expected) {
    return value == expected;
}

unittest {
    auto place = makeCoordinates(2, 300);
    const expected = Coordinates(2, 300);

    assert(matches(place, expected));
}

struct LifetimeTracker {
    int* postblits;
    int* dtors;

    this(this) {
        ++*postblits;
    }

    ~this() {
        ++*dtors;
    }
}

struct TrackerHolder {
    int tag;
    LifetimeTracker tracker;
}

LifetimeTracker makeTracker(int* postblits, int* dtors) {
    return LifetimeTracker(postblits, dtors);
}

unittest {
    int postblits = 0;
    int dtors = 0;

    {
        LifetimeTracker source = LifetimeTracker(&postblits, &dtors);
        TrackerHolder copied = TrackerHolder(1, source);

        assert(postblits == 1);
        assert(dtors == 0);
    }

    assert(dtors == 2);

    postblits = 0;
    dtors = 0;

    {
        TrackerHolder moved = TrackerHolder(2, makeTracker(&postblits, &dtors));
        TrackerHolder constructed =
            TrackerHolder(3, LifetimeTracker(&postblits, &dtors));

        assert(postblits == 0);
        assert(dtors == 0);
    }

    assert(dtors == 2);
}

struct Reading {
    int amount;

    this(int amount) {
        this.amount = amount;
    }
}

auto wrapReading(V)(auto ref V value) {
    return () { return Reading(value); }();
}

unittest {
    int measured = 5;
    auto reading = wrapReading(measured);

    assert(reading.amount == measured);
}

// Performance kernels. Each isolates one cost class and is sized so the
// tree-walking backends spend ~15 ms on it: enough for per-operation cost
// to dominate the per-test fixed cost, small enough to keep the default
// `bin/bench.sh` run short.

uint fibonacciKernel(uint i) {
    if (i < 2) return i;
    return fibonacciKernel(i - 1) + fibonacciKernel(i - 2);
}

// Call-heavy: ~29k calls.
@("kernel.calls") unittest {
    assert(fibonacciKernel(21) == 10_946);
}

// Loop-heavy over a buffer: 15k element reads and adds, no allocation.
@("kernel.loop") unittest {
    auto buf = new uint[](3_000);
    foreach (i, ref b; buf) b = cast(uint) i;
    ulong sum;
    foreach (_; 0 .. 5)
        foreach (b; buf) sum += b;
    assert(sum == 5UL * 4_498_500UL);
}

struct KernelPoint { int x; int y; }

// Struct copies through a slice: 6k element struct stores and loads.
@("kernel.structs") unittest {
    auto pts = new KernelPoint[](600);
    foreach (i, ref p; pts) p = KernelPoint(cast(int) i, cast(int) -i);
    long acc;
    foreach (_; 0 .. 10)
        foreach (p; pts) { const q = p; acc += q.x + q.y; }
    assert(acc == 0);
}

// Allocation-heavy: 1.5k appends through druntime.
@("kernel.append") unittest {
    ubyte[] bytes;
    foreach (i; 0 .. 1_500) bytes ~= cast(ubyte) i;
    assert(bytes.length == 1_500);
    assert(bytes[1_499] == cast(ubyte) 1_499);
}

unittest {
    assert(1 == 2);
}
