module snakebite.backends.bytecode.linkedmodules;


private:

import snakebite.backends.bytecode.vm: Function;
import snakebite.ffi.callback: CallbackBridge, CallbackHandler;
import snakebite.ffi.callplan: CallPlan;
import snakebite.ffi.symbol: Resolver;
import snakebite.host.threads: heapNew;
import snakebite.image.dependency: DependencyImage;
import snakebite.native.signature: SignatureTable;
import snakebite.native.staticstore: StaticStore;
import snakebite.stack.tls: TlsSlots;
import snakebite.start.data: StartData;


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

    // The registry of the guest function words, and the owner of their
    // callback entries (ADR-0003). Null until `bindCallbacks`. It stays a
    // heap block, reached by pointer: plans and the entries of the host
    // code point to it, and it keeps its owner reachable.
    public CallbackBridge* callbacks;

    // The owner binds the bridge before any plan is prepared. `owner` is
    // what `handler` gets back with each callback.
    public void bindCallbacks(
        CallbackHandler handler, void* owner,
        void function(void*, const(void)*) prepare = null,
    ) {
        callbacks = new CallbackBridge(handler, owner, prepare);
    }

    private struct PlanEntry {
        CallPlan plan;
        PlanEntry* next;
    }
    // The prepared plans, newest first. Threads that run guest code prepare
    // plans without a lock, so a plan joins the list with a compare and
    // swap.
    private shared(PlanEntry)* _plans;

    // An empty plan for the caller to fill, kept for the life of this.
    public CallPlan* newPlan() {
        import core.atomic: atomicLoad, cas;

        auto entry = new PlanEntry;
        auto head = atomicLoad(_plans);
        do
            entry.next = cast(PlanEntry*) head;
        while (!cas(&_plans, head, cast(shared(PlanEntry)*) entry));
        return &entry.plan;
    }

    public void eachPlan(scope void delegate(const(CallPlan)*) visit) const {
        import core.atomic: atomicLoad;

        for (auto entry = cast(const(PlanEntry)*) atomicLoad(_plans);
                entry !is null; entry = entry.next)
            visit(&entry.plan);
    }

    // The start data of the program. The owner builds it at its first use
    // and then sets `startBuilt`, with release order. It needs the frontend
    // to build, which this does not.
    public StartData startData;
    public shared bool startBuilt;

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
