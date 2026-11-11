module snakebite.backends.bytecode.runner;


// The machinery that executes compiled bytecode: the execution states of
// the threads, the JIT, and the call from the host into a compiled function.
// It holds none of the compiled code and none of the compiler, and it
// imports no frontend module.
public:

import snakebite.backends.bytecode.vm: Function, JitSetting, Vm;
import snakebite.host.executionstates: ExecutionStates;
import snakebite.stack.tls: TlsSlots;


// A `Function` holds the address of the JIT instance and the execution
// states hold delegates of this object, so the address of a `Runner` must
// never change. Hold it as a field of a class object.
struct Runner {
    import snakebite.backends.bytecode.jit: jitSupported;

    // Each native stack needs its own guest frame stack. Fibers can resume
    // out of nesting order, so they cannot share one LIFO stack.
    // Entries are owned and released by their host thread (ADR-0006).
    private ExecutionStates!(Vm*) _vms;
    // Set by `end` when no host code holds a callback entry, so that no
    // guest code of this runner can run again once its states are gone.
    private shared bool _jitCodeCanGo;
    // What the functions run by this runner do with the JIT.
    private JitSetting _jit;
    private bool delegate() _hasCallbackEntries;
    // The JIT code region and the other JIT state. Its address never
    // changes, and each `Function` compiled for this runner points to it.
    // The destructor of the field frees the region.
    static if (jitSupported) {
        import snakebite.backends.bytecode.jit: JitInstance;

        private JitInstance _jitInstance;

        package JitInstance* jitInstance() {
            return &_jitInstance;
        }
    } else {
        package void* jitInstance() {
            return null;
        }
    }

    @disable this(this);

    // `tlsSlots` gives the guest TLS slots of a new execution state.
    // `onIdle` runs when a thread has no state left. `hasCallbackEntries`
    // tells, when `end` runs, whether host code still holds a callback entry
    // that can call a guest function.
    public this(
        in JitSetting jit,
        TlsSlots* delegate() tlsSlots,
        void delegate() onIdle,
        bool delegate() hasCallbackEntries,
    ) {
        import snakebite.host.threads: heapNew;
        import snakebite.stack.frames: defaultFrameCapacity;

        _jit = jit;
        _hasCallbackEntries = hasCallbackEntries;
        _vms = ExecutionStates!(Vm*)(() {
            return heapNew!Vm(defaultFrameCapacity, tlsSlots());
        }, onIdle, &releaseJitCode);
    }

    public ref const(JitSetting) jitSetting() const return {
        return _jit;
    }

    // The owner ends the runner. The JIT code goes when no guest code can
    // run: host code holds no callback entry, and (`ExecutionStates`) no
    // thread has an execution state left, which is checked when the last
    // one ends. Active calls and fibers keep a state until they return.
    public void end() {
        import core.atomic: atomicStore;

        static if (jitSupported)
            atomicStore(_jitCodeCanGo, !_hasCallbackEntries());
        _vms.end;
    }

    private void releaseJitCode() nothrow @nogc {
        import core.atomic: atomicLoad;

        static if (jitSupported)
            if (atomicLoad(_jitCodeCanGo))
                _jitInstance.release;
    }

    version(unittest)
    public size_t executionStatesOfThisThread() {
        return _vms.count;
    }

    // The one host-to-guest entry. `args` are host-to-guest arguments in
    // native layout, one pointer per parameter, per `Backend.call`'s own
    // contract - each pointer holds the address of storage for that
    // parameter's native bytes, which for a `ref`/`out` parameter are the
    // target's own address. When the callee has a hidden `this`, `args[0]`
    // is that same shape one more time, before the declared parameters: the
    // address of a pointer-sized word holding the context.
    //
    // A `ref`-returning callee hands back the result's own address, not
    // its value - the same word compiled D returns in `rax`.
    //
    // `compiled` is already built and carries the layout that binds `args`
    // (`Function.hostCall`): binding `args` into `Vm.HostArgument`s and
    // running the compiled body touch no dmd state, so this takes no lock
    // of its own. A thread that held the compiler lock here while it
    // waited for another thread's callback - the way `Thread.join` waits
    // in `otherThread`/`concurrentThreads` guest code - would never see
    // that callback return (ADR-0006).
    public void call(
        const(Function)* compiled,
        void* returnPlace,
        scope const(void*)[] args,
        void* variadicCursor = null,
        const(void)* variadicTypes = null,
    ) {
        const layout = &compiled.hostCall;
        layout.checkArgumentCount(args.length, "bytecode");

        Vm.HostArgument[16] inlineArguments = void;
        const count = layout.parameters.length
            + layout.hasHiddenThis
            + (variadicCursor !is null)
            + (variadicTypes !is null);
        auto arguments = count <= inlineArguments.length
            ? inlineArguments[0 .. count] : new Vm.HostArgument[count];
        size_t filled;

        scope const(void*)[] declaredArguments = args;
        if (layout.hasHiddenThis) {
            arguments[filled++] = Vm.HostArgument(
                layout.hiddenThis.offset, args[0], layout.hiddenThis.width);
            declaredArguments = args[1 .. $];
        }

        foreach (i, parameter; layout.parameters)
            arguments[filled++] = Vm.HostArgument(
                parameter.offset, declaredArguments[i], parameter.width);

        if (variadicCursor !is null) {
            assert(layout.variadicCursor != size_t.max);
            arguments[filled++] = Vm.HostArgument(
                layout.variadicCursor, &variadicCursor, size_t.sizeof);
        }
        if (variadicTypes !is null) {
            assert(layout.variadicTypes != size_t.max);
            arguments[filled++] = Vm.HostArgument(
                layout.variadicTypes, &variadicTypes, size_t.sizeof);
        }

        auto active = _vms.enter;
        active.state.call(*compiled, returnPlace, arguments[0 .. filled]);
    }
}
