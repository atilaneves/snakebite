module ut.frontend.functions;


import snakebite.frontend.compiler: parseSnippet, withCompilerLock;
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
