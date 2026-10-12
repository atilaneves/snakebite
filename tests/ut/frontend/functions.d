module ut.frontend.functions;


import snakebite.frontend.compiler:
    FrontendFlags, parseRootModules, parseSnippet, returnsOnStack,
    withCompilerLock;
import snakebite.frontend.dmd.functions: contextOf, findFunction, moduleOf;
import ut;
import core.sync.semaphore: Semaphore;
import core.thread: Thread;
import core.time: seconds;
import snakebite.frontend.dmd.mangle: mangledNameOf;


// Equal filenames can name different modules. Path aliases must still
// select the same root, whether DMD kept an absolute or relative name.
static foreach (basis; ["absolute", "root", "import"]) {
    @("rootModules.pathAliases." ~ basis)
    unittest {
        enum directory = "/snakebite_root_lookup";
        enum prefix = directory ~ "/" ~ basis;
        enum left = prefix ~ "/left/same.d";
        enum right = prefix ~ "/right/same.d";
        enum leftSource = "module lookup_" ~ basis ~ "_left; int left() { return 1; }";
        enum rightSource = "module lookup_" ~ basis ~ "_right; int right() { return 2; }";
        const root = basis == "root" ? directory : null;
        const imports = basis == "import" ? [directory] : [];
        const flags = FrontendFlags.init;
        const dependencyImage = true;
        auto first = parseRootModules(
            [left], imports, flags, dependencyImage, [left: leftSource], root);
        auto second = parseRootModules(
            [right], imports, flags, dependencyImage, [right: rightSource], root);
        (first[0] is second[0]).should == false;
        (findFunction(first[0], "left") !is null).should == true;
        (findFunction(second[0], "right") !is null).should == true;

        enum leftAlias = prefix ~ "/left/unused/../same.d";
        enum rightAlias = prefix ~ "/right/./same.d";
        auto repeated = parseRootModules(
            [leftAlias, rightAlias], imports, flags, dependencyImage,
            [leftAlias: leftSource, rightAlias: rightSource], root);
        (repeated[0] is first[0]).should == true;
        (repeated[1] is second[0]).should == true;
    }
}


// An is-expression can test an invalid instance without rejecting the module.
@("findFunction.skipsFailedSpeculativeInstance")
unittest {
    auto module_ = parseSnippet(q{
        template Probe(T) {
            int ghost() { return T.noSuchMember; }
        }
        enum ignored = is(Probe!int == module);
        void main() {}
    });

    withCompilerLock({
        (findFunction(module_, "ghost") is null).should == true;
        (findFunction(module_, "main") !is null).should == true;
    });
}

// Executing a resolved function needs its settled owner and call context,
// even while another thread is doing unrelated semantic work in DMD.
@("metadata.warmReadsDoNotWaitForUnrelatedSemantic")
unittest {
    auto module_ = parseSnippet("auto answer() { return 42; }");
    auto function_ = findFunction(module_, "answer");
    auto ready = new Semaphore;
    auto repeat = new Semaphore;
    auto finished = new Semaphore;
    Throwable failure;
    const(char)[] name;
    auto worker = new Thread({
        try {
            (moduleOf(function_) is module_).should == true;
            (contextOf(function_).module_ is module_).should == true;
            name = mangledNameOf(function_);
        } catch (Throwable error) {
            failure = error;
        }
        ready.notify;
        repeat.wait;
        scope(exit) finished.notify;
        try {
            (moduleOf(function_) is module_).should == true;
            const context = contextOf(function_);
            (context.module_ is module_).should == true;
            (context.outerFunction is null).should == true;
            context.instantiated.should == false;
            context.templateParent.should == false;
            mangledNameOf(function_).should == name;
        } catch (Throwable error) {
            failure = error;
        }
    });
    worker.start;
    ready.wait;
    bool completed;
    withCompilerLock({
        repeat.notify;
        completed = finished.wait(5.seconds);
    });
    worker.join;
    if (failure !is null)
        throw failure;
    completed.should == true;
}


// A declaration has the same ownership and linker name on each thread.
@("metadata.answersAgreeAcrossThreads")
unittest {
    auto module_ = parseSnippet("auto publishedAnswer() { return 42; }");
    auto function_ = findFunction(module_, "publishedAnswer");
    (moduleOf(function_) is module_).should == true;
    const context = contextOf(function_);
    const name = mangledNameOf(function_);
    Throwable failure;
    auto worker = new Thread({
        try {
            (moduleOf(function_) is module_).should == true;
            contextOf(function_).should == context;
            mangledNameOf(function_).should == name;
        } catch (Throwable error) {
            failure = error;
        }
    });
    worker.start;
    worker.join;
    if (failure !is null)
        throw failure;
}


// ABI placement must agree across callers for scalar and aggregate returns.
@("metadata.returnPlacementAgreesAcrossThreads")
unittest {
    auto module_ = parseSnippet(q{
        int scalar() { return 42; }
        struct Large { long[4] values; }
        Large aggregate() { return Large.init; }
    });
    auto declarations = [ // DMD queries require mutable declarations.
        findFunction(module_, "scalar"),
        findFunction(module_, "aggregate"),
    ];
    const expected = [false, true];
    foreach (i, declaration; declarations)
        returnsOnStack(declaration).should == expected[i];
    Throwable failure;
    auto worker = new Thread({
        try {
            foreach (i, declaration; declarations)
                returnsOnStack(declaration).should == expected[i];
        } catch (Throwable error) {
            failure = error;
        }
    });
    worker.start;
    worker.join;
    if (failure !is null)
        throw failure;
}
