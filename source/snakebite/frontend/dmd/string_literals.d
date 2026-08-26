module snakebite.frontend.dmd.string_literals;

private:

private enum charCodeUnitWidth = 1;
private enum wcharCodeUnitWidth = 2;
private enum dcharCodeUnitWidth = 4;
private enum maxUtf8CodeUnits = 4;

// The literal's code units at their declared element width: `wchar`/`dchar`
// units verbatim, `char` units as UTF-8 bytes (already 1 byte wide, so no
// transcoding). Callers that store the result verbatim in a byte-addressed
// segment (rather than decoding it) get width-faithful bytes regardless of
// the literal's element type.
public const(ubyte)[] stringCodeUnitBytes(
    imported!"dmd.expression".StringExp string_,
) {
    switch (string_.sz) {
        case wcharCodeUnitWidth:
            return cast(const(ubyte)[]) stringCodeUnits!wchar(string_);
        case dcharCodeUnitWidth:
            return cast(const(ubyte)[]) stringCodeUnits!dchar(string_);
        default:
            return cast(const(ubyte)[]) stringChars(string_);
    }
}

public T[] stringCodeUnits(T)(
    imported!"dmd.expression".StringExp string_,
) {
    T[] values;
    foreach (index; 0 .. string_.numberOfCodeUnits)
        values ~= cast(T) string_.getIndex(index);

    return values;
}

public char[] stringChars(
    imported!"dmd.expression".StringExp string_,
) {
    import std.utf: encode;

    char[] values;
    foreach (index; 0 .. string_.numberOfCodeUnits) {
        const codeUnit = string_.getIndex(index);
        if (string_.sz == charCodeUnitWidth) {
            values ~= cast(char) codeUnit;
        } else {
            char[maxUtf8CodeUnits] encoded;
            const length = encode(encoded, cast(dchar) codeUnit);
            values ~= encoded[0 .. length];
        }
    }

    return values;
}
