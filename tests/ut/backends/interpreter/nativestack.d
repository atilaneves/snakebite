module ut.backends.interpreter.nativestack;


import ut;
import snakebite.backends.interpreter.nativestack: InterpreterStack;
import snakebite.backends.backend: Program;
import snakebite.backends.interpreter: Interpreter;
import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;


// `InterpreterStack.active` tracks whether a host-to-guest call is
// switched onto this stack and has not yet unwound back through
// `Evaluator.runOnInterpreterStack`'s own `scope(exit)`
// (source/snakebite/backends/interpreter/walker.d). While it is set, a
// guest `Fiber`'s own `StackContext` may still name this stack's mapping -
// left there by an abandoned fiber (suspended mid-call, never resumed) or
// by `Fiber.reset` writing a fresh entry frame onto it, per that
// destructor's own documentation (nativestack.d). Destroying the
// `InterpreterStack` while that is true must not unmap the memory such a
// context still points at: the next collection on any thread would then
// read unmapped memory the moment it reached that context.
//
// One page is enough stack for this test - nothing ever runs on it, only
// its mapping's presence is probed - and keeps the probe's own `mprotect`
// call cheap.
@("interpreterStack.destructor.leavesMappingInPlaceWhileActive")
unittest {
    import core.memory: pageSize;

    auto stack = InterpreterStack(pageSize);
    stack.active = true;
    ubyte* probe = cast(ubyte*) stack.top - pageSize;

    destroy(stack);

    mappingIsPresent(probe).should == true;
}


// The ordinary case - nothing switched onto this stack when it goes out
// of scope - must still free its memory: the guard above must not turn
// the destructor into an unconditional leak.
@("interpreterStack.destructor.unmapsWhenNotActive")
unittest {
    import core.memory: pageSize;

    auto stack = InterpreterStack(pageSize);
    ubyte* probe = cast(ubyte*) stack.top - pageSize;

    destroy(stack);

    mappingIsPresent(probe).should == false;
}


// Regression test for review comment
// https://github.com/atilaneves/snakebite/pull/426#discussion_r4082454024
// point (a). `Evaluator.runOnInterpreterStack` (walker.d) repoints the
// active guest `Fiber`'s own `StackContext.bstack` at the dedicated
// `InterpreterStack` for as long as the switch lasts, which correctly
// extends druntime's scan to that dedicated stack - but for the same
// duration it also drops the guest `Fiber`'s *own* small stack from the
// scan. Every frame between the `Fiber`'s entry point and the switch
// itself sits below `savedBstack`, on a stack no `StackContext` names
// while the switch is active.
//
// When a *host* owns the `Fiber` and calls guest code from inside it (a
// vibe.d-style task, say - ADR-0005's own scenario; here, a bare
// `core.thread.fiber.Fiber` this unittest creates directly), a value the
// host keeps live only in one of those abandoned frames is exactly the
// kind of root the conservative scan is supposed to find on its own.
// `box` is a plain local in the `Fiber`'s own entry delegate - never
// stored in a global, `__gshared`, or the frame stack, so nothing but
// that stack slot roots it - and `forceCollection` (guest code) forces a
// collection while the switch onto `InterpreterStack` is active, mid
// `backend.call`. `box.value` is read back in that same host frame right
// after: unless the abandoned span is separately registered with the GC
// (`GC.addRange`, `Evaluator.callOnInterpreterStack`), nothing roots
// `box` during that collection.
@("nativeStack.hostFiberOwnStackSurvivesCollectionDuringSwitch")
unittest {
    import core.thread.fiber: Fiber;

    auto guestModule = parseSnippet(q{
        void forceCollection() {
            import core.memory: GC;

            GC.collect();
        }
    });
    auto function_ = findFunction(guestModule, "forceCollection");
    assert(
        function_ !is null,
        "No function `forceCollection` in the guest program");
    auto backend = new Interpreter(Program([guestModule]));

    static class Box {
        int value;
    }

    int survivorValue = -1;
    auto fiber = new Fiber({
        auto box = new Box;
        box.value = 42;

        backend.call(function_, null, []);

        // `GC.collect()` above never overwrites freed bytes on its own -
        // it only decides whether `box`'s block is reachable. If the
        // switch left it unscanned, the block is now on the free list,
        // and D's GC hands a same-size-class allocation the most
        // recently freed block first - so whichever slot the collection
        // just freed (if `box` went unscanned) is what these get back.
        // With the fix, `box` was found live, never freed, and these
        // land on wholly different memory.
        foreach (_; 0 .. 64)
            cast(void) new Box;

        survivorValue = box.value;
    });
    fiber.call();

    survivorValue.should == 42;
}


// Whether the page at `address` is still mapped, without reading or
// writing through it: re-applying the exact permissions
// `InterpreterStack`'s own constructor already granted this page is a
// no-op if the mapping is still there, and fails with `ENOMEM` if it is
// not - the same safe presence probe `mprotect` gives any other caller
// that does not want to risk a segfault finding out by touching the
// memory itself.
private bool mappingIsPresent(ubyte* address) @system {
    import core.memory: pageSize;
    import core.sys.posix.sys.mman: mprotect, PROT_READ, PROT_WRITE;

    return mprotect(address, pageSize, PROT_READ | PROT_WRITE) == 0;
}
