module snakebite.exception;


private:


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
