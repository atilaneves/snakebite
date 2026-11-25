module snakebite.program;


private:


// The root modules of the guest program, parsed and semantically analysed by
// the frontend, and its entry point. A dub project is not special: a
// dub-aware driver asks dub for import paths and flags and builds one of
// these.
public struct Program {
    import snakebite.image.dependency: DependencyImage, TestHooks;
    import snakebite.frontend.ast: Dsymbol, FuncDeclaration, Module;
    import snakebite.failure.halt: HaltAction, HostActions;
    import snakebite.frontend.checks: Checks;
    import snakebite.frontend.dmd.linking: LinkMap;

    // `func` is null when the program has no `main`, which is not an error: a
    // bare directory of `.d` files can be a library.
    struct Main {
        FuncDeclaration func;
    }

    Module[] rootModules;
    // Built once from `rootModules`, for `isRootOwned`'s `O(1)` lookup; see
    // `snakebite.frontend.dmd.functions.isRootOwned`.
    private bool[Module] _rootModuleSet;
    // Whether the root modules are one unit of a larger program (ADR-0021),
    // and then the modules of that program that the frontend read, the root
    // modules among them.
    private bool _isUnit;
    private bool[Module] _programModuleSet;
    // Built once from `rootModules`; see `linkedFunctionOf`.
    private LinkMap _links;
    Main main;
    string name;
    private Checks _checks;
    private HostActions _actions;
    // Prepared for this project's execution before any guest code runs.
    const(DependencyImage)* dependencyImage;
    // Whether the program starts as a project does: its unit tests run
    // before `main`, under the runner that the project's own images name.
    bool startsAsProject;
    TestHooks testHooks;

    // The entry point is found the way a compiled build finds it: the first
    // root module declaring a module-level `main`.
    this(Module[] rootModules) {
        this(rootModules, "");
    }

    this(
        Module[] rootModules,
        in string name,
    ) {
        this(rootModules, name, Checks());
    }

    // `checks` are the ones the frontend analysed `rootModules` under, and
    // `actions` are what `-checkaction=halt` does here: the default halt ends
    // the process, as compiled code does.
    this(
        Module[] rootModules,
        in string name,
        in Checks checks,
        in HostActions actions = HostActions(),
        in bool isUnit = false,
        Module[] otherUnitModules = null,
    ) {
        import snakebite.frontend.compiler: withCompilerLock;
        import snakebite.frontend.dmd.functions: findFunction;

        this.rootModules = rootModules;
        this.name = name;
        _checks = checks;
        _actions = actions;
        // The walks read the frontend's global state, which a thread that
        // evaluates a literal changes under the lock at the same time.
        withCompilerLock({
            _links = LinkMap(rootModules);
            foreach (module_; rootModules) {
                _rootModuleSet[module_] = true;
            }
            _isUnit = isUnit;
            // The modules of the program that the frontend read: the root
            // modules, when they are the whole program.
            foreach (module_; rootModules ~ otherUnitModules)
                _programModuleSet[module_] = true;

            foreach (module_; rootModules) {
                auto found = findFunction(module_, "main");
                if (found !is null) {
                    main = Main(found);
                    break;
                }
            }
        });
    }

    public Checks checks() const {
        return _checks;
    }

    // What a backend that can hold a function pointer stores.
    public HaltAction haltAction() const {
        return _actions.halt;
    }

    public noreturn halt() const {
        _actions.halt();
    }

    // The root definition that the linker makes of the declaration
    // `function_`, or `function_` itself. Backends ask this once for each
    // function, through `CallSelection.definitionOf`, not for each call.
    public FuncDeclaration linkedFunctionOf(
        FuncDeclaration function_,
    ) const {
        return _links.definitionOf(function_);
    }

    public bool definesLinkableFunctions() const {
        return _links.definesLinkableFunctions;
    }

    // As `linkedFunctionOf`, for an `extern` variable.
    public imported!"snakebite.frontend.ast".VarDeclaration linkedVariableOf(
        imported!"snakebite.frontend.ast".VarDeclaration variable,
    ) const {
        return _links.definitionOf(variable);
    }

    // A C-linkage `main` is the entry of the process, as the C runtime
    // calls it: druntime does not start, so a build with unit tests runs
    // none of them and no module constructor, and the program is only
    // that function.
    public bool hasCEntryPoint() const {
        import snakebite.frontend.ast: LINK;

        return main.func !is null
            && (cast() main.func).resolvedLinkage == LINK.c;
    }

    public bool isInterpreted(
        FuncDeclaration function_,
    ) const {
        return function_ !is null && isRootOwned(function_);
    }

    // Whether `declaration` belongs to one of this program's own root
    // modules, rather than one dmd only reached through an `import` - both
    // a callee (`isInterpreted`) and a type's own runtime metadata
    // (`RuntimeTypes`) need this same answer for the same reason: guest
    // source gets no linked machine code or linked `TypeInfo` of its own.
    // The frontend's own load-time walks (e.g. the inline-asm check) ask
    // the identical question, so the predicate itself lives once in
    // `snakebite.frontend.dmd.functions` and this forwards to it.
    public bool isRootOwned(
        Dsymbol declaration,
    ) const {
        import snakebite.frontend.dmd.functions:
            frontendIsRootOwned = isRootOwned;

        return frontendIsRootOwned(declaration, _rootModuleSet);
    }

    // Whether another object defines `declaration`: the one decision that
    // the call selection and the static data, TypeInfo and class information
    // take for a declaration (`snakebite.frontend.dmd.functions`). The units
    // of a program (`isUnit`) are not other objects: a declaration of another
    // unit is the program's, and the program and the other unit can both
    // define its data, as for a template instance. Only a function of
    // another unit has no body here (`isInOtherUnit`).
    public bool isDefinedElsewhere(
        Dsymbol declaration,
    ) const {
        import snakebite.frontend.dmd.functions:
            frontendIsDefinedElsewhere = isDefinedElsewhere;

        return frontendIsDefinedElsewhere(declaration, _programModuleSet);
    }

    // Whether only this program defines `declaration`, so that no other
    // object refers to it: a declaration of a root module, when the root
    // modules are the whole program. A unit (`isUnit`) shares each of its
    // definitions with the other units, as an object file exports a symbol:
    // the program and another object can both define it.
    public bool definesAlone(
        Dsymbol declaration,
    ) const {
        return !isUnit && isRootOwned(declaration);
    }

    // Whether the root modules are one unit of a larger program, which a link
    // makes from the files of its units (ADR-0021). The unit then names each
    // datum that another unit can refer to, as an object file names a
    // symbol.
    public bool isUnit() const {
        return _isUnit;
    }

    // Whether another unit of the program defines `declaration`: an object of
    // the program that is not this unit, as a native build of the unit sees
    // it.
    public bool isInOtherUnit(
        Dsymbol declaration,
    ) const {
        import snakebite.frontend.dmd.functions:
            frontendIsDefinedElsewhere = isDefinedElsewhere;

        return isUnit
            && frontendIsDefinedElsewhere(declaration, _rootModuleSet)
            && !frontendIsDefinedElsewhere(declaration, _programModuleSet);
    }
}
