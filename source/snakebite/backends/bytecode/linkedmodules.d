module snakebite.backends.bytecode.linkedmodules;


private:

import snakebite.backends.bytecode.vm: Function;
import snakebite.ffi.symbol: Resolver;
import snakebite.host.threads: heapNew;
import snakebite.image.dependency: DependencyImage;
import snakebite.native.signature: SignatureTable;
import snakebite.native.staticstore: StaticStore;
import snakebite.stack.tls: TlsSlots;


// The compiled code and data of the modules of one process, bound together.
// It holds nothing of the compiler and nothing of the machinery that
// executes. A struct that its owner holds by value: its address, and the
// addresses of what it owns, do not change.
public struct LinkedModules {
    @disable this(this);

    // `image` is the dependency image that symbols resolve in, or null. The
    // owner must outlive this.
    public this(const(DependencyImage)* image) {
        store = StaticStore(() => heapNew!TlsSlots);
        resolver = Resolver(image);
    }

    // The interned parameter signatures of the layouts. A `Signature*` of
    // one `LinkedModules` meets only others of the same one.
    public SignatureTable signatures;

    // The storage of the static data and constants. What fills it is
    // elsewhere: it holds no frontend type.
    public StaticStore store;

    // The resolver of the symbols that the call plans bind to.
    public Resolver resolver;

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
