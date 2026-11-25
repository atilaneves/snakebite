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

    import snakebite.frontend.ast: ClassDeclaration, Declaration,
        FuncDeclaration, Module;
    import snakebite.ffi: PlanCache;
    import snakebite.ffi.callplanstore: CallPlanStore;
    import snakebite.ffi.names: Linked;
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
        public void delegate(FuncDeclaration function_, Linked!(void*) address)
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
        plans = PlanCache(planStore);
        callSelection.linksFunctions = program.definesLinkableFunctions;
        data = NativeData(store, &plans, &_program.definesAlone,
            &_program.isDefinedElsewhere,
            (variable) => _program.linkedVariableOf(variable),
            &constantSymbolAddress,
            &writeClassImage, (type) => types.get(type),
            backend.blocksOf, &callableKind, program.isUnit);
        types = RuntimeTypes(&_program.definesAlone,
            &_program.isDefinedElsewhere,
            &callableAddress,
            &classRuntimeInfo, &data);
    }

    // The function that a call of `function_` runs.
    public FuncDeclaration definitionOf(FuncDeclaration function_) {
        return callSelection.definitionOf(
            function_, (declaration) => _program.linkedFunctionOf(declaration));
    }

    // The address of `symbol` that a constant holds: the name of its symbol
    // when the program does not define it (`snakebite.ffi.names`).
    private Linked!(void*) constantSymbolAddress(Declaration symbol) {
        import snakebite.frontend.dmd.mangle: nativeSymbolName;

        if (auto function_ = symbol.isFuncDeclaration)
            return callableAddress(function_, 0);

        return Linked!(void*).named(
            data.named(nativeSymbolName(symbol), symbol.toString));
    }

    // The native metadata of a guest class. The vtable is native layout that
    // host code with a guest object calls through, so each slot is a
    // callable address.
    public Linked!TypeInfo_Class classRuntimeInfo(
        ClassDeclaration declaration,
    ) {
        if (auto found = _classRuntime.find(declaration))
            return *found;

        return buildClassRuntimeInfo(declaration);
    }

    // Apart from `classRuntimeInfo`: the delegates below capture `this`, so
    // a function that holds them allocates a closure when it starts, and
    // the lookup of a class that exists must not allocate.
    private Linked!TypeInfo_Class buildClassRuntimeInfo(
        ClassDeclaration declaration,
    ) {
        import snakebite.language.statics.classinfo:
            classRuntimeInfo_ = classRuntimeInfo;

        return _classRuntime.build(() => classRuntimeInfo_(
            declaration,
            _classRuntime,
            hooks,
        ));
    }

    // The initial image of an object of `declaration`, written at `place`.
    private void writeClassImage(ClassDeclaration declaration, void* place) {
        import snakebite.language.statics.classinfo: initialImage;

        _classRuntime.run({
            initialImage(declaration, place, _classRuntime, hooks);
        });
    }

    private imported!"snakebite.language.statics.classinfo".Hooks hooks() {
        import snakebite.language.statics.classinfo: Hooks;

        return Hooks(
            &callableAddress,
            &types.classInfoName,
            &types.isNativeClass,
            &types.nativeVtable,
            (decl) => types.rtInfo(decl),
            _backend.classBuilt,
            &data,
            &types.hasOwnCopy,
            &types.ownClassInfo,
        );
    }

    // The callable address of a function: the entry of a vtable slot
    // (adjusted for the interface offset that the slot has), or the value
    // of a function pointer or of the function word of a delegate
    // (`adjustment` 0). Function pointers can reach host code inside
    // aggregates or through pointers to guest data, where the barrier cannot
    // replace them. Null for an abstract function.
    public Linked!(void*) callableAddress(
        FuncDeclaration method, ptrdiff_t adjustment,
    ) {
        import snakebite.frontend.ast: isAbstract;

        // getOverloads can leave an alias in a function-pointer constant.
        method = definitionOf(method.toAliasFunc);
        if (method.isAbstract)
            return Linked!(void*).init;

        const(void)* word;
        if (callSelection.usesNativeVariadicAddress(
                method, &isDefinedElsewhere))
            return Linked!(void*).named(plans.nameOf(method));
        if (callSelection.usesGuestBody(method, &isDefinedElsewhere)) {
            word = _backend.guestWord(method);
            if (callSelection.storesGuestWord(
                    method, &isDefinedElsewhere, adjustment))
                return Linked!(void*).held(cast(void*) word);
        }
        auto address = plans.callableAddress(word, method, adjustment);
        // An adjusted address is the entry of a vtable slot. Only a virtual
        // call reaches it, and that call knows its declaration.
        if (adjustment == 0 && _backend.addressGiven !is null)
            _backend.addressGiven(method, address);
        return address;
    }

    private bool isDefinedElsewhere(FuncDeclaration function_) const {
        return _program.isDefinedElsewhere(function_);
    }

    // `linked` as a backend that reads it as it runs, and does not save,
    // uses it: a name gives the address of its symbol
    // (`CallPlanStore.ready`).
    public T ready(T)(Linked!T linked) {
        return plans.store.ready(linked);
    }

    // What `callableAddress` held: a guest function, or the callback entry
    // that host code calls for one.
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
