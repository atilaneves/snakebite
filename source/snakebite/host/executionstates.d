module snakebite.host.executionstates;


private:


import snakebite.host.threads: heapDelete, heapNew, PerThread;


// Execution entries can outlive the owner through callbacks or suspended
// Fibers. Guest TLS has a separate lifetime because guest pointers can retain it.
public struct ExecutionStates(State) {
    private struct Core {
        State delegate() create;
        shared bool ended;
        void delegate() onIdle;
        void delegate() onQuiet;
        // The entries that exist on all threads.
        shared size_t live;
        shared bool quiet;

        // Calls `onQuiet` once: when the owner has ended and no entry is
        // left on any thread, so no guest code of the owner is running or
        // suspended.
        void checkQuiet() {
            import core.atomic: atomicLoad, cas;

            if (onQuiet !is null && atomicLoad(ended) && atomicLoad(live) == 0
                    && cas(&quiet, false, true))
                onQuiet();
        }
    }

    private struct Entry {
        State state;
        size_t depth;
        Core* core;

        @disable this(this);

        this(State state, Core* core) {
            import core.atomic: atomicOp;

            this.state = state;
            this.core = core;
            atomicOp!"+="(core.live, 1);
        }

        ~this() {
            import core.atomic: atomicOp;

            heapDelete(state);
            atomicOp!"-="(core.live, 1);
            core.checkQuiet;
        }
    }

    private Core* _core;
    private PerThread!(Entry*, true) _entries;

    @disable this();
    @disable this(this);

    // `onQuiet`, when given, runs once on the thread that ends the last entry
    // of an ended owner, or on the thread that ends the owner when no entry
    // is left. It must not allocate from the GC or take a lock.
    public this(State delegate() create, void delegate() onIdle,
        void delegate() onQuiet = null)
    {
        _core = new Core;
        _core.create = create;
        _core.onIdle = onIdle;
        _core.onQuiet = onQuiet;
        // Capture the core, not the movable handle.
        auto core = _core;
        _entries = PerThread!(Entry*, true)(() {
            auto state = core.create();
            scope(failure) heapDelete(state);
            return heapNew!Entry(state, core);
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
        _core.checkQuiet;
    }

    private void releaseIdle() {
        if (_entries.release(&idle))
            _core.onIdle();
    }

    private static bool idle(Entry* entry) {
        return entry.depth == 0;
    }
}
