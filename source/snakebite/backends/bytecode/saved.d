module snakebite.backends.bytecode.saved;


private:


// A compiled program as plain records and the file that holds them. This
// module imports nothing of the frontend: the bytecode VM compiles without
// it. A record names a process address by what it points at, so that the
// process that loads the file can put its own address in the same place.


// What a file that cannot be used says: another build, a damaged file, or a
// path that cannot be read.
public class SavedFileException: Exception {
    public this(string message) {
        super(message);
    }
}


public struct SavedProgram {
    public string programName;
}


// The file starts with the magic, the version of the format and the build ID
// of the `sb` that wrote it. A reader compares them before it decodes
// anything else, because the records name addresses of that very build.
public void writeSaved(
    in string path, in SavedProgram program, in immutable(ubyte)[] buildId,
) {
    import std.file: rename, write, remove, exists;
    import std.conv: text;

    ubyte[] bytes = cast(ubyte[]) magic.dup;
    bytes ~= encode(formatVersion);
    bytes ~= encode(buildId);
    bytes ~= encode(program);
    const temporary = text(path, ".part");
    scope(failure) if (temporary.exists) remove(temporary);
    write(temporary, bytes);
    rename(temporary, path);
}


public SavedProgram readSaved(
    in string path, in immutable(ubyte)[] buildId,
) {
    import std.file: exists, read;

    if (!path.exists)
        throw new SavedFileException(path ~ " does not exist");
    const(ubyte)[] bytes = cast(const(ubyte)[]) read(path);
    if (bytes.length < magic.length || bytes[0 .. magic.length] != magic)
        throw new SavedFileException(path ~ " is not a saved sb program");
    bytes = bytes[magic.length .. $];
    const damaged = path ~ " is truncated or damaged";
    ulong version_;
    ubyte[] savedBuildId;
    try {
        version_ = decode!ulong(bytes);
        savedBuildId = decode!(ubyte[])(bytes);
    } catch (SavedFileException) {
        throw new SavedFileException(damaged);
    }
    if (version_ != formatVersion || savedBuildId != buildId)
        throw new SavedFileException(path ~ " was saved by another build of sb");
    try
        return decode!SavedProgram(bytes);
    catch (SavedFileException)
        throw new SavedFileException(damaged);
}


private enum ubyte[8] magic = cast(ubyte[8]) "SBCFILE\0";
private enum ulong formatVersion = 1;


// Integers, bools, enums, arrays and structs of those. An array starts with
// its length as a `ulong`.
public ubyte[] encode(T)(in T value) {
    ubyte[] bytes;
    append(bytes, value);
    return bytes;
}


public T decode(T)(ref const(ubyte)[] bytes) {
    import std.traits: isArray, isIntegral, isFloatingPoint, OriginalType,
        Unqual;
    import core.stdc.string: memcpy;

    static if (is(T == enum))
        return cast(T) decode!(OriginalType!T)(bytes);
    else static if (is(T == bool) || isIntegral!T || isFloatingPoint!T) {
        if (bytes.length < T.sizeof)
            throw new SavedFileException("short read");
        Unqual!T result;
        memcpy(&result, bytes.ptr, T.sizeof);
        bytes = bytes[T.sizeof .. $];
        return result;
    } else static if (isArray!T) {
        alias Element = Unqual!(typeof(T.init[0]));
        const length = decode!ulong(bytes);
        // Every element takes at least a byte, so a length above what is left
        // is damage, and must not become an allocation.
        if (length > bytes.length)
            throw new SavedFileException("short read");
        auto result = new Element[cast(size_t) length];
        static if (is(Element == ubyte) || is(Element == char)) {
            if (length)
                memcpy(result.ptr, bytes.ptr, cast(size_t) length);
            bytes = bytes[cast(size_t) length .. $];
        } else
            foreach (ref element; result)
                element = decode!Element(bytes);
        return cast(T) result;
    } else static if (is(T == struct)) {
        Unqual!T result;
        static foreach (i, Field; typeof(result.tupleof))
            result.tupleof[i] = decode!Field(bytes);
        return result;
    } else
        static assert(false, "cannot decode " ~ T.stringof);
}


private void append(T)(ref ubyte[] bytes, in T value) {
    import std.traits: isArray, isIntegral, isFloatingPoint, OriginalType,
        Unqual;

    static if (is(T == enum))
        append(bytes, cast(OriginalType!T) value);
    else static if (is(T == bool) || isIntegral!T || isFloatingPoint!T)
        bytes ~= (cast(const(ubyte)*) &value)[0 .. T.sizeof];
    else static if (isArray!T) {
        append(bytes, cast(ulong) value.length);
        static if (is(Unqual!(typeof(value[0])) == ubyte)
                || is(Unqual!(typeof(value[0])) == char))
            bytes ~= cast(const(ubyte)[]) value;
        else
            foreach (element; value)
                append(bytes, element);
    } else static if (is(T == struct)) {
        static foreach (i, Field; typeof(value.tupleof))
            append(bytes, value.tupleof[i]);
    } else
        static assert(false, "cannot encode " ~ T.stringof);
}
