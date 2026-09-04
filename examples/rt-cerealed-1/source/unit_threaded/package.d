module unit_threaded;

private:


public enum SingleThreaded;


public void writelnUt(T...)(auto ref T) {
}


public void check(alias F)() @safe {
    import std.traits: Parameters, ReturnType;

    static assert(Parameters!F.length == 1);
    static assert(is(ReturnType!F == bool));

    alias T = Parameters!F[0];

    foreach (_; 0 .. 100)
        assert(F(randomValue!T));
}


public void shouldEqual(T, U)(auto ref T actual, auto ref U expected) @safe {
    static if (is(T == class) || is(U == class)) {
        assert(equalClass(actual, expected));
    } else {
        assert(trustedEqual(actual, expected));
    }
}


// AA equality (`_d_aaEqual`) is `@system` in dmd 2.112 druntime and
// `@safe`/`@trusted` in 2.113. It does not do anything unsafe, so it
// is fine to trust here.
private bool trustedEqual(T, U)(auto ref T actual, auto ref U expected) @trusted {
    return cast(const) actual == cast(const) expected;
}


private bool equalClass(T, U)(T actual, U expected) @trusted {
    import std.traits: BaseClassesTuple, FieldNameTuple;

    if (actual is null || expected is null)
        return actual is null && expected is null;

    bool result = true;

    static foreach (name; FieldNameTuple!T)
        result = result && equalValue(__traits(getMember, actual, name),
                                      __traits(getMember, expected, name));

    static foreach (Base; BaseClassesTuple!T)
        result = result && equalClass(cast(Base) actual, cast(Base) expected);

    return result;
}


private bool equalValue(T, U)(auto ref T actual, auto ref U expected) @trusted {
    static if (is(T == class) && is(U == class))
        return equalClass(actual, expected);
    else
        return cast(const) actual == cast(const) expected;
}


public auto should(T)(lazy T expression) {
    struct Should {
        bool opEquals(U)(auto ref U expected) {
            expression.shouldEqual(expected);
            return true;
        }
    }

    return Should();
}


public void shouldNotEqual(T, U)(auto ref T actual, auto ref U expected) @safe {
    assert(!trustedEqual(actual, expected));
}


public void shouldBeTrue(T)(lazy T condition) @safe {
    assert(cast(bool) condition);
}


public void shouldThrow(E : Throwable = Exception, T)(lazy T expression) {
    bool threw;

    try {
        expression;
    } catch (E) {
        threw = true;
    }

    assert(threw);
}


public void shouldNotThrow(E : Throwable = Exception, T)(lazy T expression) {
    try {
        expression;
    } catch (E) {
        assert(false);
    }
}


public void shouldThrowWithMessage(E : Throwable = Exception, T)(
    lazy T expression,
    in string expected,
) {
    E thrown;

    try {
        expression;
    } catch (E exception) {
        thrown = exception;
    }

    assert(thrown !is null);
    assert(thrown.msg == expected);
}


private T randomValue(T)() @safe {
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


private ulong randomBits() @safe {
    static ulong state = 0x4d595df4d0f33173;
    state = state * 6_364_136_223_846_793_005UL + 1;
    return state;
}
