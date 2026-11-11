module snakebite.failure.report;


private:


// A terminal failure cannot expose a side effect to a caller that resumes.
// The cast adds pure only to this non-returning call, not to a general I/O
// function. The reporter borrows valid slices and never changes their bytes.
public noreturn internalFailure(
    in string message = "internal invariant failed",
    in string file = __FILE__,
    in size_t line = __LINE__,
) @trusted pure nothrow @nogc {
    alias Terminal = noreturn function(in string, in string, in size_t)
        pure nothrow @nogc;
    (cast(Terminal) &reportFailure)(message, file, line);
}


private noreturn reportFailure(
    in string message, in string file, in size_t line,
) nothrow @nogc {
    import core.stdc.stdio: fprintf, stderr, fwrite, fflush;
    import core.stdc.stdlib: _Exit, EXIT_FAILURE;

    fwrite("snakebite: internal failure at ".ptr, 1,
        "snakebite: internal failure at ".length, stderr);
    fwrite(file.ptr, 1, file.length, stderr);
    fprintf(stderr, ":%zu: ", line);
    fwrite(message.ptr, 1, message.length, stderr);
    fwrite("\n".ptr, 1, 1, stderr);
    fflush(stderr);
    _Exit(EXIT_FAILURE);
}


// Snakebite's own failure type: a refusal or fault in snakebite itself,
// as opposed to anything a guest program throws. A host that catches this
// knows snakebite could not run the guest, not that the guest failed.
public final class SnakebiteException: Exception {
    public this(
        string message,
        string file = __FILE__,
        size_t line = __LINE__,
    ) @safe @nogc nothrow pure scope {
        super(message, file, line);
    }
}
