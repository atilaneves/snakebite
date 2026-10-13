module snakebite.executionstates;


private:


import snakebite.hostthreads: heapDelete, heapNew, PerThread;


// Execution entries can outlive the owner through callbacks or suspended
// Fibers. Guest TLS has a separate lifetime because guest pointers can retain it.
public struct ExecutionStates(State) {
    private struct Core {
        State delegate() create;
        shared bool ended;
        void delegate() onIdle;
    }

    private struct Entry {
        State state;
        size_t depth;

        @disable this(this);

        this(State state) {
            this.state = state;
        }

        ~this() {
            heapDelete(state);
        }
    }

    private Core* _core;
    private PerThread!(Entry*, true) _entries;

    @disable this();
    @disable this(this);

    public this(State delegate() create, void delegate() onIdle) {
        _core = new Core;
        _core.create = create;
        _core.onIdle = onIdle;
        // Capture the core, not the movable handle.
        auto core = _core;
        _entries = PerThread!(Entry*, true)(() {
            auto state = core.create();
            scope(failure) heapDelete(state);
            return heapNew!Entry(state);
        });
    }

    version(unittest)
    public size_t count() {
        return _entries.count;
    }

    public struct Active {
        private ExecutionStates* _owner;
        private Entry* _entry;

        @disable this();
        @disable this(this);

        private this(ExecutionStates* owner, Entry* entry) {
            _owner = owner;
            _entry = entry;
        }

        public State state() {
            return _entry.state;
        }

        ~this() {
            import core.atomic: atomicLoad;

            --_entry.depth;
            if (atomicLoad(_owner._core.ended))
                _owner.releaseIdle;
        }
    }

    // Keep this handle at the same address until the returned guard ends.
    public Active enter() {
        auto entry = _entries.current;
        ++entry.depth;
        return Active(&this, entry);
    }

    // Other threads observe this flag on entry completion. No thread releases
    // another thread's state, and an active Fiber keeps its entry until return.
    public void end() {
        import core.atomic: atomicStore;

        atomicStore(_core.ended, true);
        releaseIdle;
    }

    private void releaseIdle() {
        if (_entries.release(&idle))
            _core.onIdle();
    }

    private static bool idle(Entry* entry) {
        return entry.depth == 0;
    }
}
