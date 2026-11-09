module ut.backends.bytecode.jit;


import ut.backends;
import snakebite.backends.backend: Program;
import snakebite.backends.bytecode.inspection: isJitCompiled;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;
import core.atomic: atomicLoad, atomicOp, atomicStore;
import core.thread: Thread;


private enum source = q{
    module jitsample;
    long hot(long n) {
        long sum;
        foreach (i; 0 .. n)
            sum += i % 7;
        return sum;
    }
    long cold(long n) { return n + 1; }
};

// A function that the host calls 300 times has JIT code, and still returns
// what the handlers return. Without the JIT there is nothing to look at.
@("jit.hotFunctionHasJitCode")
unittest {
    if (!testJit.enabled)
        return;
    auto guestModule = parseSnippet(source);
    auto program = Program([guestModule]);
    auto backend = ownedBackend!Bytecode(program);
    auto hot = findFunction(guestModule, "hot");
    long result;
    foreach (round; 0 .. 300) {
        long n = round;
        backend.call(hot, &result, [cast(void*) &n]);
        result.should == (n / 7) * 21 + [0, 0, 1, 3, 6, 10, 15][n % 7];
    }

    bool hotCompiled;
    backend.eachCompiled((declaration, function_) {
        if (declaration.ident.toString == "hot")
            hotCompiled = isJitCompiled(function_);
    });
    hotCompiled.should == true;
}

// Eight threads make one function hot at the same moment: one compiles it,
// the others keep running handlers or move to the code, and all get the same
// answer.
@("jit.severalThreadsMakeTheSameFunctionHot")
unittest {
    if (!testJit.enabled)
        return;
    auto guestModule = parseSnippet(source);
    auto program = Program([guestModule]);
    auto backend = ownedBackend!Bytecode(program);
    auto hot = findFunction(guestModule, "hot");

    enum threadCount = 8;
    shared size_t ready;
    shared bool go;
    shared size_t wrong;
    auto threads = new Thread[threadCount];
    foreach (ref thread; threads) {
        thread = new Thread({
            atomicOp!"+="(ready, 1);
            while (!atomicLoad(go)) {}
            foreach (round; 0 .. 100) {
                long n = 700;
                long result;
                backend.call(hot, &result, [cast(void*) &n]);
                if (result != 2100)
                    atomicOp!"+="(wrong, 1);
            }
        });
        thread.start;
    }
    while (atomicLoad(ready) < threadCount) {}
    atomicStore(go, true);
    foreach (thread; threads)
        thread.join;

    atomicLoad(wrong).should == 0;
    bool compiled;
    backend.eachCompiled((declaration, function_) {
        if (declaration.ident.toString == "hot")
            compiled = isJitCompiled(function_);
    });
    compiled.should == true;
}

// A function that the host calls once, and whose do-while loop runs 10000
// times, is
// hot at its backward branch, a conditional branch.
@("jit.functionCalledOnceIsHotAtItsDoWhileLoop")
@Tags("changes-jit") // The JIT choice is process-wide.
unittest {
    withDefaultJit({
        auto guestModule = parseSnippet(q{
            module jitloop;
            long loop(long n) {
                long sum;
                long i;
                do {
                    sum += i % 7;
                    ++i;
                } while (i < n);
                return sum;
            }
        });
        auto program = Program([guestModule]);
        auto backend = Owned!Bytecode(program);
        auto loop = findFunction(guestModule, "loop");
        long n = 10_000;
        long result;
        backend.call(loop, &result, [cast(void*) &n]);
        result.should == (n / 7) * 21 + [0, 0, 1, 3, 6, 10, 15][n % 7];

        bool compiled;
        backend.eachCompiled((declaration, function_) {
            if (declaration.ident.toString == "loop")
                compiled = isJitCompiled(function_);
        });
        compiled.should == true;
    });
}
