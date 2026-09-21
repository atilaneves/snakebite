module snakebite.backends.temporarystack;

private:


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

    public void finish(
        in size_t mark_,
        scope void delegate(in Entry) destroy,
    ) {
        while (_entries.length > mark_) {
            const entry = _entries[$ - 1];
            _entries = _entries[0 .. $ - 1];
            if (!entry.armed)
                continue;
            // A throwing destructor must not strand older completed values.
            scope (failure) finish(mark_, destroy);
            destroy(entry);
        }
    }
}
