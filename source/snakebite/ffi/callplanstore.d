module snakebite.ffi.callplanstore;


private:

import snakebite.ffi.callback: CallbackBridge, CallbackHandler;
import snakebite.ffi.callplan: CallPlan, NativeSignature, Pending, planOf;
import snakebite.ffi.names: Linked, Name, Names;
import snakebite.ffi.symbol: Resolver;
import snakebite.image.dependency: DependencyImage;
import snakebite.native.address: Target;


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

    // The names of the symbols that the program refers to.
    public Names names;

    // The address of the symbol `name`: the one place where a program that
    // a compile to RAM made, or that a load read, finds the address of a
    // symbol that it names. The answer is kept in the name. A symbol that no
    // object defines is an error that names the symbol and its declaration.
    public void* addressOf(Name* name) {
        if (auto address = addressIfPresent(name))
            return address;
        throw missing(name.symbol, name.declaredBy);
    }

    // As `addressOf`, but null for a symbol that no object defines. A name
    // with an own copy (`Names.defineOwn`) gives the copy that
    // `chosenCopy` decides.
    public void* addressIfPresent(Name* name) {
        import core.atomic: atomicLoad, atomicStore, MemoryOrder;

        auto found = cast(void*) atomicLoad!(MemoryOrder.acq)(name.address);
        if (found is null) {
            if (auto adjusted = name.adjusted) {
                found = cast(void*) callbacks.adjustedEntryOf(
                    addressOf(adjusted.code), adjusted.signature,
                    adjusted.adjustment);
                atomicStore!(MemoryOrder.rel)(
                    name.address, cast(shared(void*)) found);
            }
            else {
                auto processCopy = resolver.resolve(name.symbol);
                found = names.keep(name, (own) {
                    auto copy = chosenCopy(processCopy, own);
                    return copy is null ? Name.absent : copy + name.distance;
                });
            }
        }
        return found is Name.absent ? null : found;
    }

    // The one decision for a datum that the program and another object can
    // both define: the copy of the process, `processCopy`, when the process
    // has the symbol, else the program's own copy `own`. Null when there is
    // neither. A compile to RAM asks when it makes the datum ready to run, a
    // load when it makes the loaded program ready; a compile never asks.
    public static void* chosenCopy(
        void* processCopy, const(void)* own,
    ) pure nothrow @nogc {
        return processCopy !is null ? processCopy : cast(void*) own;
    }

    // This thread's address of the thread-local symbol `symbol`, or null when
    // the process does not have it.
    public void* threadLocalAddressIfPresent(in char[] symbol) const {
        return resolver.resolveThreadLocal(symbol);
    }

    // `linked` as the program uses it when it runs: a name gives the
    // address of its symbol.
    public T ready(T)(Linked!T linked) {
        auto name = linked.name;
        if (name is null)
            return linked.held;
        static if (is(T == E[], E))
            return (cast(E*) addressOf(name))[0 .. linked.length];
        else
            return cast(T) addressOf(name);
    }

    // The word that refers to `target` in a program made ready to run. Only
    // a target of another object can be a name.
    public size_t wordOf(in Target target) {
        return isNamed(target) ? wordOfName(target) : target.address;
    }

    // The word that refers to `target`, which is a name (`isNamed`), in a
    // program made ready to run: the address of its symbol, or the table or
    // the record of an interface of the class information that it names.
    public size_t wordOfName(in Target target) {
        import snakebite.failure.report: SnakebiteException;
        import snakebite.native.address: interfaceWordOf;

        const address = addressOf(cast(Name*) target.address);
        if (target.kind == Target.Kind.hostSymbol)
            return cast(size_t) address;
        const info = cast(const(TypeInfo_Class)) address;
        if (target.index >= info.interfaces.length)
            throw new SnakebiteException(
                "the program file names an interface that a class does not "
                ~ "have");
        return interfaceWordOf(target.kind, info, target.index);
    }

    // Whether the word that refers to `target` is found only when the
    // program is made ready to run.
    public bool isNamed(in Target target) const @trusted nothrow @nogc {
        with (Target.Kind) switch (target.kind) {
            case hostSymbol:
            case interfaceTable:
            case interfaceRecord:
                return names.nameAt(cast(const(void)*) target.address) !is null;
            default:
                return false;
        }
    }

    // The failure of a symbol `symbol` that no object defines, as the link
    // of a native build reports it: the one place that makes it.
    // `declaredBy` names the declaration, when there is one.
    public static Exception missing(in char[] symbol, in char[] declaredBy) {
        import std.conv: text;

        return new Exception(text(
            "ffi cannot resolve the symbol `", symbol, "`",
            declaredBy.length ? text(" declared by `", declaredBy, "`") : "",
            ": it is not in this process"));
    }

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
    // The newest plan that `bindNewPlans` bound with the plans older than it.
    private shared(PlanEntry)* _boundPlans;

    // Whether no plan was made.
    public bool isEmpty() const @safe nothrow pure @nogc {
        return _plans is null;
    }

    // A plan that lays out the call of `signature` to the code that `name`
    // names, kept for the life of this. A null `name` is a plan with no code
    // to call.
    //
    // The plan holds the name of the code, not its address: `bound` binds it
    // at the first call, as the dynamic linker binds a PLT entry, or throws
    // `failure`, or, when `failure` is empty, the failure of a symbol that no
    // object defines (`addressOf`). With no `name` the plan is not laid out,
    // and `bound` always throws `failure`. Every plan of this store is made
    // here, so the plans of a load are the plans of a compile.
    public CallPlan* plan(
        NativeSignature signature, Name* name = null, string failure = null,
    ) {
        return planAt(signature, name, null, failure);
    }

    // As `plan`, for a caller that found the address of `name` itself:
    // `address` is what `addressOf` answered.
    public CallPlan* planAt(
        NativeSignature signature, Name* name, void* address,
        string failure = null,
    ) {
        import core.atomic: atomicLoad, cas;

        auto entry = new PlanEntry;
        entry.signature = signature;
        entry.pending = Pending(name, failure, &this);
        if (name !is null || failure.length == 0)
            entry.plan = planOf(signature, address, callbacks);
        if (address is null && (name !is null || failure.length != 0))
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

    // The plans, oldest first, with the name of the code and the failure
    // text of `plan` that made each.
    public void eachPlan(
        scope void delegate(const(CallPlan)*, in NativeSignature, Name*,
            in string) visit,
    ) const {
        import core.atomic: atomicLoad;
        import std.algorithm: reverse;

        const(PlanEntry)*[] entries;
        for (auto entry = cast(const(PlanEntry)*) atomicLoad(_plans);
                entry !is null; entry = entry.next)
            entries ~= entry;
        foreach (entry; entries.reverse)
            visit(&entry.plan, entry.signature, cast(Name*) entry.pending.name,
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

    // Binds each plan made since the last call when this process has the
    // symbol that it names, as a function that calls it is made ready to
    // run: a first call can then run where no allocation is allowed, in a
    // finalizer. A plan whose symbol no object defines stays unbound, and
    // its call throws the failure. A plan is bound once; threads that bind
    // the same plan write the same word.
    pragma(inline, true)
    public void bindNewPlans() {
        import core.atomic: atomicLoad, MemoryOrder;

        // Inline: each function that is made ready to run asks, and most
        // find no new plan.
        auto head = atomicLoad!(MemoryOrder.acq)(_plans);
        auto bound = atomicLoad!(MemoryOrder.acq)(_boundPlans);
        if (head !is bound)
            bindPlans(head, bound);
    }

    private void bindPlans(
        shared(PlanEntry)* head, shared(PlanEntry)* bound,
    ) {
        import core.atomic: cas;

        for (auto entry = cast(PlanEntry*) head;
                entry !is null && entry !is cast(PlanEntry*) bound;
                entry = entry.next)
            bindIfPresent(&entry.plan);
        cas(&_boundPlans, bound, head);
    }

    private static void bindIfPresent(const(CallPlan)* plan) {
        if (plan.address !is null || plan.pending is null)
            return;
        const pending = plan.pending;
        if (pending.name is null)
            return;
        if (auto address = (cast(CallPlanStore*) pending.store)
                .addressIfPresent(cast(Name*) pending.name))
            plan.bindAddress(address);
    }

    private static const(CallPlan)* bind(return const(CallPlan)* plan) {
        const pending = plan.pending;
        auto name = cast(Name*) pending.name;
        auto store = cast(CallPlanStore*) pending.store;
        if (name is null || pending.failure.length != 0
                && store.addressIfPresent(name) is null)
            throw new Exception(pending.failure);
        plan.bindAddress(store.addressOf(name));
        return plan;
    }
}
