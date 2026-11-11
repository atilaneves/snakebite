module snakebite.ffi.callplanstore;


private:

import snakebite.ffi.callback: CallbackBridge, CallbackHandler;
import snakebite.ffi.callplan: CallPlan, NativeSignature, planOf;
import snakebite.ffi.symbol: Resolver;
import snakebite.image.dependency: DependencyImage;


// The owner of the call plans of one backend, of the resolver that they bind
// symbols with and of the callback bridge. It holds nothing of the frontend.
// A struct that its owner holds by value: its address, and the addresses of
// what it owns, do not change.
public struct CallPlanStore {
    @disable this(this);

    // `image` is the dependency image that symbols resolve in, or null. The
    // owner must outlive this.
    public this(const(DependencyImage)* image) {
        resolver = Resolver(image);
    }

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

    // A plan with the two inputs that `plan` made it from: the file of a
    // program holds these, and a load makes the plan again from them.
    private struct PlanEntry {
        CallPlan plan;
        NativeSignature signature;
        string symbol;
        PlanEntry* next;
    }
    // The prepared plans, newest first. Threads that run guest code prepare
    // plans without a lock, so a plan joins the list with a compare and
    // swap.
    private shared(PlanEntry)* _plans;

    // Whether no plan was made.
    public bool isEmpty() const @safe nothrow pure @nogc {
        return _plans is null;
    }

    // A plan that lays out the call of `signature` to the code at `symbol`,
    // kept for the life of this, or null when the resolver has no `symbol`.
    // An empty `symbol` is a plan with no code to call. Every plan of this
    // store is made here, so the plans of a load are the plans of a compile.
    public CallPlan* plan(NativeSignature signature, string symbol = null) {
        import core.atomic: atomicLoad, cas;

        void* address;
        if (symbol.length != 0) {
            address = resolver.resolve(symbol);
            if (address is null)
                return null;
        }
        auto entry = new PlanEntry;
        entry.plan = planOf(signature, address, callbacks);
        entry.signature = signature;
        entry.symbol = symbol;
        // Plans are only pushed, never popped or reused, so a head that
        // compares equal is the same node: no ABA.
        shared(PlanEntry)* head;
        do {
            head = atomicLoad(_plans);
            entry.next = cast(PlanEntry*) head;
        } while (!cas(&_plans, head, cast(shared(PlanEntry)*) entry));
        return &entry.plan;
    }

    // The plans, oldest first, with the inputs of `plan` that made each.
    public void eachPlan(
        scope void delegate(
            const(CallPlan)*, in NativeSignature, in string) visit,
    ) const {
        import core.atomic: atomicLoad;
        import std.algorithm: reverse;

        const(PlanEntry)*[] entries;
        for (auto entry = cast(const(PlanEntry)*) atomicLoad(_plans);
                entry !is null; entry = entry.next)
            entries ~= entry;
        foreach (entry; entries.reverse)
            visit(&entry.plan, entry.signature, entry.symbol);
    }
}
