module snakebite.backends.bytecode.program;


private:

import snakebite.backends.bytecode.relocation: plain, setBy;
import snakebite.backends.bytecode.vm: bindInstructionReferences, Function,
    JitSetting, prepareForExecution;
import snakebite.ffi.callplanstore: CallPlanStore;
import snakebite.host.threads: heapNew;
import snakebite.image.dependency: DependencyImage;
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
        const resolver = &plans.resolver;
        store = StaticStore(() => heapNew!TlsSlots(resolver), recordsAddresses);
    }

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

    // An empty module for the compiler to fill.
    public Module* newModule() @safe nothrow pure {
        auto module_ = new Module;
        _modules ~= module_;
        return module_;
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

    // Makes a function whose tables are filled ready to run on the runner
    // that has `jit` and `jitInstance`: a compile and a load both end with
    // this. Returns null, or the reason why the function is not valid.
    public static string complete(JitInstance)(
        Function* function_, in JitSetting jit, JitInstance jitInstance,
    ) {
        function_.fixWindowFacts;
        if (const reason = bindInstructionReferences(*function_))
            return reason;
        prepareForExecution(function_, jit, jitInstance,
            function_.mangledName);
        return null;
    }
}


// The compiled code and the static data that one D module defines. The
// program owns it and the address does not change.
public struct Module {
    @disable this(this);

    // The start record of the D module: its phases and unit tests, and its
    // imports as positions in `StartData.modules`. The start data points
    // here. It is filled when the start data is built.
    @plain public ModuleStart start;

    // The static data that the D module defines: its variables and their
    // initial bytes. The addresses in instructions point into the blocks.
    @setBy("Module.newModule")
    public StaticBlocks blocks;

    // Each is a heap block that never moves: a call site embeds the address
    // of its callee before the callee is filled. One append per function.
    @plain package Function*[] _functions;

    // An empty function for the compiler to fill. A compile that fails
    // takes it out again with `discardFunction`.
    public Function* newFunction() @safe nothrow pure {
        auto function_ = new Function;
        _functions ~= function_;
        return function_;
    }

    // Takes out the function that `newFunction` returned, for a compile that
    // failed. Functions that were made after it stay.
    public void discardFunction(Function* function_) @safe nothrow pure {
        foreach_reverse (i, kept; _functions)
            if (kept is function_) {
                _functions = _functions[0 .. i] ~ _functions[i + 1 .. $];
                return;
            }
    }
}
