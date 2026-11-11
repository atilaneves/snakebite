module snakebite.program;


private:


// The root modules of the guest program, parsed and semantically analysed by
// the frontend, and its entry point. A dub project is not special: a
// dub-aware driver asks dub for import paths and flags and builds one of
// these.
public struct Program {
    import snakebite.image.dependency: DependencyImage, TestHooks;
    import dmd.dmodule: Module;
    import dmd.func: FuncDeclaration;
    import dmd.dsymbol: Dsymbol;
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
    public imported!"dmd.declaration".VarDeclaration linkedVariableOf(
        imported!"dmd.declaration".VarDeclaration variable,
    ) const {
        return _links.definitionOf(variable);
    }

    // A C-linkage `main` is the entry of the process, as the C runtime
    // calls it: druntime does not start, so a build with unit tests runs
    // none of them and no module constructor, and the program is only
    // that function.
    public bool hasCEntryPoint() const {
        import dmd.astenums: LINK;

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
}
