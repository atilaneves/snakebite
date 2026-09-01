module snakebite.ffi.callback;


private:


import core.sync.mutex: Mutex;


public alias CallbackHandler = extern(C) void function(
    void*,
    void*,
    void**,
    size_t,
);


public struct CallbackTarget {
    public CallbackHandler handler;
    public void* context;
}


public enum CallbackSignature {
    intToInt,
    doubleToDouble,
}


private enum slotCount = 64;
private enum unusedSlot = size_t.max;

private alias IntFunction = extern(C) int function(int);
private alias DoubleFunction = extern(C) double function(double);


private struct Slot {
    CallbackHandler handler;
    void* context;
    bool used;
}


private __gshared Slot[slotCount] slots;
private __gshared Mutex mutex;


shared static this() {
    mutex = new Mutex;
}


// The slot number is part of each entry point, so a callback needs no
// executable memory of its own. These are the two shapes measured by the
// race; the target remains independent of both.
private extern(C) int invokeInt(size_t index, int value) {
    auto slot = &slots[index];
    int result;
    void*[1] arguments = [cast(void*) &value];
    slot.handler(
        slot.context,
        cast(void*) &result,
        arguments.ptr,
        arguments.length,
    );
    return result;
}


private extern(C) double invokeDouble(size_t index, double value) {
    auto slot = &slots[index];
    double result;
    void*[1] arguments = [cast(void*) &value];
    slot.handler(
        slot.context,
        cast(void*) &result,
        arguments.ptr,
        arguments.length,
    );
    return result;
}


private string makeTrampolines(string prefix, string returnType,
    string invokeName)
{
    import std.conv: text;

    string result;
    foreach (i; 0 .. slotCount)
        result ~= "private extern(C) " ~ returnType ~ " " ~ prefix ~
            text(i) ~ "(" ~ returnType ~ " value) { return " ~
            invokeName ~ "(" ~ text(i) ~ ", value); }\n";
    return result;
}


mixin(makeTrampolines("callbackIntTrampoline", "int", "invokeInt"));
mixin(makeTrampolines("callbackDoubleTrampoline", "double", "invokeDouble"));


private string makeTrampolineTable(
    string tableName,
    string prefix,
    string elementType,
) {
    import std.conv: text;

    string result = "private " ~ elementType ~ "[slotCount] " ~ tableName ~
        " = [";
    foreach (i; 0 .. slotCount) {
        if (i != 0)
            result ~= ", ";
        result ~= "&" ~ prefix ~ text(i);
    }
    return result ~ "];";
}


mixin(makeTrampolineTable(
    "intTrampolines", "callbackIntTrampoline", "IntFunction"));
mixin(makeTrampolineTable(
    "doubleTrampolines", "callbackDoubleTrampoline", "DoubleFunction"));


// A native callback. The target owns the interpreter context; this value
// keeps it reachable and reserves one fixed trampoline slot while native
// code may call the function pointer.
public struct Callback {
    private size_t _slot = unusedSlot;
    private CallbackTarget _target;
    private CallbackSignature _signature;

    @disable this(this);

    public this(
        CallbackTarget target,
        CallbackSignature signature,
    ) {
        mutex.lock;
        scope(exit) mutex.unlock;

        foreach (i; 0 .. slots.length) {
            if (slots[i].used)
                continue;

            slots[i] = Slot(target.handler, target.context, true);
            _slot = i;
            _target = target;
            _signature = signature;
            return;
        }

        throw new Exception("ffi callback trampoline pool is exhausted");
    }

    public ~this() {
        if (_slot == unusedSlot)
            return;

        mutex.lock;
        scope(exit) mutex.unlock;
        slots[_slot] = Slot.init;
        _slot = unusedSlot;
    }

    public void* functionPointer() const {
        assert(_slot != unusedSlot);
        final switch (_signature) with (CallbackSignature) {
            case intToInt:
                return cast(void*) intTrampolines[_slot];
            case doubleToDouble:
                return cast(void*) doubleTrampolines[_slot];
        }
    }
}
