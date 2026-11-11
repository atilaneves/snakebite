module snakebite.backends.bytecode.linkedmodules;


private:

import snakebite.backends.bytecode.vm: Function;
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

    // Each is a heap block that never moves: a call site embeds the address
    // of its callee before the callee is filled. One append per function.
    private Function*[] _functions;

    // An empty function for the compiler to fill. The compiler may fail
    // after this and then keeps the empty function here, unreachable from
    // its own index.
    public Function* newFunction() {
        auto function_ = new Function;
        _functions ~= function_;
        return function_;
    }

    public inout(Function*)[] functions() inout {
        return _functions;
    }
}
