module unit_threaded;

private:


public void check(alias F)() {
    import std.traits: Parameters, ReturnType;

    static assert(Parameters!F.length == 1);
    static assert(is(ReturnType!F == bool));

    alias T = Parameters!F[0];

    foreach (_; 0 .. 100)
        assert(F(randomValue!T));
}


private T randomValue(T)() {
    import std.range.primitives: ElementType;
    import std.traits: isDynamicArray, isFloatingPoint, isIntegral, isSomeChar;

    static if (is(T == bool)) {
        return (randomBits & 1) == 1;
    } else static if (isSomeChar!T) {
        return cast(T) (randomBits % (cast(ulong) T.max + 1));
    } else static if (isIntegral!T) {
        return cast(T) randomBits;
    } else static if (isFloatingPoint!T) {
        return cast(T) (randomBits % 2_000_001) / 1_000_000 - 1;
    } else static if (isDynamicArray!T) {
        T value;
        value.length = randomBits % 33;
        foreach (ref element; value)
            element = randomValue!(ElementType!T);
        return value;
    } else {
        static assert(false, "Cannot generate a random " ~ T.stringof);
    }
}


private ulong randomBits() {
    static ulong state = 0x4d595df4d0f33173;
    state = state * 6_364_136_223_846_793_005UL + 1;
    return state;
}
