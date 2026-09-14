module snakebite.backends.temporarystack;


// Backend neutral state for expression-scoped destructors. The payload is
// owned by the caller: the interpreter uses a metadata index and bytecode
// uses a call-site index. This module has no DMD or backend execution types.
public struct TemporaryStack {
    public struct Entry {
        public void* address;
        public size_t payload;
        public bool armed;
    }

    private Entry[] _entries;

    public size_t mark() const {
        return _entries.length;
    }

    public void registerTemporary(
        void* address,
        size_t payload,
        bool armed = false,
    ) {
        _entries ~= Entry(address, payload, armed);
    }

    public void arm(void* address) {
        foreach_reverse (ref entry; _entries)
            if (entry.address is address) {
                entry.armed = true;
                return;
            }
    }

    public void suspend(void* address) {
        foreach_reverse (ref entry; _entries)
            if (entry.address is address) {
                entry.armed = false;
                return;
            }
    }

    public const(Entry) back() const {
        assert(_entries.length != 0);
        return _entries[$ - 1];
    }

    public const(Entry)[] entries() const {
        return _entries;
    }

    public void pop() {
        assert(_entries.length != 0);
        _entries.length -= 1;
    }

    public void discard(in size_t mark_) {
        assert(mark_ <= _entries.length);
        _entries.length = mark_;
    }
}
