module snakebite.sharedtable;


private:

import core.atomic: atomicLoad, atomicStore, MemoryOrder;
import core.sync.mutex: Mutex;


// A hash table that every thread running guest code reads without a
// lock, and that only an insert locks (ADR-0006). It holds the caches a
// backend fills once per key on a slow path and reads on the hot path:
// frame layouts, call plans, type information, resolved symbols.
//
// An entry is never removed or overwritten. `insert` keeps the first
// value stored for a key and hands that value back, so two threads that
// build the same answer at the same time end up with the one answer.
// Every value lives on the heap and the table holds a pointer to it, so
// the pointer `find` returns stays valid and unique for the life of the
// table: a table that grows copies pointers, not values, and the storage
// it replaces stays alive for as long as a reader still points into it,
// because the GC owns both.
//
// A reader on storage that an insert has since replaced sees a snapshot
// that can miss the newest keys. It then reports a miss, and the caller
// takes the slow path, which looks again under the lock and finds the
// entry. That is the one cost of a lock-free read, and it is paid once
// per thread per key at most.
public struct SharedTable(Key, Value) {
    // A copy made after the first insert would share `Storage` with the
    // original until one copy grows, and then insert through the other
    // copy into storage nothing reads any more (finding 2.4). Every
    // struct that holds a `SharedTable` is disabled the same way, by
    // this propagating to it.
    @disable this(this);

    private struct Entry {
        Key key;
        Value* value;
        // Written last, with release order, after `key` and `value`: a
        // reader that loads it with acquire order sees both.
        bool ready;
    }

    private struct Storage {
        Entry[] entries;
        size_t used;
    }

    private Storage* _storage;
    private shared(Mutex) _lock;

    // This table's own insert lock, made the first time any thread
    // needs it and published for every later caller to reuse. Before
    // this, every `SharedTable` in the process shared one insert lock
    // (finding 9): a `PlanCache` miss in one backend waited on a
    // symbol-resolver miss in another, on paths that never call each
    // other and have nothing to do with one another. `bootstrapLock`
    // only ever guards the moment a table's own lock is being made,
    // never an insert itself, so creating two tables' locks at once on
    // two threads cannot make one wait for the other's insert.
    private Mutex lockOf() {
        if (auto existing = atomicLoad!(MemoryOrder.acq)(_lock))
            return cast(Mutex) existing;

        bootstrapLock.lock;
        scope(exit) bootstrapLock.unlock;
        if (_lock is null)
            atomicStore!(MemoryOrder.rel)(_lock, cast(shared(Mutex)) new Mutex);
        return cast(Mutex) _lock;
    }

    public Value* opBinaryRight(string op: "in")(Key key) {
        return find(key);
    }

    // Same lookup, callable on a `const` table (finding: DMD, unlike
    // LDC, needs this overload written out - it does not always accept
    // the mutable `in` above for a `const` instance). No lock, the same
    // as the mutable lookup; the pointer comes back `const` so a
    // `const` caller cannot write through it.
    public const(Value)* opBinaryRight(string op: "in")(Key key) const {
        return find(key);
    }

    // The value stored for `key`, or null.
    public Value* find(Key key) {
        auto storage = atomicLoad!(MemoryOrder.acq)(_storage);
        if (storage is null)
            return null;

        const mask = storage.entries.length - 1;
        auto index = hashOf(key) & mask;
        while (true) {
            auto entry = &storage.entries[index];
            if (!atomicLoad!(MemoryOrder.acq)(entry.ready))
                return null;
            if (same(entry.key, key))
                return entry.value;
            index = (index + 1) & mask;
        }
    }

    // The `const` twin of `find`, for a `const` table. The same
    // lock-free walk; the pointer it hands back is `const` so it stays
    // read-only for a caller that only has a `const` table.
    public const(Value)* find(Key key) const {
        auto storage = atomicLoad!(MemoryOrder.acq)(_storage);
        if (storage is null)
            return null;

        const mask = storage.entries.length - 1;
        auto index = hashOf(key) & mask;
        while (true) {
            auto entry = &storage.entries[index];
            if (!atomicLoad!(MemoryOrder.acq)(entry.ready))
                return null;
            if (same(entry.key, key))
                return entry.value;
            index = (index + 1) & mask;
        }
    }

    // Whether `key` has a stored value. `find`'s `const` overload could
    // answer this too, but a caller that only wants a yes/no should not
    // have to spell out and then throw away a pointer.
    public bool contains(Key key) const {
        auto storage = atomicLoad!(MemoryOrder.acq)(_storage);
        if (storage is null)
            return false;

        const mask = storage.entries.length - 1;
        auto index = hashOf(key) & mask;
        while (true) {
            auto entry = &storage.entries[index];
            if (!atomicLoad!(MemoryOrder.acq)(entry.ready))
                return false;
            if (same(entry.key, key))
                return true;
            index = (index + 1) & mask;
        }
    }

    // Stores `value` for `key` unless the key already has one, and
    // returns the value the table holds after this call.
    public Value* insert(Key key, Value value) {
        auto tableLock = lockOf();
        tableLock.lock;
        scope(exit) tableLock.unlock;

        if (auto found = find(key))
            return found;

        if (_storage is null
                || (_storage.used + 1) * 2 > _storage.entries.length)
            grow;

        // One element on the heap: `new Value` cannot make a box for a
        // class reference or an array.
        auto box = new Value[1];
        box[0] = value;
        auto stored = box.ptr;
        const mask = _storage.entries.length - 1;
        auto index = hashOf(key) & mask;
        while (_storage.entries[index].ready)
            index = (index + 1) & mask;
        auto entry = &_storage.entries[index];
        entry.key = key;
        entry.value = stored;
        atomicStore!(MemoryOrder.rel)(entry.ready, true);
        // `length` (below) reads this with `atomicLoad` from any thread
        // while this insert - the only writer, under `lock` - is still
        // running: a plain `++` would be a formal data race with that
        // read even though no other insert can be running at the same
        // time (finding 2.5). Reading it back with `atomicLoad` too
        // keeps every access to `used` atomic, with no bare read or
        // write anywhere.
        const before = atomicLoad!(MemoryOrder.raw)(_storage.used);
        atomicStore!(MemoryOrder.rel)(_storage.used, before + 1);
        return stored;
    }

    // The number of keys stored.
    public size_t length() const {
        auto storage = atomicLoad!(MemoryOrder.acq)(_storage);
        return storage is null
            ? 0 : atomicLoad!(MemoryOrder.raw)(storage.used);
    }

    private void grow() {
        enum initialLength = 16;
        auto grown = new Storage;
        grown.entries = new Entry[
            _storage is null ? initialLength : _storage.entries.length * 2];
        if (_storage !is null) {
            const mask = grown.entries.length - 1;
            foreach (ref entry; _storage.entries) {
                if (!entry.ready)
                    continue;
                auto index = hashOf(entry.key) & mask;
                while (grown.entries[index].ready)
                    index = (index + 1) & mask;
                grown.entries[index] = entry;
            }
            grown.used = _storage.used;
        }
        atomicStore!(MemoryOrder.rel)(_storage, grown);
    }

    private static size_t hashOf(Key key) {
        static if (is(Key == class) || is(Key : const(void)*)) {
            // A pointer's low bits are alignment, and its high bits are
            // the same for every allocation. Mix them so that the low
            // bits of the hash differ between nearby addresses.
            auto bits = cast(size_t) cast(const(void)*) key;
            bits ^= bits >> 32;
            bits *= 0x9E37_79B9_7F4A_7C15UL;
            return bits ^ (bits >> 29);
        } else {
            return object.hashOf(key);
        }
    }

    private static bool same(const Key left, const Key right) {
        static if (is(Key == class) || is(Key : const(void)*))
            return left is right;
        else
            return left == right;
    }
}


// Guards only the moment a `SharedTable` makes its own insert lock
// (`lockOf`), never an insert itself: every table gets a lock of its
// own (finding 9), and this one is held for as long as `new Mutex`
// takes, nothing more.
private __gshared Mutex bootstrapLock;

shared static this() {
    bootstrapLock = new Mutex;
}
