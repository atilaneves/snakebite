module ut.backends.interpreter.nativestack;


import ut;
import snakebite.backends.interpreter.nativestack: InterpreterStack;


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
