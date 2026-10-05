module snakebite.backends.temporarystack;

private:

import snakebite.cstack: CStack;


// Backend neutral state for expression-scoped destructors. The payload is
// owned by the caller: the interpreter uses a metadata index and bytecode
// uses a call-site index. This module has no DMD or backend execution types.
public struct TemporaryStack {
    private enum noEntry = size_t.max;

    public struct Entry {
        public void* address;
        public size_t payload;
        private ubyte _state;
        private enum armedFlag = 1;
        private enum startedFlag = 2;
        private enum consumedFlag = 4;
        private enum trackedFlag = 8;
        private enum ready = armedFlag | startedFlag;

        public this(void* address, in size_t payload, in bool armed)
        @nogc nothrow pure {
            this.address = address;
            this.payload = payload;
            _state = armed ? ready : 0;
        }

        public bool armed() const @safe @nogc nothrow pure {
            return (_state & armedFlag) != 0;
        }

        public void armed(in bool value) @safe @nogc nothrow pure {
            _state = cast(ubyte) (value ? _state | armedFlag : _state & ~armedFlag);
        }

        private bool _started() const @safe @nogc nothrow pure {
            return (_state & startedFlag) != 0;
        }

        private void _started(in bool value) @safe @nogc nothrow pure {
            _state = cast(ubyte) (value ? _state | startedFlag : _state & ~startedFlag);
        }

        private bool _consumed() const @safe @nogc nothrow pure {
            return (_state & consumedFlag) != 0;
        }

        private void _consumed(in bool value) @safe @nogc nothrow pure {
            _state = cast(ubyte) (value ? _state | consumedFlag : _state & ~consumedFlag);
        }
    }

    private struct Order {
        size_t order = noEntry;
        size_t node = noEntry;
        size_t previous = noEntry;
    }

    // A compressed radix tree bounds each path by the number of bits in
    // size_t, regardless of the number of values or nested destructors.
    // Registration maxima let cleanup exclude older marks on that path.
    private struct Node {
        size_t parent = noEntry;
        size_t left = noEntry;
        size_t right = noEntry;
        size_t bit = noEntry;
        size_t order;
        size_t registration;
        size_t maximum;
    }

    private CStack!Entry _entries;
    private CStack!Order _orders;
    private CStack!Node _nodes;
    private size_t _root = noEntry;
    private size_t _free = noEntry;
    private size_t _order;
    private size_t _latest = noEntry;
    private bool _indexed;

    public size_t mark() const @nogc nothrow pure {
        return _entries.length;
    }

    pragma(inline, true) public void registerTemporary(
        void* address,
        size_t payload,
        bool armed = false,
    ) @nogc {
        _entries.push(Entry(address, payload, armed));
        if (_orders.length != 0)
            registerTracked(armed);
    }

    private void registerTracked(in bool armed) @nogc {
        _orders.push(Order());
        _entries.back._state |= Entry.trackedFlag;
        if (armed) {
            const index = _entries.length - 1;
            _orders[index].order = nextOrder;
            _entries[index]._started = true;
            add(index, noEntry);
        }
    }

    pragma(inline, true) public void arm(void* address) @nogc {
        if (_entries.length && _entries.back.address is address
                && !(_entries.back._state & Entry.trackedFlag)) {
            _entries.back._state = Entry.ready;
            return;
        }
        armTracked(address);
    }

    private void armTracked(void* address) @nogc {
        size_t next = noEntry;
        foreach_reverse (index; 0 .. _entries.length) {
            if (!_entries[index]._consumed && _entries[index].address is address) {
                if (_entries[index].armed)
                    return;
                // A constructor's receiver starts before its arguments.
                // `suspend` records that order; completion must preserve it.
                if (!_entries[index]._started)
                    start(index);
                _entries[index].armed = true;
                if (_orders.length != 0)
                    add(index, next);
                return;
            }
            if (!_indexed && _entries[index].armed)
                next = index;
        }
    }

    private void start(in size_t index) @nogc {
        if (_orders.length == 0) {
            if (index == _entries.length - 1) {
                _entries[index]._started = true;
                return;
            }
            trackOrder;
        }
        _orders[index].order = nextOrder;
        _entries[index]._started = true;
    }

    private void trackOrder() @nogc {
        _latest = noEntry;
        _order = _entries.length;
        foreach (index; 0 .. _entries.length) {
            _orders.push(Order(_entries[index]._started ? index : noEntry));
            _entries[index]._state |= Entry.trackedFlag;
            if (_entries[index].armed)
                add(index, noEntry);
        }
    }

    private void add(in size_t index, in size_t next) @nogc {
        if (!_indexed) {
            const previous = next == noEntry
                ? _latest : _orders[next].previous;
            const order = _orders[index].order;
            if ((previous == noEntry || _orders[previous].order < order)
                && (next == noEntry || order < _orders[next].order)) {
                _orders[index].previous = previous;
                _orders[index].node = next;
                if (previous != noEntry)
                    _orders[previous].node = index;
                if (next != noEntry)
                    _orders[next].previous = index;
                else
                    _latest = index;
                return;
            }
            // Most expressions have the same lifetime and registration
            // order. Only a disagreement needs a marked order index.
            _indexed = true;
            auto current = _latest;
            while (current != noEntry) {
                const prior = _orders[current].previous;
                insert(current);
                current = prior;
            }
            _latest = noEntry;
        }
        insert(index);
    }

    private size_t nextOrder() @nogc nothrow pure {
        assert(_order != noEntry);
        return _order++;
    }

    private void insert(in size_t index) @nogc {
        import core.bitop: bsr;

        const order = _orders[index].order;
        const leaf = allocate(Node(
            noEntry, noEntry, noEntry, noEntry, order, index, index + 1,
        ));
        _orders[index].node = leaf;
        if (_root == noEntry) {
            _root = leaf;
            return;
        }
        auto match = _root;
        while (_nodes[match].bit != noEntry)
            match = childFor(match, order);
        const bit = cast(size_t) bsr(order ^ _nodes[match].order);
        auto child = _root;
        while (_nodes[child].bit != noEntry && _nodes[child].bit > bit)
            child = childFor(child, order);
        const parent = _nodes[child].parent;
        const right = (order & (size_t(1) << bit)) != 0;
        const branch = allocate(Node(
            parent, right ? child : leaf, right ? leaf : child, bit,
        ));
        _nodes[child].parent = branch;
        _nodes[leaf].parent = branch;
        if (parent == noEntry)
            _root = branch;
        else if (_nodes[parent].right == child)
            _nodes[parent].right = branch;
        else
            _nodes[parent].left = branch;
        refresh(branch);
    }

    private size_t childFor(in size_t node, in size_t order) const @nogc nothrow pure {
        return order & (size_t(1) << _nodes[node].bit)
            ? _nodes[node].right : _nodes[node].left;
    }

    private size_t allocate(Node node) @nogc {
        if (_free == noEntry) {
            _nodes.push(node);
            return _nodes.length - 1;
        }
        const index = _free;
        _free = _nodes[index].left;
        _nodes[index] = node;
        return index;
    }

    private void release(in size_t index) @nogc nothrow pure {
        _nodes[index].left = _free;
        _free = index;
    }

    private void refresh(size_t node) @nogc nothrow pure {
        import std.algorithm.comparison: max;

        while (node != noEntry) {
            _nodes[node].maximum = max(
                _nodes[_nodes[node].left].maximum,
                _nodes[_nodes[node].right].maximum,
            );
            node = _nodes[node].parent;
        }
    }

    private void remove(in size_t index) @nogc nothrow pure {
        if (!_indexed) {
            if (index == _latest) {
                _latest = _orders[index].previous;
                return;
            }
            const previous = _orders[index].previous;
            const next = _orders[index].node;
            if (previous != noEntry)
                _orders[previous].node = next;
            if (next != noEntry)
                _orders[next].previous = previous;
            else
                _latest = previous;
            _orders[index].node = noEntry;
            return;
        }
        removeIndexed(index);
    }

    private void removeIndexed(in size_t index) @nogc nothrow pure {
        const leaf = _orders[index].node;
        const parent = _nodes[leaf].parent;
        if (parent == noEntry) {
            _root = noEntry;
        } else {
            const sibling = _nodes[parent].left == leaf
                ? _nodes[parent].right : _nodes[parent].left;
            const grandparent = _nodes[parent].parent;
            _nodes[sibling].parent = grandparent;
            if (grandparent == noEntry)
                _root = sibling;
            else if (_nodes[grandparent].left == parent)
                _nodes[grandparent].left = sibling;
            else
                _nodes[grandparent].right = sibling;
            release(parent);
            refresh(grandparent);
        }
        release(leaf);
        _orders[index].node = noEntry;
    }

    pragma(inline, true) public void suspend(void* address) @nogc {
        if (_entries.length && _entries.back.address is address
                && !(_entries.back._state & Entry.trackedFlag)) {
            _entries.back._state = Entry.startedFlag;
            return;
        }
        suspendTracked(address);
    }

    private void suspendTracked(void* address) @nogc {
        foreach_reverse (index; 0 .. _entries.length)
            if (!_entries[index]._consumed && _entries[index].address is address) {
                start(index);
                if (_entries[index].armed && _orders.length != 0)
                    remove(index);
                _entries[index].armed = false;
                return;
            }
    }

    public void finish(T)(
        in size_t mark_,
        scope void delegate(in T) destroy,
    ) if (is(T == Entry) || is(T == size_t)) {
        while (_entries.length > mark_) {
            if (_entries.back._state != Entry.ready) {
                if (_orders.length == 0)
                    trackOrder;
                finishTracked(mark_, destroy);
                return;
            }
            const entry = _entries.back;
            _entries.pop;
            scope (failure) finish(mark_, destroy);
            static if (is(T == Entry))
                destroy(entry);
            else
                destroy(entry.payload);
        }
    }

    private void finishTracked(T)(
        in size_t mark_,
        scope void delegate(in T) destroy,
    ) {
        for (;;) {
            if (_orders.length == 0) {
                if (_entries.length <= mark_)
                    break;
                if (!_entries.back.armed) {
                    trackOrder;
                    continue;
                }
                const entry = _entries.back;
                _entries.pop;
                _latest = noEntry;
                if (entry.armed) {
                    scope (failure) finish(mark_, destroy);
                    static if (is(T == Entry))
                        destroy(entry);
                    else
                        destroy(entry.payload);
                }
                continue;
            }
            const index = latestArmed(mark_);
            if (index == noEntry)
                break;
            const entry = _entries[index];
            _entries[index].armed = false;
            _entries[index]._consumed = true;
            remove(index);
            if (index == _entries.length - 1) {
                _entries.pop;
                _orders.pop;
                if (_entries.length == 0) {
                    _indexed = false;
                    _order = 0;
                }
            }
            // A throwing destructor must not strand older completed values.
            scope (failure) finish(mark_, destroy);
            static if (is(T == Entry))
                destroy(entry);
            else
                destroy(entry.payload);
        }
        _entries.truncate(mark_);
        if (_orders.length != 0)
            _orders.truncate(mark_);
        if (mark_ == 0) {
            _order = 0;
            _indexed = false;
            _latest = noEntry;
        }
    }

    private size_t latestArmed(in size_t mark_) const @nogc nothrow pure {
        if (!_indexed)
            return _latest != noEntry && _latest >= mark_ ? _latest : noEntry;
        return latestIndexed(mark_);
    }

    private size_t latestIndexed(in size_t mark_) const @nogc nothrow pure {
        if (_root == noEntry || _nodes[_root].maximum <= mark_)
            return noEntry;
        size_t node = _root;
        while (_nodes[node].bit != noEntry)
            node = _nodes[_nodes[node].right].maximum > mark_
                ? _nodes[node].right : _nodes[node].left;
        return _nodes[node].registration;
    }
}
