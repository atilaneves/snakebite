module ut.frontend.functions;


import snakebite.frontend.compiler:
    parseSnippet, returnsOnStack, withCompilerLock;
import snakebite.frontend.dmd.functions: contextOf, findFunction, moduleOf;
import ut;
import core.sync.semaphore: Semaphore;
import core.thread: Thread;
import core.time: seconds;
import snakebite.frontend.dmd.mangle: mangledNameOf;


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


// Frontend ownership and linker names belong to the declaration. A thread
// that has not used it yet must be able to reuse another thread's snapshot.
@("metadata.publishedReadsDoNotWaitForUnrelatedSemantic")
unittest {
    auto module_ = parseSnippet("auto publishedAnswer() { return 42; }");
    auto function_ = findFunction(module_, "publishedAnswer");
    (moduleOf(function_) is module_).should == true;
    const context = contextOf(function_);
    const name = mangledNameOf(function_);
    auto begin = new Semaphore;
    auto finished = new Semaphore;
    Throwable failure;
    auto worker = new Thread({
        begin.wait;
        scope(exit) finished.notify;
        try {
            (moduleOf(function_) is module_).should == true;
            contextOf(function_).should == context;
            mangledNameOf(function_).should == name;
        } catch (Throwable error) {
            failure = error;
        }
    });
    worker.start;
    bool completed;
    withCompilerLock({
        begin.notify;
        completed = finished.wait(5.seconds);
    });
    worker.join;
    if (failure !is null)
        throw failure;
    completed.should == true;
}


// ABI classification is fixed after semantic analysis. Different callers
// of the same declaration must be able to reuse its completed answer.
@("metadata.returnPlacementDoesNotWaitForUnrelatedSemantic")
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
    const expected = [
        returnsOnStack(declarations[0]),
        returnsOnStack(declarations[1]),
    ];
    expected.should == [false, true];
    auto begin = new Semaphore;
    auto finished = new Semaphore;
    Throwable failure;
    auto worker = new Thread({
        begin.wait;
        scope(exit) finished.notify;
        try {
            foreach (i, declaration; declarations)
                returnsOnStack(declaration).should == expected[i];
        } catch (Throwable error) {
            failure = error;
        }
    });
    worker.start;
    bool completed;
    withCompilerLock({
        begin.notify;
        completed = finished.wait(5.seconds);
    });
    worker.join;
    if (failure !is null)
        throw failure;
    completed.should == true;
}
