module snakebite.language.statics.world;


private:


// The static world of one program: its static data, its type information,
// its class information, its call plans and the callable address of each of
// its functions. It builds these parts and connects them to each other. A
// backend gives the storage, and the `Backend` answers below; all the other
// answers are the same for every backend.
// Its owner constructs it in place: the parts keep its address.
public struct StaticWorld {
    @disable this(this);

    import dmd.dclass: ClassDeclaration;
    import dmd.declaration: Declaration;
    import dmd.dmodule: Module;
    import dmd.func: FuncDeclaration;
    import snakebite.ffi: PlanCache;
    import snakebite.ffi.callplanstore: CallPlanStore;
    import snakebite.language.call.selection: CallSelection;
    import snakebite.language.statics.classinfo: ClassRuntimeCache;
    import snakebite.language.statics.data: NativeData;
    import snakebite.language.statics.typeinfo: RuntimeTypes;
    import snakebite.native.address: Target;
    import snakebite.native.staticstore: StaticBlocks, StaticStore;
    import snakebite.program: Program;

    // What only a backend knows.
    public struct Backend {
        // The word that stands for the guest body of a function, with the
        // body ready to run: host code can call the function as soon as it
        // has the word. The backend registers the word with `plans`.
        public const(void)* delegate(FuncDeclaration function_) guestWord;
        // Optional. Called with each address, with no adjustment, that host
        // code gets for a function.
        public void delegate(FuncDeclaration function_, void* address)
            addressGiven;
        // Optional. Called with the class information that this built for a
        // guest class.
        public void delegate(ClassDeclaration declaration, TypeInfo_Class info)
            classBuilt;
        // Optional. The blocks of the D module that defines a datum. Without
        // it every datum goes to the store.
        public StaticBlocks* delegate(Module module_) blocksOf;
    }

    // How to reach each compiled function that the guest calls.
    public PlanCache plans;
    // Whether the body of a callee is preferred does not change while a
    // program runs.
    public CallSelection callSelection;
    public NativeData data;
    public RuntimeTypes types;
    // A guest class never reaches the code generator of dmd, so nothing
    // emits its `TypeInfo_Class`, its vtables or its `.init` bytes as linked
    // data. This builds them once for each class.
    private ClassRuntimeCache _classRuntime;
    private const Program _program;
    private Backend _backend;

    // `store` and `planStore` are the storage of the owner, which outlives
    // this.
    public this(
        const Program program,
        StaticStore* store,
        CallPlanStore* planStore,
        Backend backend,
    ) {
        _program = program;
        _backend = backend;
        plans = PlanCache(planStore, &_program.isRootOwned);
        callSelection.linksFunctions = program.definesLinkableFunctions;
        data = NativeData(store, &_program.isRootOwned,
            (variable) => _program.linkedVariableOf(variable),
            &constantSymbolAddress,
            (name) => plans.resolveThreadLocal(name),
            &classRuntimeInfo, (type) => types.get(type),
            backend.blocksOf, &callableKind);
        types = RuntimeTypes(&_program.isRootOwned,
            (name) => plans.resolve(name),
            &callableAddress,
            &classRuntimeInfo, &data);
    }

    // The function that a call of `function_` runs.
    public FuncDeclaration definitionOf(FuncDeclaration function_) {
        return callSelection.definitionOf(
            function_, (declaration) => _program.linkedFunctionOf(declaration));
    }

    private void* constantSymbolAddress(Declaration symbol) {
        import snakebite.frontend.dmd.mangle: nativeSymbolName;

        if (auto function_ = symbol.isFuncDeclaration)
            return callableAddress(function_, 0);

        return plans.resolve(nativeSymbolName(symbol));
    }

    // The native metadata of a guest class. The vtable is native layout that
    // host code with a guest object calls through, so each slot is a
    // callable address.
    public TypeInfo_Class classRuntimeInfo(ClassDeclaration declaration) {
        if (auto found = _classRuntime.find(declaration))
            return *found;

        return buildClassRuntimeInfo(declaration);
    }

    // Apart from `classRuntimeInfo`: the delegates below capture `this`, so
    // a function that holds them allocates a closure when it starts, and
    // the lookup of a class that exists must not allocate.
    private TypeInfo_Class buildClassRuntimeInfo(ClassDeclaration declaration) {
        import snakebite.language.statics.classinfo:
            classRuntimeInfo_ = classRuntimeInfo, Hooks;

        return _classRuntime.build(() => classRuntimeInfo_(
            declaration,
            _classRuntime,
            Hooks(
                &callableAddress,
                &types.linkedClassInfo,
                (decl) => types.rtInfo(decl),
                _backend.classBuilt,
                &data,
            ),
        ));
    }

    // The callable address of a function: the entry of a vtable slot
    // (adjusted for the interface offset that the slot has), or the value
    // of a function pointer or of the function word of a delegate
    // (`adjustment` 0). Function pointers can reach host code inside
    // aggregates or through pointers to guest data, where the barrier cannot
    // replace them. Null for an abstract function.
    public void* callableAddress(FuncDeclaration method, ptrdiff_t adjustment) {
        import dmd.dsymbolsem: isAbstract;

        // getOverloads can leave an alias in a function-pointer constant.
        method = definitionOf(method.toAliasFunc);
        if (method.isAbstract)
            return null;

        const(void)* word;
        const hasNativeSymbol = plans.hasNativeSymbol(method);
        if (callSelection.usesNativeVariadicAddress(method, hasNativeSymbol))
            return plans.addressOf(method);
        if (callSelection.usesGuestBody(method,
                (callee) => _program.isInterpreted(callee),
                hasNativeSymbol,
                plans.hasIndependentNativeSymbol(method))) {
            word = _backend.guestWord(method);
            if (callSelection.storesGuestWord(
                    method, hasNativeSymbol, adjustment))
                return cast(void*) word;
        }
        auto address = plans.callableAddress(word, method, adjustment);
        // An adjusted address is the entry of a vtable slot. Only a virtual
        // call reaches it, and that call knows its declaration.
        if (adjustment == 0 && _backend.addressGiven !is null)
            _backend.addressGiven(method, address);
        return address;
    }

    // What `callableAddress` returned: a guest function, the callback entry
    // that host code calls for one, or code of the host.
    public Target.Kind callableKind(in void* address) {
        if (address is null || plans.isGuestWord(address))
            return Target.Kind.functionWord;
        if (plans.guestTarget(address).word !is null)
            return Target.Kind.callbackEntry;
        if (plans.isAdjustedHostEntry(address))
            return Target.Kind.callbackEntry;
        return Target.Kind.hostSymbol;
    }
}
