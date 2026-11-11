module snakebite.backends.bytecode.loaded;


private:


import snakebite.backends.api: Backend;
import snakebite.backends.bytecode.saved: SavedProgram, SavedTarget;
import snakebite.backends.bytecode.vm: Function, Vm;
import snakebite.start.data: FunctionHandle;


// Runs a program that `--save` stored. It has no frontend declaration: the
// start data comes from the file, and so do the functions. Its only way in is
// the handle of `main` and the handles of the module phases.
public final class LoadedBytecode: Backend {
    import snakebite.ffi.plan: CallPlan, NativeSignature, planAt;
    import snakebite.ffi.symbol: Resolver;
    import snakebite.host.executionstates: ExecutionStates;
    import snakebite.host.threads: heapNew;
    import snakebite.native.signature: SignatureTable;
    import snakebite.program: Program;
    import snakebite.stack.frames: defaultFrameCapacity;
    import snakebite.start.data: ModuleStart, StartData;

    private ExecutionStates!(Vm*) _vms;
    private SignatureTable _signatures;
    private Resolver _resolver;
    // The memory that the functions point into. The garbage collector keeps
    // the data; the texts are `calloc`ed, as the compiler's string literals.
    private ubyte[][] _data;
    private ubyte*[] _texts;
    private const(void)*[] _plans;
    private const(Function)*[] _functions;

    public this(in SavedProgram saved) {
        super(Program.init);
        _resolver = Resolver(null);
        _vms = ExecutionStates!(Vm*)(
            () => heapNew!Vm(defaultFrameCapacity), () {});
        loadData(saved);
        loadPlans(saved);
        foreach (function_; saved.functions) {
            import snakebite.backends.bytecode.saved: instantiate;

            _functions ~= instantiate(
                function_, &addressOf, _plans, _signatures);
        }
        startWith(startDataOf(saved));
    }

    ~this() {
        import core.stdc.stdlib: free;

        foreach (text; _texts)
            free(text);
    }

    protected override void release() {
        _vms.end;
    }

    private void loadData(in SavedProgram saved) {
        import core.stdc.stdlib: calloc;
        import core.stdc.string: memcpy;

        foreach (text; saved.texts) {
            auto copy = cast(ubyte*) calloc(text.length + 1, 1);
            assert(copy !is null);
            memcpy(copy, text.ptr, text.length);
            _texts ~= copy;
        }
        foreach (datum; saved.data) {
            // The slice starts where the alignment says.
            auto memory = new ubyte[datum.bytes.length + datum.alignment];
            const start = -cast(size_t) memory.ptr & (datum.alignment - 1);
            auto bytes = memory[start .. start + datum.bytes.length];
            bytes[] = datum.bytes[];
            foreach (pointer; datum.pointers)
                *cast(void**) (bytes.ptr + pointer.offset) =
                    addressOf(pointer.target);
            _data ~= bytes;
        }
    }

    private void* addressOf(in SavedTarget target) {
        final switch (target.kind) with (SavedTarget.Kind) {
        case datum:
            return _data[target.index].ptr + target.offset;
        case text:
            return _texts[target.index] + target.offset;
        }
    }

    private void loadPlans(in SavedProgram saved) {
        import snakebite.backends.bytecode.saved: decode;
        import std.conv: text;

        foreach (plan; saved.plans) {
            const(ubyte)[] bytes = plan.signature;
            const signature = decode!NativeSignature(bytes);
            auto address = _resolver.resolve(plan.symbol);
            if (address is null)
                throw new Exception(text("the symbol `", plan.symbol,
                    "` is not in this process"));
            _plans ~= planAt(signature, address);
        }
    }

    private StartData startDataOf(in SavedProgram saved) {
        StartData data;
        data.programName = saved.programName;
        data.main.present = saved.hasMain;
        data.main.returnsVoid = saved.returnsVoid;
        data.main.parameterCount = saved.parameterCount;
        if (saved.hasMain)
            data.main.function_ = new LoadedFunction(_functions[saved.main]);
        foreach (module_; saved.modules)
            data.modules ~= ModuleStart(
                module_.name, module_.standalone, module_.imports.dup);
        return data;
    }

    private final class LoadedFunction: FunctionHandle {
        private const(Function)* _function;

        this(const(Function)* function_) {
            _function = function_;
        }

        public override void call(void* returnPlace, void*[] args) {
            auto active = _vms.enter;
            active.state.callFromHost(_function, returnPlace, args);
        }
    }

    public override void call(
        imported!"dmd.func".FuncDeclaration function_,
        void* returnPlace,
        void*[] args,
    ) {
        throw new Exception("a loaded program has no frontend declaration");
    }

    public override void[] staticStorage(
        imported!"dmd.declaration".VarDeclaration variable,
    ) {
        throw new Exception("a loaded program has no frontend declaration");
    }

    public override FunctionHandle compiledFunction(
        imported!"dmd.func".FuncDeclaration function_,
    ) {
        throw new Exception("a loaded program has no frontend declaration");
    }

    public override string eval(imported!"dmd.func".FuncDeclaration function_) {
        throw new Exception("a loaded program has no frontend declaration");
    }
}
