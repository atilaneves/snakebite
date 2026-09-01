module cerealed;


public import cerealed.utils;


public struct Cerealiser {
    private ubyte[] _bytes;

    public const(ubyte)[] bytes() const @property @safe pure nothrow {
        return _bytes;
    }

    public void grain(Length = size_t, T)(auto ref T value) @trusted {
        import core.stdc.string: memcpy;
        import std.range.primitives: ElementType;
        import std.traits: isDynamicArray;

        static if (isDynamicArray!T) {
            alias E = ElementType!T;

            const length = cast(Length) value.length;
            assert(length == value.length);
            grain(length);

            const oldLength = _bytes.length;
            const dataSize = value.length * E.sizeof;
            _bytes.length += dataSize;
            if (dataSize)
                memcpy(_bytes.ptr + oldLength, value.ptr, dataSize);
        } else {
            const oldLength = _bytes.length;
            _bytes.length += T.sizeof;
            memcpy(_bytes.ptr + oldLength, &value, value.sizeof);
        }
    }
}


public struct Decerealiser {
    private const(ubyte)[] _bytes;

    public this(in ubyte[] bytes) @safe pure nothrow {
        _bytes = bytes;
    }

    public const(ubyte)[] bytes() const @property @safe pure nothrow {
        return _bytes;
    }

    public void grain(Length = size_t, T)(ref T value) @trusted {
        import core.stdc.string: memcpy;
        import std.range.primitives: ElementType;
        import std.traits: isDynamicArray;

        static if (isDynamicArray!T) {
            alias E = ElementType!T;

            Length length;
            grain(length);

            const dataSize = length * E.sizeof;
            assert(_bytes.length >= dataSize);
            value = new E[length];
            if (dataSize)
                memcpy(value.ptr, _bytes.ptr, dataSize);
            _bytes = _bytes[dataSize .. $];
        } else {
            assert(_bytes.length >= T.sizeof);
            memcpy(&value, _bytes.ptr, value.sizeof);
            _bytes = _bytes[T.sizeof .. $];
        }
    }
}


public ubyte[] cerealise(T)(auto ref T value) {
    auto cerealiser = Cerealiser();
    cerealiser.grain(value);
    return cerealiser.bytes.dup;
}


public T decerealise(T)(in ubyte[] bytes) {
    auto cerealiser = Decerealiser(bytes);
    T value;
    cerealiser.grain(value);
    assert(cerealiser.bytes.length == 0);
    return value;
}
