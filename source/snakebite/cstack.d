module snakebite.cstack;


private:


// A growable stack on the C heap, for state that a destructor run by the GC
// finalizer must push and pop: the GC forbids an allocation there, and
// shrinking a GC array and appending to it again allocates each time.
//
// The GC scans the items only when `scanned` is set. Otherwise each item can
// refer to GC memory only when something else keeps that memory alive.
public struct CStack(T, bool scanned = false) {
    private T* _items;
    private size_t _length;
    private size_t _capacity;

    @disable this(this);

    ~this() {
        release(_items, _capacity);
    }

    public size_t length() const {
        return _length;
    }

    public void push(T item) {
        if (_length == _capacity)
            grow;
        _items[_length++] = item;
    }

    // The new block is registered before the old one is unregistered: a
    // collection on another thread never scans a block that is freed.
    private void grow() {
        import core.stdc.stdlib: calloc;
        import core.stdc.string: memcpy;

        const capacity = _capacity ? _capacity * 2 : 64;
        auto grown = cast(T*) calloc(capacity, T.sizeof);
        if (grown is null)
            assert(0, "out of memory for a stack");
        static if (scanned) {
            import core.memory: GC;

            GC.addRange(grown, capacity * T.sizeof);
        }
        if (_items !is null)
            memcpy(grown, _items, _length * T.sizeof);
        release(_items, _capacity);
        _items = grown;
        _capacity = capacity;
    }

    private static void release(T* items, in size_t capacity) {
        import core.stdc.stdlib: free;

        if (items is null)
            return;
        static if (scanned) {
            import core.memory: GC;

            GC.removeRange(items);
        }
        free(items);
    }

    public void pop() {
        --_length;
    }

    // Drops every item from `length` on.
    public void truncate(in size_t length) {
        _length = length;
    }

    public ref inout(T) opIndex(in size_t index) inout {
        return _items[index];
    }

    public ref inout(T) back() inout {
        return _items[_length - 1];
    }

    public size_t opDollar() const {
        return _length;
    }

    public inout(T)[] opSlice() inout {
        return _items[0 .. _length];
    }

    public inout(T)[] opSlice(in size_t from, in size_t to) inout {
        assert(to <= _length);
        return _items[from .. to];
    }
}
