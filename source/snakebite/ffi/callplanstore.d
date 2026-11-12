module snakebite.ffi.callplanstore;


private:

import snakebite.ffi.callback: CallbackBridge, CallbackHandler;
import snakebite.ffi.callplan: CallPlan, NativeSignature, Pending, planOf;
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

    // A plan with the inputs that `plan` made it from: the file of a
    // program holds these, and a load makes the plan again from them.
    private struct PlanEntry {
        CallPlan plan;
        NativeSignature signature;
        Pending pending;
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
    // kept for the life of this. An empty `symbol` is a plan with no code to
    // call.
    //
    // `failure` is the text of the failure of a call that cannot be made when
    // the compile makes the plan: the plan is unbound, and `bound` binds it
    // at the first call, as the dynamic linker binds a PLT entry, or throws
    // `failure`. With an empty `symbol` the plan is not laid out, and `bound`
    // always throws `failure`. Every plan of this store is made here, so the
    // plans of a load are the plans of a compile.
    public CallPlan* plan(
        NativeSignature signature, string symbol = null, string failure = null,
    ) {
        return planAt(signature, symbol,
            symbol.length == 0 ? null : resolver.resolve(symbol), failure);
    }

    // As `plan`, for a caller that resolved `symbol` itself: `address` is
    // what the resolver answered.
    public CallPlan* planAt(
        NativeSignature signature, string symbol, void* address,
        string failure = null,
    ) {
        import core.atomic: atomicLoad, cas;

        auto entry = new PlanEntry;
        entry.signature = signature;
        entry.pending = Pending(symbol, failure, &resolver.resolve);
        if (symbol.length != 0 || failure.length == 0)
            entry.plan = planOf(signature, address, callbacks);
        if (address is null && failure.length != 0)
            entry.plan.pending = &entry.pending;
        // Plans are only pushed, never popped or reused, so a head that
        // compares equal is the same node: no ABA.
        shared(PlanEntry)* head;
        do {
            head = atomicLoad(_plans);
            entry.next = cast(PlanEntry*) head;
        } while (!cas(&_plans, head, cast(shared(PlanEntry)*) entry));
        return &entry.plan;
    }

    // The plans, oldest first, with the symbol and the failure text of `plan`
    // that made each.
    public void eachPlan(
        scope void delegate(
            const(CallPlan)*, in NativeSignature, in string, in string) visit,
    ) const {
        import core.atomic: atomicLoad;
        import std.algorithm: reverse;

        const(PlanEntry)*[] entries;
        for (auto entry = cast(const(PlanEntry)*) atomicLoad(_plans);
                entry !is null; entry = entry.next)
            entries ~= entry;
        foreach (entry; entries.reverse)
            visit(&entry.plan, entry.signature, entry.pending.symbol,
                entry.pending.failure);
    }

    // `plan` with its code address set, which is `plan` itself when it has
    // one. The code of a symbol that the process did not have when the plan
    // was made is bound here, at the first call of the plan: this throws the
    // failure text of the plan if the symbol is still absent. A call of a bound
    // plan runs the one test of its address.
    public static const(CallPlan)* bound(return const(CallPlan)* plan) {
        if (plan.address !is null || plan.pending is null)
            return plan;
        return bind(plan);
    }

    private static const(CallPlan)* bind(return const(CallPlan)* plan) {
        const pending = plan.pending;
        void* address;
        if (pending.symbol.length != 0)
            address = pending.resolve(pending.symbol);
        if (address is null)
            throw new Exception(pending.failure);
        plan.bindAddress(address);
        return plan;
    }
}
