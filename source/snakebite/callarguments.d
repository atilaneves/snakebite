module snakebite.callarguments;


private:


// Owns argument-address storage until the call returns. No slice points
// into the local buffer until values is read, so returning the owner by
// value does not leave a pointer into a previous stack frame.
public struct CallArguments {
    private const(void)*[16] _local;
    private const(void)*[] _overflow;
    private size_t _length;

    public this(in size_t length) @safe pure nothrow {
        _length = length;
        if (length > _local.length)
            _overflow = new const(void)*[length];
    }

    public const(void)*[] values() return scope @nogc nothrow pure {
        return _length <= _local.length
            ? _local[0 .. _length] : _overflow;
    }
}
