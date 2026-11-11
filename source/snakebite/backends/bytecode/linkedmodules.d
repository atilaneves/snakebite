module snakebite.backends.bytecode.linkedmodules;


private:

import snakebite.native.signature: SignatureTable;


// The compiled code and data of the modules of one process, bound together.
// It holds nothing of the compiler and nothing of the machinery that
// executes. A struct that its owner holds by value: its address, and the
// addresses of what it owns, do not change.
public struct LinkedModules {
    @disable this(this);

    // The interned parameter signatures of the layouts. A `Signature*` of
    // one `LinkedModules` meets only others of the same one.
    public SignatureTable signatures;
}
