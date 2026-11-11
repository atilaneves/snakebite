module snakebite.druntime.atomicwrapper;


private:


// This module imports nothing of the frontend: the resolver of host symbols
// answers its name.

// DMD generates this operation to gate an instantiated shared module
// constructor. The host compiler builds this wrapper with its own druntime,
// so its inline assembly stays in compiled host code.
public enum atomicAddSymbol = "snakebite_constructor_atomic_add_int";

public extern(C) int snakebite_constructor_atomic_add_int(
    shared int* value,
    int amount,
) nothrow @trusted {
    import core.atomic: atomicOp;

    return atomicOp!"+="(*value, amount);
}
