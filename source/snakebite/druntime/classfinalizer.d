module snakebite.druntime.classfinalizer;


private:


// The host druntime runs linked class destructors and monitor cleanup.
public extern(C) void _d_callfinalizer(void* object);
