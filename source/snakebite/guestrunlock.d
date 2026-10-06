module snakebite.guestrunlock;


// The lock of guest runs. It also guards the process's runner hooks, which a
// guest run installs and an image load clears. It lives in a module of its
// own because both of those import this one and neither may import the other.
public imported!"core.sync.mutex".Mutex guestRunLock() {
    return _guestRunLock;
}


private __gshared imported!"core.sync.mutex".Mutex _guestRunLock;
// The lock is held while the guest runs. A guest that calls `exit` ends the
// process with it held, and a GC object would then abort when druntime
// finalizes it, so the lock lives in static storage.
private __gshared align(16) ubyte[
    __traits(classInstanceSize, imported!"core.sync.mutex".Mutex)
] _guestRunLockStorage;

shared static this() {
    import core.sync.mutex: Mutex;
    import core.lifetime: emplace;

    _guestRunLock = emplace!Mutex(_guestRunLockStorage[]);
}
