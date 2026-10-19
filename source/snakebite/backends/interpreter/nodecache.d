module snakebite.backends.interpreter.nodecache;

private:

// A direct-mapped cache from the address of an AST node (or type) to what
// the evaluator worked out about it on its first visit. A probe is one
// multiply, a shift, a load and a compare. A colliding key evicts the
// previous one, which only costs a recomputation.
public struct NodeCache(Value, size_t bits) {
    private struct Entry {
        const(void)* key;
        Value value;
    }

    private Entry[1 << bits] _entries;

    public Value* find(in void* key) @safe @nogc nothrow pure {
        auto entry = &_entries[indexOf(key)];
        return entry.key is key ? &entry.value : null;
    }

    public Value* insert(in void* key, in Value value)
        @safe @nogc nothrow pure
    {
        auto entry = &_entries[indexOf(key)];
        entry.key = key;
        entry.value = value;
        return &entry.value;
    }

    private static size_t indexOf(in void* key) @trusted @nogc nothrow pure {
        return ((cast(size_t) key >> 3) * 0x9E3779B97F4A7C15UL) >> (64 - bits);
    }
}
