module snakebite.runtimeentry;


private:


// A program with a C entry starts and ends the runtime itself, with `rt_init`
// and `rt_term` or with the functions of `core.runtime.Runtime` that call
// them. The guest shares the runtime of the host, which the host started, so
// a guest reference to one of these functions binds to the function here
// that has the same type. For the program that is bound, the first start
// runs the module constructors and the last end runs the module destructors.
// With no program bound, the functions are druntime's own.
public struct RuntimeEntry {
    import core.runtime: Runtime;

    public alias Phase = extern(C) int function(void*);

    // The linker names of the functions, in the order of `druntime` and
    // `entries`.
    public enum symbols = [
        "rt_init",
        "rt_term",
        Runtime.initialize.mangleof,
        Runtime.terminate.mangleof,
    ];

    public static void*[symbols.length] druntime() {
        return [
            cast(void*) &rt_init,
            cast(void*) &rt_term,
            cast(void*) &Runtime.initialize,
            cast(void*) &Runtime.terminate,
        ];
    }

    public static void*[symbols.length] entries() {
        return [
            cast(void*) &initialize,
            cast(void*) &terminate,
            cast(void*) &runtimeInitialize,
            cast(void*) &runtimeTerminate,
        ];
    }

    // What a guest reference to the function at `address` binds to.
    public static void* route(void* address) {
        foreach (i, function_; druntime)
            if (address == function_)
                return entries[i];
        return address;
    }

    // `start` and `finish` run the module phases of the program of `owner`.
    // `token` is the path of a loadable file that nothing else loads: the
    // loader's reference count of it is the depth of the starts, as druntime
    // counts the depth of `rt_init`.
    public static void bind(
        void* owner, Phase start, Phase finish, const(char)* token,
    ) {
        _start = start;
        _finish = finish;
        _token = token;
        atomicStore(_succeeded, true);
        atomicStore(_pending, true);
        _owner = owner;
    }

    public static void unbind() {
        _owner = null;
        _start = null;
        _finish = null;
        _token = null;
    }
}


import core.atomic: atomicLoad, atomicStore, cas;


private extern(C) int initialize() {
    import core.sys.posix.dlfcn: dlclose, dlopen, RTLD_NOW;

    if (_owner is null)
        return rt_init;
    if (!rt_init)
        return 0;
    scope(exit) rt_term;
    auto handle = dlopen(_token, RTLD_NOW);
    if (handle is null)
        return 0;
    if (cas(&_pending, true, false))
        atomicStore(_succeeded, _start(_owner) != 0);
    if (atomicLoad(_succeeded))
        return 1;
    dlclose(handle);
    return 0;
}


private extern(C) int terminate() {
    import core.sys.posix.dlfcn: dlclose, dlopen, RTLD_NOLOAD, RTLD_NOW;

    if (_owner is null)
        return rt_term;
    auto handle = dlopen(_token, RTLD_NOW | RTLD_NOLOAD);
    if (handle is null)
        return 0;
    if (dlclose(handle) || dlclose(handle))
        return 0;
    auto remaining = dlopen(_token, RTLD_NOW | RTLD_NOLOAD);
    if (remaining !is null) {
        dlclose(remaining);
        return 1;
    }
    const result = _finish(_owner);
    atomicStore(_pending, true);
    return result;
}


private bool runtimeInitialize() {
    return initialize != 0;
}


private bool runtimeTerminate() {
    return terminate != 0;
}


private __gshared void* _owner;
private __gshared RuntimeEntry.Phase _start;
private __gshared RuntimeEntry.Phase _finish;
private __gshared const(char)* _token;
private shared bool _pending;
private shared bool _succeeded;


private extern(C) int rt_init();
private extern(C) int rt_term();
