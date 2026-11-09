module snakebite.backends.bytecode.handlermap;

// A hash table from the address of a handler to a value. It uses open
// addressing and never removes an entry, and it grows when it is half full.
// The null key marks a free slot, so it cannot be a key. A table does no
// locking: the owner builds it before threads read it, or reads and writes it
// under one lock.

import core.stdc.stdlib: calloc, free;

package struct HandlerMap(Key, Value) {
    @nogc nothrow:

    private struct Entry {
        Key key;
        Value value;
    }

    private enum initialCapacity = 1024;

    private Entry[] entries;
    private size_t count;

    // The value stored for `key`, or null.
    inout(Value)* find(in Key key) inout {
        if (entries.length == 0)
            return null;
        for (auto slot = slotOf(key); entries[slot].key !is null;
                slot = (slot + 1) & (entries.length - 1))
            if (entries[slot].key is key)
                return &entries[slot].value;
        return null;
    }

    // The value for `key`, which is `Value.init` for a new key; null when the
    // memory for the table is missing. `added` tells a new key.
    Value* insert(Key key, out bool added) {
        if ((count + 1) * 2 > entries.length && !grow)
            return null;
        auto slot = slotOf(key);
        while (entries[slot].key !is null && entries[slot].key !is key)
            slot = (slot + 1) & (entries.length - 1);
        added = entries[slot].key is null;
        if (added) {
            entries[slot].key = key;
            ++count;
        }
        return &entries[slot].value;
    }

    // Sets the value of `key`. False when the memory is missing.
    bool put(Key key, Value value) {
        bool added;
        auto place = insert(key, added);
        if (place is null)
            return false;
        *place = value;
        return true;
    }

    private size_t slotOf(in Key key) const {
        return ((cast(size_t) key * 0x9E37_79B9_7F4A_7C15UL) >> 20)
            & (entries.length - 1);
    }

    private bool grow() {
        const capacity = entries.length == 0
            ? initialCapacity : entries.length * 2;
        auto memory = cast(Entry*) calloc(capacity, Entry.sizeof);
        if (memory is null)
            return false;
        auto old = entries;
        entries = memory[0 .. capacity];
        foreach (ref entry; old)
            if (entry.key !is null) {
                auto slot = slotOf(entry.key);
                while (entries[slot].key !is null)
                    slot = (slot + 1) & (capacity - 1);
                entries[slot] = entry;
            }
        free(old.ptr);
        return true;
    }
}
