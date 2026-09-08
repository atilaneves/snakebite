module ut.backends.bytecode.vm;


import ut;
import snakebite.backends.bytecode.vm:
    Arg, CallSite, Function, Instruction, opCall, opConstant,
    opResolveInterfaceMethod, opReturn, Vm;
import snakebite.ffi: PlanCache;
import snakebite.ffi.abi: Register;
import snakebite.framestack: defaultFrameCapacity;


// `snakebite.backends.bytecode.vm` compiles without any DMD frontend
// import path, so these tests build a `Function` by hand instead of
// compiling one from guest source - one for each `CallSite.Kind`, the
// same three shapes `snakebite.backends.bytecode.compiler` builds through
// `CallSite.guest`/`CallSite.native`/`CallSite.indirect`. `Function`'s own
// fields stay package-private even to a test module in this same source
// tree (D's package protection is name-, not path-, scoped), so every
// `Function` below is built through its positional field constructor
// rather than field assignment - `assertSites`/`exceptionHandlers` passed
// as empty literals, everything after left to its own default.


@("opCall.guestSite.callsCompiledFunction")
unittest {
    auto callee = new Function(
        [
            Instruction(&opConstant, 0, 0, int.sizeof),
            Instruction(&opReturn, 0, 0, int.sizeof),
        ],
        [42],
        [],
        [],
        [],
        int.sizeof,
        int.sizeof,
    );

    auto caller = Function(
        [
            Instruction(&opCall, 0, 0, 0),
            Instruction(&opReturn, 0, 0, int.sizeof),
        ],
        [],
        [CallSite.guest(callee, [], int.sizeof)],
        [],
        [],
        int.sizeof,
        int.sizeof,
    );

    auto vm = Vm(defaultFrameCapacity);
    int result;
    vm.call(caller, &result);

    result.should == 42;
}


// Exercises the same `PlanCache.rawPlanOf`/`executeCallPlan` path this
// backend's own bounds-check and allocation call sites go through -
// `abs` stands in for a druntime hook here only because it is a plain
// `extern(C)` symbol every host process already has loaded, with a
// return value simple enough to check without any FFI helper of its own.
@("opCall.nativeSite.callsResolvedSymbol")
unittest {
    PlanCache plans;
    auto plan = plans.rawPlanOf(
        "abs",
        [Register(Register.Kind.signed, 4)],
        Register(Register.Kind.signed, 4),
    );
    assert(plan !is null, "libc's `abs` should be resolvable by linker name");

    auto fn = Function(
        [
            Instruction(&opConstant, 0, 0, int.sizeof),
            Instruction(&opCall, 8, 0, 0),
            Instruction(&opReturn, 0, 8, int.sizeof),
        ],
        [-7],
        [
            CallSite.native(
                cast(const(void)*) plan, [Arg(0, 0, int.sizeof)],
                int.sizeof),
        ],
        [],
        [],
        16,
        8,
    );

    auto vm = Vm(defaultFrameCapacity);
    int result;
    vm.call(fn, &result);

    result.should == 7;
}


// `calleeSlotOffset` is read back from the caller's own frame at run
// time rather than fixed at compile time - the shape a call through a
// function pointer/delegate value or a resolved vtable slot needs.
// Two distinct callees prove which one actually ran: a bug that ignored
// the frame and always ran the first compiled function would still pass
// a single-callee test.
@("opCall.indirectSite.readsCalleeFromFrame")
unittest {
    auto calleeA = new Function(
        [
            Instruction(&opConstant, 0, 0, int.sizeof),
            Instruction(&opReturn, 0, 0, int.sizeof),
        ],
        [1],
        [],
        [],
        [],
        int.sizeof,
        int.sizeof,
    );

    auto calleeB = new Function(
        [
            Instruction(&opConstant, 0, 0, int.sizeof),
            Instruction(&opReturn, 0, 0, int.sizeof),
        ],
        [2],
        [],
        [],
        [],
        int.sizeof,
        int.sizeof,
    );

    auto caller = Function(
        [
            Instruction(&opConstant, 0, 0, size_t.sizeof),
            Instruction(&opCall, size_t.sizeof, 0, 0),
            Instruction(&opReturn, 0, size_t.sizeof, int.sizeof),
        ],
        [cast(long) cast(size_t) calleeB],
        [CallSite.indirect(0, [], int.sizeof)],
        [],
        [],
        size_t.sizeof + int.sizeof,
        size_t.sizeof,
    );

    auto vm = Vm(defaultFrameCapacity);
    int result;
    vm.call(caller, &result);

    result.should == 2;
}


private interface Greeter {
    int greet();
}

private class Formal: Greeter {
    override int greet() { return 111; }
}


// Not a `CallSite` at all - `opResolveInterfaceMethod` only computes an
// address, read back afterward through an ordinary `CallSite.indirect`
// call the same way `compileVirtualCall` does. `Formal`/`Greeter` are
// real, normally-compiled D types (this test module is itself compiled
// by the host D compiler, not by this project's own dmd-frontend-backed
// bytecode compiler), so `obj`'s vptr and its `TypeInfo_Class.interfaces`
// are the same shapes a real linked program's own interface dispatch
// reads - proving `opResolveInterfaceMethod` against genuine druntime
// metadata rather than a shape this project's own `classinfo.d` built.
@("opResolveInterfaceMethod.resolvesRealClassOverride")
unittest {
    auto obj = new Formal;
    auto interfaceInfo = obj.classinfo.interfaces[0].classinfo;

    auto fn = Function(
        [
            Instruction(&opConstant, 0, 0, size_t.sizeof),
            Instruction(&opResolveInterfaceMethod, size_t.sizeof, 0, 1,
                cast(size_t) cast(void*) interfaceInfo),
            Instruction(&opReturn, 0, size_t.sizeof, size_t.sizeof),
        ],
        [cast(long) cast(size_t) cast(void*) obj],
        [],
        [],
        [],
        size_t.sizeof * 2,
        size_t.sizeof,
    );

    auto vm = Vm(defaultFrameCapacity);
    void* result;
    vm.call(fn, &result);

    int delegate() greet;
    greet.ptr = cast(void*) obj;
    greet.funcptr = cast(int function()) result;

    greet().should == 111;
}
