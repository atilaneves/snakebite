module snakebite.backends.bytecode.program;


private:

import snakebite.backends.bytecode.relocation: plain, setBy;
import snakebite.backends.bytecode.vm: bindHostCode,
    bindInstructionReferences, CallSite, Function,
    JitSetting, prepareForExecution;
import snakebite.ffi.callplanstore: CallPlanStore;
import snakebite.host.threads: heapNew;
import snakebite.image.dependency: DependencyImage;
import snakebite.memory.program: loadedProgramGrows, ProgramMemory;
import snakebite.native.signature: SignatureTable;
import snakebite.native.staticstore: StaticBlocks, StaticStore;
import snakebite.stack.tls: TlsSlots;
import snakebite.start.data: ModuleStart, StartData;


// What one process holds of a compiled program while it runs: the compiled
// functions, the signatures, the static storage, the call plans and the start
// data.
// It holds no frontend type. A slot that is not filled yet (a call site, or a
// start handle, of a function that is not compiled) holds a delegate that the
// compiler gave; the delegate fills the slot at its first use and is then
// dropped. A filled start handle holds the compiled function and the address
// of the `Runner` that runs it, and no other part of the compiler.
// A struct that its owner holds by value: its address, and the addresses of
// what it owns, do not change.
public struct Program {
    @disable this(this);

    // `image` is the dependency image that symbols resolve in, or null. The
    // owner must outlive this, and must construct it in place: the tables of
    // thread-local variables keep the address of the resolver of `plans`.
    // With `recordsAddresses`, each word of the program that holds an
    // address has a record, so that a file can hold the program.
    public this(const(DependencyImage)* image, bool recordsAddresses = false) {
        plans = CallPlanStore(image);
        const planStore = &plans;
        store = StaticStore(() => heapNew!TlsSlots(planStore), recordsAddresses);
    }

    // The memory of a program that a load made; a compile to RAM takes
    // none.
    @setBy("loadProgram")
    public ProgramMemory memory;

    public bool recordsAddresses() const @safe pure nothrow @nogc {
        return store.recordsAddresses;
    }

    // The interned parameter signatures of the layouts. A `Signature*` of
    // one `Program` meets only others of the same one.
    @setBy("SignatureTable.intern")
    public SignatureTable signatures;

    // The storage of the static data and constants. What fills it is
    // elsewhere: it holds no frontend type.
    @setBy("Program.this")
    public StaticStore store;

    // The call plans, the resolver of their symbols and the callback bridge.
    @setBy("wire")
    public CallPlanStore plans;

    // The start data of the program. The owner builds it at its first use
    // and the owner decides when. It needs the frontend to build, which this
    // does not.
    @plain public StartData startData;

    // Each is a heap block that never moves: the compiler and the compiled
    // code point to a `Module`. One append per module.
    @plain package Module*[] _modules;

    // An empty module for the compiler to fill. A loaded program does not
    // grow.
    public Module* newModule() @safe nothrow pure {
        if (memory.isTaken)
            loadedProgramGrows;
        auto module_ = new Module;
        _modules ~= module_;
        return module_;
    }

    // `count` empty modules, in `memory`, after the modules that the program
    // has, for a load of a file to fill. The list of the modules is a GC
    // array: a load of a file does not know how many modules the files after
    // it have.
    public void newModules(in size_t count) {
        foreach (_; 0 .. count) {
            // `auto`: the load fills the module.
            auto module_ = memory.data.make!Module;
            module_.blocks.takeFrom(&memory);
            _modules ~= module_;
        }
    }

    public size_t functionCount() const @safe pure nothrow @nogc {
        size_t total;
        foreach (module_; _modules)
            total += module_._functions.length;
        return total;
    }

    // Each function of the program, in the order of the modules. `visit` can
    // add modules and functions; the walk reaches them too.
    public void eachFunction(scope void delegate(Function*) visit) {
        for (size_t m = 0; m < _modules.length; ++m)
            for (size_t f = 0; f < _modules[m]._functions.length; ++f)
                visit(_modules[m]._functions[f]);
    }

    // Makes a function in the form that the compiler builds and a file holds
    // ready to run on the runner that has `jit` and `jitInstance`: a compile
    // to RAM and a load both end with this, and a save does not call it.
    // Each word that names a symbol (`snakebite.ffi.names`) gets the address
    // that `plans` finds for it, and each call to a name is connected to the
    // definition of the name (`CallSite.connect`). Returns null, or the
    // reason why the function is not valid.
    public static string complete(JitInstance)(
        Function* function_, ref CallPlanStore plans, in JitSetting jit,
        JitInstance jitInstance,
    ) {
        import snakebite.backends.bytecode.vm: wordAt;

        // Each record that a compile or a load leaves is of a name.
        foreach (reloc; function_.relocs) {
            auto word = wordAt(*function_, reloc.place);
            if (word is null)
                return "a relocation has no place";
            *word = plans.wordOfName(reloc.target);
        }
        function_.relocs = null;
        plans.bindNewPlans;
        foreach (ref site; function_.callSites)
            if (site.kind == CallSite.Kind.named)
                site.connect(plans);
        function_.fixWindowFacts;
        if (const reason = bindInstructionReferences(*function_))
            return reason;
        bindHostCode(*function_);
        prepareForExecution(function_, jit, jitInstance,
            function_.mangledName);
        return null;
    }
}


// The compiled code and the static data that one D module defines. The
// program owns it and the address does not change.
public struct Module {
    @disable this(this);

    // The `ModuleStart` of the D module: its phases and unit tests, its
    // `main`, and its imports by name. The start data points here. It is
    // filled when the start data is built.
    @plain public ModuleStart start;

    // The static data that the D module defines: its variables and their
    // initial bytes. The addresses in instructions point into the blocks.
    @setBy("Module.newModule")
    public StaticBlocks blocks;

    // Each is a heap block that never moves: a call site embeds the address
    // of its callee before the callee is filled. One append per function.
    @plain package Function*[] _functions;

    // An empty function for the compiler to fill. A compile that fails
    // takes it out again with `discardFunction`. A loaded program does not
    // grow: the GC does not scan `_functions` of a loaded module.
    public Function* newFunction() @safe nothrow pure {
        if (blocks.isLoaded)
            loadedProgramGrows;
        auto function_ = new Function;
        _functions ~= function_;
        return function_;
    }

    // `count` empty functions, in `memory`, for a load to fill.
    public void newFunctions(ref ProgramMemory memory, in size_t count) {
        auto functions = memory.data.array!Function(count);
        _functions = memory.data.array!(Function*)(count);
        foreach (index, ref function_; _functions)
            function_ = &functions[index];
    }

    // Takes out the function that `newFunction` returned, for a compile that
    // failed. Functions that were made after it stay.
    public void discardFunction(Function* function_) @safe nothrow pure {
        if (blocks.isLoaded)
            loadedProgramGrows;
        foreach_reverse (i, kept; _functions)
            if (kept is function_) {
                _functions = _functions[0 .. i] ~ _functions[i + 1 .. $];
                return;
            }
    }
}
