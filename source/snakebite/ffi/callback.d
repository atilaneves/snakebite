module snakebite.ffi.callback;


private:


import core.sync.mutex: Mutex;
import snakebite.exception: SnakebiteException;


// The fixed compiler-built entries available to all callback owners.
public enum boolFunctionEntryCount = 64;


// The callback shape currently supported by the Barrier. Keeping this policy
// here makes both backends reject the same declarations before host code can
// jump to them.
public bool supportsBoolFunction(
    imported!"dmd.func".FuncDeclaration function_,
) {
    import dmd.astenums: LINK, Tbool;

    if (function_ is null)
        return false;
    auto type = function_.type.isTypeFunction;
    if (type is null)
        return false;

    const linkage = function_.resolvedLinkage;
    return type.parameterList.length == 0
        && type.next.ty == Tbool
        && (linkage == LINK.d || linkage == LINK.default_);
}


// An entry calls this handler with the target state that its owner supplied.
public alias BoolFunctionHandler = extern(C) bool function(void*, void*);


// The address that host code calls. It has the same ABI as the supported
// guest callback shape, so a guest callback crosses the Barrier without a
// host-side representation.
private alias BoolFunction = extern(D) bool function();


private struct BoolFunctionTarget {
    BoolFunctionHandler handler;
    void* context;
    void* function_;
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


// The unique owner of one reserved compiler-built entry. CallbackBridge is
// the public seam, so this lifetime detail cannot leak into a backend.
private struct BoolFunctionEntry {
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


// A raw function-pointer word that the backend has already established is a
// guest declaration. The backend-specific ownership check stays an adapter;
// all ABI inspection and host argument rewriting stay behind this seam.
public alias GuestFunction = imported!"dmd.func".FuncDeclaration;
public alias GuestFunctionPredicate = extern(C) bool function(
    void*, GuestFunction,
);


public final class CallbackBridge {
    private BoolFunctionHandler _handler;
    private void* _context;
    private GuestFunctionPredicate _isGuest;
    private void* _owner;
    private string _backendName;
    private BoolFunctionEntry[GuestFunction] _entries;

    public this(
        BoolFunctionHandler handler,
        void* context,
        GuestFunctionPredicate isGuest,
        void* owner,
        string backendName,
    ) {
        if (handler is null || isGuest is null)
            throw new Exception("ffi callback bridge has no target");

        _handler = handler;
        _context = context;
        _isGuest = isGuest;
        _owner = owner;
        _backendName = backendName;
    }

    public ~this() {
        release;
    }

    // Releases every entry owned by this backend. Backends call this from
    // their own lifetime hook because host code may retain the bridge's
    // executable addresses until the backend is disposed.
    public void release() {
        foreach (ref entry_; _entries.byValue)
            entry_.release;
        _entries = null;
    }

    // Returns one stable executable identity for each guest declaration.
    // Repeated conversions of the same declaration therefore compare equal
    // in host code, while different declarations remain distinct.
    public void* address(GuestFunction function_) {
        if (!supportsBoolFunction(function_))
            throw new Exception("ffi callback declaration has unsupported "
                ~ "signature");

        if (auto existing = function_ in _entries)
            return cast(void*) existing.address;

        auto target = BoolFunctionTarget(
            _handler,
            _context,
            cast(void*) function_,
        );
        _entries[function_] = BoolFunctionEntry.reserve(target);
        return cast(void*) _entries[function_].address;
    }

    // Values are returned in a fixed-size holder so callback addresses stay
    // alive while the prepared call consumes them. The caller only learns
    // the one slice needed by CallPlan.
    public void adaptArguments(
        GuestFunction hostFunction,
        scope const(void*)[] arguments,
        ref CallbackArguments result,
    ) {
        import snakebite.ffi.limits: maxArguments;

        if (arguments.length > maxArguments)
            throw new Exception("ffi callback arguments exceed the limit");

        result._length = arguments.length;
        foreach (i; 0 .. result._length)
            result._arguments[i] = cast(void*) arguments[i];
        adapt(hostFunction, arguments, result);
    }

    private void* callbackAddress(
        GuestFunction hostFunction,
        GuestFunction callback,
        bool indirect,
    ) {
        import std.conv: text;

        if (indirect)
            throw new SnakebiteException(
                text(_backendName, " cannot call `", hostFunction.toString,
                    "` with a guest function pointer through a `ref` "
                    ~ "or `out` parameter (see issue #9)"),
            );

        if (!supportsBoolFunction(callback))
            throw new SnakebiteException(
                text(_backendName, " cannot call `", hostFunction.toString,
                    "` with `", callback.toString,
                    "` as a function pointer argument: callback signature `",
                    callback.type.toString,
                    "` is not supported (see issue #9)"),
            );

        return address(callback);
    }

    private void adapt(
        GuestFunction hostFunction,
        scope const(void*)[] arguments,
        ref CallbackArguments result,
    ) {
        import dmd.astenums: STC;
        import snakebite.nativelayout: loadIntegral;

        auto type = hostFunction.type.isTypeFunction;
        assert(type !is null);

        size_t index = hostFunction.vthis !is null ? 1 : 0;
        foreach (i; 0 .. type.parameterList.length) {
            if (index >= arguments.length)
                break;

            auto parameter = type.parameterList[i];
            const argumentIndex = index++;
            auto pointer = parameter.type.isTypePointer;
            if (pointer is null || pointer.next.isTypeFunction is null)
                continue;

            const indirect =
                (parameter.storageClass & (STC.ref_ | STC.out_)) != 0;
            auto callbackPlace = indirect
                ? cast(const(void)*) loadIntegral(
                    arguments[argumentIndex], size_t.sizeof, false,
                )
                : arguments[argumentIndex];
            if (callbackPlace is null)
                continue;
            const raw = loadIntegral(
                callbackPlace, size_t.sizeof, false);
            if (raw == 0)
                continue;

            auto candidate = cast(GuestFunction) cast(void*) raw;
            if (!_isGuest(_owner, candidate))
                continue;

            result._addresses[argumentIndex] = cast(size_t)
                callbackAddress(hostFunction, candidate, indirect);
            result._arguments[argumentIndex] =
                &result._addresses[argumentIndex];
        }
    }
}


public struct CallbackArguments {
    private void*[imported!"snakebite.ffi.limits".maxArguments]
        _arguments;
    private size_t[imported!"snakebite.ffi.limits".maxArguments]
        _addresses;
    private size_t _length;

    public scope const(void*)[] values() {
        return _arguments[0 .. _length];
    }
}
