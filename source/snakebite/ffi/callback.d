module snakebite.ffi.callback;


private:


import core.sync.mutex: Mutex;


// This module is temporary support for the `rt-simple` callback. A proper,
// general FFI solution must replace the fixed entries, the global pool, and
// every `BoolFunction` type below. That solution must derive each entry from
// the callback's ABI signature instead of naming one D type.


// The fixed compiler-built entries available to all callback owners.
public enum boolFunctionEntryCount = 64;


// The first callback shape supported by the shared FFI layer.
public alias BoolFunction = extern(D) bool function();
// An entry calls this handler with the target state that its owner supplied.
public alias BoolFunctionHandler = extern(C) bool function(void*, void*);


// The state that one compiler-built entry needs to reach its backend.
public struct BoolFunctionTarget {
    public BoolFunctionHandler handler;
    public void* context;
    public void* function_;
}


private enum unusedEntry = size_t.max;


private struct Slot {
    BoolFunctionTarget target;
    bool used;
}


private __gshared Slot[boolFunctionEntryCount] slots;
private __gshared Mutex mutex;


shared static this() {
    mutex = new Mutex;
}


private bool invoke(in size_t index) {
    auto target = slots[index].target;
    if (target.handler is null)
        throw new Exception("ffi callback entry is no longer valid");

    return target.handler(target.context, target.function_);
}


private extern(D) bool entry(size_t index)() {
    return invoke(index);
}


private immutable BoolFunction[boolFunctionEntryCount] entries = () {
    BoolFunction[boolFunctionEntryCount] result;
    static foreach (i; 0 .. boolFunctionEntryCount)
        result[i] = &entry!i;
    return result;
}();


// The unique owner of one reserved compiler-built entry.
public struct BoolFunctionEntry {
    private size_t _index = unusedEntry;

    @disable this(this);

    public static BoolFunctionEntry reserve(BoolFunctionTarget target) {
        if (target.handler is null)
            throw new Exception("ffi callback target has no handler");

        mutex.lock;
        scope(exit) mutex.unlock;

        foreach (i; 0 .. slots.length) {
            if (slots[i].used)
                continue;

            slots[i] = Slot(target, true);
            return BoolFunctionEntry(i);
        }

        throw new Exception("ffi bool function callback pool is exhausted");
    }

    public BoolFunction address() const {
        if (_index == unusedEntry)
            throw new Exception("ffi callback entry is not reserved");

        return entries[_index];
    }

    public void release() {
        if (_index == unusedEntry)
            return;

        mutex.lock;
        scope(exit) mutex.unlock;

        slots[_index] = Slot.init;
        _index = unusedEntry;
    }
}
