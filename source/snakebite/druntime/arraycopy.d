module snakebite.druntime.arraycopy;


private:


// The host druntime owns array assignment checks and copying. Backends call
// this declaration with the guest values in native dynamic-array layout.
public extern(C) void[] _d_arraycopy(
    size_t elementSize,
    void[] from,
    void[] to,
) nothrow @trusted;
