module snakebite.tlsstorage;


private:


import snakebite.internalfailure: internalFailure;


// A thread-local guest variable's compile-time-constant description
// (issue #40, ADR-0006, finding 1.3): the identity `TlsSlots.slotFor`
// keys this thread's own copy by, and the bytes every thread's copy
// starts from. Built once, under the compiler lock, by
// `snakebite.nativelayout.NativeData.tlsDescriptorOf`; read here with no
// lock, since nothing ever changes a `TlsDescriptor` after that.
//
// A thread-local variable's storage differs by thread, the same way a
// compiled D thread-local's does: compiled D reaches it through the
// thread pointer plus a fixed offset into the TLS segment, never through
// a linked absolute address. The bytecode compiler bakes a pointer to
// one of these into an `opTls*` instruction operand in place of a
// resolved storage address, so no instruction ever holds one thread's
// address as a constant every other thread would read or write through
// too.
//
// This module holds no dmd import, so the bytecode VM - which the
// project's coding guideline forbids from importing dmd - can resolve an
// `opTls*` operand without doing so.
public struct TlsDescriptor {
    public const(void)* key;
    public const(void)* templateBytes;
    public size_t size;
    // Set when the variable's storage is native (a dependency image's
    // own thread-local, or an `extern` one): the linker name that
    // `nativeAddress` resolves, on each thread, to that thread's copy in
    // the image's TLS block. No copy is made from a template then, so
    // native code and guest code on one thread reach the same bytes.
    public string nativeName;
    public void* delegate(in char[] name) nativeAddress;
}


// One thread's own copies of the thread-local guest variables it has
// touched, grown on demand. A `TlsSlots` belongs to exactly one thread -
// Fibers on that thread share it (ADR-0006), so `slotFor` takes no lock:
// nothing here is ever visible to another thread.
//
// The copies and the table that finds them live on the C heap and the GC
// scans each copy through `addRange`. The first touch of a variable can
// happen in a destructor that the GC finalizer runs, on a thread that never
// ran guest code, and a GC allocation is forbidden there; `addRange` takes
// no GC lock.
public struct TlsSlots {
    private struct Entry {
        const(void)* key;
        void* bytes;
        size_t size;
        bool owned;
    }

    private Entry[] _table;
    private size_t _count;

    @disable this(this);

    ~this() {
        import core.memory: GC;
        import core.stdc.stdlib: free;

        foreach (ref entry; _table) {
            if (entry.key is null || !entry.owned)
                continue;
            if (entry.size)
                GC.removeRange(entry.bytes);
            free(entry.bytes);
        }
        free(_table.ptr);
        _table = null;
        _count = 0;
    }

    // No copy that a guest pointer could reach was made.
    public bool empty() const {
        return _count == 0;
    }

    public void[] slotFor(const(TlsDescriptor)* descriptor) {
        if (auto found = find(descriptor.key))
            return found.bytes[0 .. found.size];

        Entry entry = Entry(descriptor.key);
        if (descriptor.nativeName.length) {
            // Resolved on this thread: a thread-local symbol's address
            // is the calling thread's own, so another thread's answer
            // would be that thread's copy.
            entry.bytes = descriptor.nativeAddress(descriptor.nativeName);
            assert(entry.bytes !is null, descriptor.nativeName);
        } else {
            import core.memory: GC;
            import core.stdc.stdlib: calloc;
            import core.stdc.string: memcpy;

            entry.bytes = calloc(1, descriptor.size ? descriptor.size : 1);
            if (entry.bytes is null)
                internalFailure("out of memory for a thread-local variable");
            memcpy(entry.bytes, descriptor.templateBytes, descriptor.size);
            if (descriptor.size)
                GC.addRange(entry.bytes, descriptor.size);
            entry.owned = true;
        }
        entry.size = descriptor.size;
        insert(entry);
        return entry.bytes[0 .. entry.size];
    }

    private Entry* find(const(void)* key) {
        if (_table.length == 0)
            return null;
        const mask = _table.length - 1;
        for (auto at = hashOf(key) & mask; ; at = (at + 1) & mask) {
            if (_table[at].key is key)
                return &_table[at];
            if (_table[at].key is null)
                return null;
        }
    }

    private void insert(Entry entry) {
        // Keep the table at most half full so a probe always finds a gap.
        if ((_count + 1) * 2 > _table.length)
            grow;
        place(_table, entry);
        ++_count;
    }

    private void grow() {
        import core.stdc.stdlib: calloc, free;

        const length = _table.length ? _table.length * 2 : 8;
        auto memory = cast(Entry*) calloc(length, Entry.sizeof);
        if (memory is null)
            internalFailure("out of memory for a thread-local table");
        auto bigger = memory[0 .. length];
        foreach (entry; _table)
            if (entry.key !is null)
                place(bigger, entry);
        free(_table.ptr);
        _table = bigger;
    }

    private static void place(Entry[] table, Entry entry) {
        const mask = table.length - 1;
        auto at = hashOf(entry.key) & mask;
        while (table[at].key !is null)
            at = (at + 1) & mask;
        table[at] = entry;
    }
}
