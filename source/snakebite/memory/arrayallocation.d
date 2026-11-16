module snakebite.memory.arrayallocation;

private:

import core.internal.gc.blockmeta : MAXSMALLSIZE;


public enum arrayAllocationMaxLength = MAXSMALLSIZE / (void*).sizeof;
public enum arrayAllocationMaxSpares = 62;


// Only the dispatch that owns these slots can change them.
public struct ArrayAllocationSlots {
    void*[arrayAllocationMaxSpares] roots;
    size_t charge;
    size_t count;
}


public struct ArrayAllocationRequest {
    ArrayAllocationSlots* slots;
    const TypeInfo element;
    size_t payload;
}


public struct ArrayAllocationThread {
    const(bool)* inFinalizer;
    ulong* bytesAllocated;
}

public struct ArrayAllocationCache {
    ArrayAllocationThread thread;
    const(void)* type;
    ArrayAllocationSlots[arrayAllocationMaxLength] lengths;
}


extern(C) public ArrayAllocationThread arrayAllocationThread() nothrow @nogc;
extern(C) public ArrayAllocationRequest* exchangeArrayAllocationRequest(
    ArrayAllocationRequest* request,
) nothrow @nogc;
