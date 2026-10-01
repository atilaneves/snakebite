module snakebite.druntime.classfinalizer;


private:


// The host druntime runs linked class destructors and monitor cleanup.
public extern(C) void _d_callfinalizer(void* object);

// The same for an interface pointer, which druntime first turns back into
// the object it points into.
public extern(C) void _d_callinterfacefinalizer(void* interfacePointer);
