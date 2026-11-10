module snakebite.backends.api;


private:


import snakebite.program: Program;
import snakebite.backends.startdata: FunctionHandle, StartData;


// The handle of a backend that runs a function from its declaration.
public final class DeclarationHandle: FunctionHandle {
    private imported!"dmd.func".FuncDeclaration _function;
    private Backend _backend;

    public this(
        Backend backend, imported!"dmd.func".FuncDeclaration function_,
    ) {
        _backend = backend;
        _function = function_;
    }

    public override void call(void* returnPlace, void*[] args) {
        _backend.call(_function, returnPlace, args);
    }
}


// Cumulative work done by a backend's compiler. A backend without a
// compilation phase leaves `hasCompiler` false; this is distinct from a
// compiler whose measured duration is zero.
public struct CompilationStatistics {
    import core.time: Duration;

    bool hasCompiler;
    size_t cacheMisses;
    Duration duration;
}


// Wall time since `start`, less the time `backend` compiled in it, so that
// an interval and the compilation it causes are reported once each.
public struct ExecutionClock {
    import core.time: Duration, MonoTime;

    private const(Backend) _backend;
    private MonoTime _start;
    private Duration _compiledAtStart;

    public static ExecutionClock start(const(Backend) backend) {
        return ExecutionClock(
            backend,
            MonoTime.currTime,
            backend.compilationStatistics.duration,
        );
    }

    public Duration peek() const {
        const compiled =
            _backend.compilationStatistics.duration - _compiledAtStart;
        return MonoTime.currTime - _start - compiled;
    }
}


// Owns one backend: the only release of the execution state the backend
// made for the calling thread while that thread lives (its frame stacks
// stay GC roots until then; the end of a thread also releases it). A site
// that holds the handle cannot forget to release.
// The backend itself stays on the GC heap: callback entries and guest
// finalizers can still reach it. A handle must not be a member of a GC
// object: the destructor calls a virtual function, and the GC can finalize
// the backend first.
public struct Owned(B : Backend) {
    private B _backend;

    @disable this(this);

    public this(B backend) {
        _backend = backend;
    }

    static if (!__traits(isAbstractClass, B)) {
        public this(const Program program) {
            _backend = new B(program);
        }
    }

    ~this() {
        // `release` is protected: through the base class it is visible here.
        Backend base = _backend;
        if (base !is null)
            base.release;
    }

    public B backend() {
        return _backend;
    }

    alias backend this;
}


public abstract class Backend {
    import dmd.dmodule: Module;
    import dmd.func: FuncDeclaration;

    // The program this backend runs. Whether a callee is interpreted or
    // called natively is the program's one decision (`isInterpreted`),
    // so every backend is constructed knowing which program it runs.
    protected const Program _program;

    protected this(const Program program) {
        _program = program;
    }

    // Ends the owner's execution-state lifetime. Active calls keep their
    // state until return or unwind. Later callbacks can still enter the
    // reachable backend, and release their state when they finish. Guest
    // thread-local storage remains valid for pointers into its variables.
    protected void release() {
    }

    // Read-only cumulative statistics. Backends without a compilation phase
    // use the default empty result.
    public CompilationStatistics compilationStatistics() const {
        return CompilationStatistics.init;
    }

    // Invoke one guest function. `args` and the value written to
    // `returnPlace` are in native layout, exactly as compiled D would lay
    // them out; `null` for `returnPlace` means the result is discarded
    // (e.g. a `void` function, or a caller that does not need the value).
    // Type information travels only through `function_`'s dmd type, not
    // through the untyped `void*[]`.
    //
    // `args[i]` points at the native bytes of parameter `i`; for a `ref`
    // or `out` parameter those bytes are the target's own address, one
    // pointer wide - the same convention a callback re-entry already
    // uses. When `function_` has a hidden `this` (a member method or a
    // nested function that reads an outer member's `this`), `args[0]` is
    // that same shape one more time, before the declared parameters: the
    // address of a pointer-sized word holding the context.
    //
    // For a value-returning callee, `returnPlace` must be exactly the
    // return type's size. For a `ref`-returning callee, `returnPlace`
    // must be pointer-sized: the callee hands back the result's own
    // address, not its value, the same word compiled D returns in `rax`.
    //
    // A guest failure (a failed assert, an uncaught guest exception) throws
    // a host exception, the same as `eval`.
    //
    // Guest state persists across calls on one instance: a REPL keeps one
    // backend for the whole session, so declarations from earlier cells are
    // visible to later ones.
    public abstract void call(
        FuncDeclaration function_, void* returnPlace, void*[] args,
    );

    // The bytes of the process-wide `static` or `__gshared` variable
    // `variable`, in native layout, or empty when this backend keeps no
    // static storage between calls (CTFE evaluates each call in isolation).
    // Module phases use it to do what dmd's glue layer does with the gate
    // of a module destructor.
    public abstract void[] staticStorage(
        imported!"dmd.declaration".VarDeclaration variable,
    );

    // The handle of `function_` in this backend, for `FunctionHandle.call`. A
    // handle is valid for the life of the backend. The backend decides when
    // the function is compiled: the bytecode backend compiles it at the
    // first call of the handle. The start data (`StartData`) needs a frontend
    // declaration in this and in `staticStorage`, and nowhere else.
    public abstract FunctionHandle compiledFunction(FuncDeclaration function_);

    // The start data of the program, built once (see `buildStartData`).
    public final ref StartData startData() {
        import core.atomic: atomicLoad, atomicStore, MemoryOrder;
        import snakebite.backends.startdatabuilder: buildStartData;
        import snakebite.frontend.compiler: withCompilerLock;

        if (!atomicLoad!(MemoryOrder.acq)(_startBuilt))
            withCompilerLock({
                if (atomicLoad(_startBuilt))
                    return;

                // `buildStartData` throws before it assigns, so a failure
                // leaves no half-built data and the next call builds again.
                _startData = buildStartData(
                    cast(Program) _program, &compiledFunction, &staticStorage);
                atomicStore!(MemoryOrder.rel)(_startBuilt, true);
            });
        return _startData;
    }

    private StartData _startData;
    private shared bool _startBuilt;

    // Execute one synthesised `string`-returning function and return its
    // result. The guest renders the value itself (`std.conv.text`), so the
    // returned string is a natively laid out value like any other; nothing
    // is boxed or marshalled. A `Throwable` that escapes propagates to the
    // caller.
    //
    // Guest state persists across calls on one instance: a REPL keeps one
    // backend for the whole session, so declarations from earlier cells are
    // visible to later ones.
    //
    // Collapses into `call` once `call` can return a native `string`.
    public abstract string eval(FuncDeclaration function_);
}
