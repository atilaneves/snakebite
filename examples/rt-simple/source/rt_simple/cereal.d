module rt_simple.cereal;

private:


public ubyte[] cerealise(T)(auto ref T value) {
    import core.stdc.string: memcpy;
    import std.range.primitives: ElementType;
    import std.traits: isDynamicArray;

    static if (isDynamicArray!T) {
        alias E = ElementType!T;

        const dataSize = value.length * E.sizeof;
        auto bytes = new ubyte[size_t.sizeof + dataSize];
        const length = value.length;
        memcpy(bytes.ptr, &length, length.sizeof);
        if (dataSize)
            memcpy(bytes.ptr + length.sizeof, value.ptr, dataSize);
        return bytes;
    } else {
        auto bytes = new ubyte[T.sizeof];
        memcpy(bytes.ptr, &value, value.sizeof);
        return bytes;
    }
}


public T decerealise(T)(in ubyte[] bytes) {
    import core.stdc.string: memcpy;
    import std.range.primitives: ElementType;
    import std.traits: isDynamicArray;

    static if (isDynamicArray!T) {
        alias E = ElementType!T;

        assert(bytes.length >= size_t.sizeof);
        size_t length;
        memcpy(&length, bytes.ptr, length.sizeof);
        assert(bytes.length == length.sizeof + length * E.sizeof);

        auto value = new E[length];
        if (length)
            memcpy(value.ptr, bytes.ptr + length.sizeof, length * E.sizeof);
        return value;
    } else {
        assert(bytes.length == T.sizeof);
        T value;
        memcpy(&value, bytes.ptr, value.sizeof);
        return value;
    }
}
