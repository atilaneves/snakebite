module snakebite.ffi.callplanstore;


private:

import snakebite.ffi.callback: CallbackBridge, CallbackHandler;
import snakebite.ffi.callplan: CallPlan;
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

    private struct PlanEntry {
        CallPlan plan;
        PlanEntry* next;
    }
    // The prepared plans, newest first. Threads that run guest code prepare
    // plans without a lock, so a plan joins the list with a compare and
    // swap.
    private shared(PlanEntry)* _plans;

    // An empty plan for the caller to fill, kept for the life of this.
    public CallPlan* newPlan() nothrow pure {
        import core.atomic: atomicLoad, cas;

        auto entry = new PlanEntry;
        auto head = atomicLoad(_plans);
        do
            entry.next = cast(PlanEntry*) head;
        while (!cas(&_plans, head, cast(shared(PlanEntry)*) entry));
        return &entry.plan;
    }
}
