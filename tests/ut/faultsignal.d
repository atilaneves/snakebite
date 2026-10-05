module ut.faultsignal;


import core.sys.posix.signal: SIGBUS, SIGFPE, SIGSEGV;
import snakebite.backends.guestfault: GuestFault;
import snakebite.backends.haltprocess: Halted, isHalt;
import snakebite.faultsignal:
    classify,
    Divisor,
    divisorOf,
    FaultReport,
    GuestRun,
    HardwareFault,
    installFaultHandlers,
    takeFault;
import ut;


version (linux) version (X86_64):


// What the faulting instruction reads, with the registers numbered as the
// hardware does them.
private enum rax = 0;
private enum rcx = 1;
private enum rdx = 2;
private enum rbx = 3;
private enum rsp = 4;
private enum rbp = 5;
private enum rsi = 6;
private enum rdi = 7;
private enum r9 = 9;
private enum r12 = 12;

private Divisor decoded(
    in ubyte[] instruction, in ulong[16] registers = ulong[16].init,
) @trusted {
    // The decoder reads the bytes after the instruction too, as far as the
    // encoding says: pad so that a test never reads outside the array.
    auto bytes = instruction ~ new ubyte[16];
    return divisorOf(bytes.ptr, registers);
}

// `registersWith(rcx, 5, r9, 0)` has `rcx` of 5 and `r9` of 0.
private ulong[16] registersWith(in ulong[] numbersAndValues...) {
    ulong[16] registers;
    for (size_t index = 0; index < numbersAndValues.length; index += 2)
        registers[numbersAndValues[index]] = numbersAndValues[index + 1];
    return registers;
}


@("faultsignal.divisorOf.idivRegisterZero")
unittest {
    // idiv ecx
    decoded([0xf7, 0xf9], registersWith(rcx, 0)).should == Divisor.zero;
}

@("faultsignal.divisorOf.idivRegisterMinusOne")
unittest {
    // idiv ecx
    decoded([0xf7, 0xf9], registersWith(rcx, uint.max))
        .should == Divisor.nonZero;
}

@("faultsignal.divisorOf.divRegisterZero")
unittest {
    // div ecx
    decoded([0xf7, 0xf1], registersWith(rcx, 0)).should == Divisor.zero;
}

@("faultsignal.divisorOf.thirtyTwoBitOperandIgnoresTheHighHalf")
unittest {
    // idiv ecx: the register holds a nonzero upper half, the divisor is zero.
    decoded([0xf7, 0xf9], registersWith(rcx, 1UL << 32))
        .should == Divisor.zero;
}

@("faultsignal.divisorOf.sixtyFourBitOperandReadsTheHighHalf")
unittest {
    // idiv rcx
    decoded([0x48, 0xf7, 0xf9], registersWith(rcx, 1UL << 32))
        .should == Divisor.nonZero;
}

@("faultsignal.divisorOf.sixtyFourBitOperandZero")
unittest {
    // idiv rcx
    decoded([0x48, 0xf7, 0xf9], registersWith(rcx, 0))
        .should == Divisor.zero;
}

@("faultsignal.divisorOf.extendedRegisterZero")
unittest {
    // idiv r9d: REX.B selects r9
    decoded([0x41, 0xf7, 0xf9], registersWith(r9, 0, rcx, 5))
        .should == Divisor.zero;
}

@("faultsignal.divisorOf.extendedRegisterNonZero")
unittest {
    decoded([0x41, 0xf7, 0xf9], registersWith(r9, 3, rcx, 0))
        .should == Divisor.nonZero;
}

@("faultsignal.divisorOf.eightBitOperandZero")
unittest {
    // idiv cl
    decoded([0xf6, 0xf9], registersWith(rcx, 0x100)).should == Divisor.zero;
}

@("faultsignal.divisorOf.eightBitOperandNonZero")
unittest {
    // idiv cl
    decoded([0xf6, 0xf9], registersWith(rcx, 0x101))
        .should == Divisor.nonZero;
}

@("faultsignal.divisorOf.highByteRegisterZero")
unittest {
    // idiv ah: without a REX prefix, register 4 of a byte operand is ah.
    decoded([0xf6, 0xfc], registersWith(rax, 0x0001))
        .should == Divisor.zero;
}

@("faultsignal.divisorOf.highByteRegisterNonZero")
unittest {
    decoded([0xf6, 0xfc], registersWith(rax, 0x0100))
        .should == Divisor.nonZero;
}

@("faultsignal.divisorOf.rexByteRegisterIsTheLowByte")
unittest {
    // idiv sil: with a REX prefix, register 6 of a byte operand is sil.
    decoded([0x40, 0xf6, 0xfe], registersWith(rsi, 0x0100))
        .should == Divisor.zero;
}

@("faultsignal.divisorOf.sixteenBitOperandZero")
unittest {
    // idiv cx
    decoded([0x66, 0xf7, 0xf9], registersWith(rcx, 0x10000))
        .should == Divisor.zero;
}

@("faultsignal.divisorOf.sixteenBitOperandNonZero")
unittest {
    decoded([0x66, 0xf7, 0xf9], registersWith(rcx, 0x10001))
        .should == Divisor.nonZero;
}

@("faultsignal.divisorOf.memoryThroughARegisterZero")
unittest {
    int[2] values = [0, -1];
    // idiv dword ptr [rbx]
    decoded([0xf7, 0x3b], registersWith(rbx, cast(size_t) &values[0]))
        .should == Divisor.zero;
}

@("faultsignal.divisorOf.memoryThroughARegisterNonZero")
unittest {
    int[2] values = [0, -1];
    decoded([0xf7, 0x3b], registersWith(rbx, cast(size_t) &values[1]))
        .should == Divisor.nonZero;
}

@("faultsignal.divisorOf.memoryWithEightBitDisplacement")
unittest {
    int[2] values = [-1, 0];
    // idiv dword ptr [rbp + 4]
    decoded([0xf7, 0x7d, 0x04], registersWith(rbp, cast(size_t) &values[0]))
        .should == Divisor.zero;
}

@("faultsignal.divisorOf.memoryWithNegativeEightBitDisplacement")
unittest {
    int[2] values = [0, -1];
    // idiv dword ptr [rbp - 4]: the displacement is signed.
    decoded([0xf7, 0x7d, 0xfc], registersWith(rbp, cast(size_t) &values[1]))
        .should == Divisor.zero;
}

@("faultsignal.divisorOf.memoryWithThirtyTwoBitDisplacement")
unittest {
    int[2] values = [-1, 0];
    // idiv dword ptr [rbp + 0x1004]
    decoded([0xf7, 0xbd, 0x04, 0x10, 0x00, 0x00],
        registersWith(rbp, cast(size_t) &values[0] - 0x1000))
        .should == Divisor.zero;
}

@("faultsignal.divisorOf.memoryWithNegativeThirtyTwoBitDisplacement")
unittest {
    int[2] values = [-1, 0];
    // idiv dword ptr [rbp - 0x1000]
    decoded([0xf7, 0xbd, 0x00, 0xf0, 0xff, 0xff],
        registersWith(rbp, cast(size_t) &values[1] + 0x1000))
        .should == Divisor.zero;
}

@("faultsignal.divisorOf.memoryWithScaledIndexZero")
unittest {
    int[4] values = [-1, -1, 0, -1];
    // idiv dword ptr [rax + rbx * 4]
    decoded([0xf7, 0x3c, 0x98],
        registersWith(rax, cast(size_t) &values[0], rbx, 2))
        .should == Divisor.zero;
}

@("faultsignal.divisorOf.memoryWithScaledIndexNonZero")
unittest {
    int[4] values = [-1, -1, 0, -1];
    decoded([0xf7, 0x3c, 0x98],
        registersWith(rax, cast(size_t) &values[0], rbx, 3))
        .should == Divisor.nonZero;
}

@("faultsignal.divisorOf.memoryWithIndexAndNoBaseZero")
unittest {
    int[2] values = [0, -1];
    // idiv dword ptr [rbx * 4 + 0]: mod 0 and base 5 mean no base, so rbp
    // must not be added. The address is a multiple of 4.
    decoded([0xf7, 0x3c, 0x9d, 0x00, 0x00, 0x00, 0x00],
        registersWith(rbx, cast(size_t) &values[0] / 4, rbp, 0x1000))
        .should == Divisor.zero;
}

@("faultsignal.divisorOf.memoryWithIndexAndNoBaseNonZero")
unittest {
    int[2] values = [0, -1];
    decoded([0xf7, 0x3c, 0x9d, 0x00, 0x00, 0x00, 0x00],
        registersWith(rbx, cast(size_t) &values[1] / 4, rbp, 0x1000))
        .should == Divisor.nonZero;
}

@("faultsignal.divisorOf.memoryWithExtendedIndexAndBaseZero")
unittest {
    long[2] values = [0, 5];
    // idiv qword ptr [r9 + r12 * 8]: REX.W, REX.X, REX.B
    decoded([0x4b, 0xf7, 0x3c, 0xe1],
        registersWith(r9, cast(size_t) &values[0], r12, 0))
        .should == Divisor.zero;
}

@("faultsignal.divisorOf.memoryWithExtendedIndexAndBaseNonZero")
unittest {
    long[2] values = [0, 5];
    decoded([0x4b, 0xf7, 0x3c, 0xe1],
        registersWith(r9, cast(size_t) &values[0], r12, 1))
        .should == Divisor.nonZero;
}

@("faultsignal.divisorOf.memoryAtTheStackPointer")
unittest {
    int[2] values = [3, 0];
    // idiv dword ptr [rsp + 4]: a base of rsp needs an index byte.
    decoded([0xf7, 0x7c, 0x24, 0x04],
        registersWith(rsp, cast(size_t) &values[0]))
        .should == Divisor.zero;
}

// idiv dword ptr [rip + displacement]: the displacement counts from the end
// of the instruction, which is 6 bytes long. The data is next to the code: a
// displacement has 32 bits.
private Divisor decodedRelativeToTheInstructionPointer(in size_t dataIndex) @trusted {
    struct Layout {
        ubyte[6] code;
        int[2] data;
        ubyte[16] padding;
    }

    Layout layout;
    layout.code = [0xf7, 0x3d, 0, 0, 0, 0];
    layout.data = [1, 0];
    const end = cast(long) &layout + 6;
    *cast(int*) (layout.code.ptr + 2) =
        cast(int) (cast(long) &layout.data[dataIndex] - end);
    return divisorOf(layout.code.ptr, ulong[16].init);
}

@("faultsignal.divisorOf.memoryRelativeToTheInstructionPointerNonZero")
unittest {
    decodedRelativeToTheInstructionPointer(0).should == Divisor.nonZero;
}

@("faultsignal.divisorOf.memoryRelativeToTheInstructionPointerZero")
unittest {
    decodedRelativeToTheInstructionPointer(1).should == Divisor.zero;
}

@("faultsignal.divisorOf.nopIsUnknown")
unittest {
    decoded([0x90]).should == Divisor.unknown;
}

@("faultsignal.divisorOf.otherOperationOfTheSameOpcodeIsUnknown")
unittest {
    // neg ecx: the opcode of idiv, another operation
    decoded([0xf7, 0xd9]).should == Divisor.unknown;
}

@("faultsignal.divisorOf.otherOpcodeIsUnknown")
unittest {
    // mov eax, [rax]
    decoded([0x8b, 0x00]).should == Divisor.unknown;
}

@("faultsignal.divisorOf.overrideOfTheSegmentBaseIsUnknown")
unittest {
    // idiv dword ptr fs:[rbx]: the base of fs is not a register.
    decoded([0x64, 0xf7, 0x3b], registersWith(rbx, 0))
        .should == Divisor.unknown;
}

@("faultsignal.divisorOf.overrideOfTheAddressSizeIsUnknown")
unittest {
    // idiv dword ptr [ebx]: the 0x67 prefix makes the address 32 bits wide.
    decoded([0x67, 0xf7, 0x3b], registersWith(rbx, 0))
        .should == Divisor.unknown;
}


private FaultReport report(
    in int signal, in int code, in size_t address, in size_t pc = 0x400000,
    in Divisor divisor = Divisor.unknown,
) {
    return FaultReport(signal, code, address, pc, divisor);
}

private enum segvMapError = 1;
private enum segvAccessError = 2;
private enum sigKernel = 0x80;
private enum fpeIntegerDivide = 1;

static foreach (address; [0UL, 8, 8000, 65_535]) {
    @("faultsignal.classify.addressInTheFirstPageIsNull." ~ address.stringof)
    unittest {
        classify(report(SIGSEGV, segvMapError, address))
            .should == GuestFault.Kind.nullDereference;
    }
}

static foreach (address; [65_536UL, 0x7000_0000_0000]) {
    @("faultsignal.classify.addressAfterTheFirstPageIsInvalid." ~ address.stringof)
    unittest {
        classify(report(SIGSEGV, segvMapError, address))
            .should == GuestFault.Kind.invalidAccess;
    }
}

@("faultsignal.classify.protectionFaultInTheFirstPageIsNull")
unittest {
    classify(report(SIGSEGV, segvAccessError, 16))
        .should == GuestFault.Kind.nullDereference;
}

@("faultsignal.classify.nonCanonicalAddressIsNotANullPointer")
unittest {
    // The kernel gives `si_addr` of 0 for it: that is not the address.
    classify(report(SIGSEGV, sigKernel, 0))
        .should == GuestFault.Kind.invalidAccess;
}

@("faultsignal.classify.jumpToTheFirstPageIsANullCall")
unittest {
    classify(report(SIGSEGV, segvMapError, 0, 0))
        .should == GuestFault.Kind.nullCall;
}

@("faultsignal.classify.jumpToAnUnmappedAddressIsInvalid")
unittest {
    classify(report(SIGSEGV, segvMapError, 0x7000_0000_0000, 0x7000_0000_0000))
        .should == GuestFault.Kind.invalidAccess;
}

@("faultsignal.classify.busErrorIsInvalid")
unittest {
    classify(report(SIGBUS, 2, 0)).should == GuestFault.Kind.invalidAccess;
}

@("faultsignal.classify.divisionByZero")
unittest {
    classify(report(SIGFPE, fpeIntegerDivide, 0, 0x400000, Divisor.zero))
        .should == GuestFault.Kind.divisionByZero;
}

@("faultsignal.classify.divisionOverflow")
unittest {
    classify(report(SIGFPE, fpeIntegerDivide, 0, 0x400000, Divisor.nonZero))
        .should == GuestFault.Kind.divisionOverflow;
}

@("faultsignal.classify.divisionOfAnUnknownInstruction")
unittest {
    classify(report(SIGFPE, fpeIntegerDivide, 0, 0x400000, Divisor.unknown))
        .should == GuestFault.Kind.divisionFault;
}


// The helpers that fault. Not inlined and with the operands unknown to the
// compiler, so that the hardware does the work.
private int load(int* pointer) {
    pragma(inline, false);
    return *pointer;
}

private void store(int* pointer) {
    pragma(inline, false);
    *pointer = 3;
}

private int divide(int dividend, int divisor) {
    pragma(inline, false);
    return dividend / divisor;
}

private long divideLong(long dividend, long divisor) {
    pragma(inline, false);
    return dividend % divisor;
}

private void call(void function() function_) {
    pragma(inline, false);
    function_();
}

private int[] cleanups;

private int loadThroughAFrameWithCleanup(int* pointer) {
    pragma(inline, false);
    scope(exit) cleanups ~= 1;
    return load(pointer);
}

private int loadThroughAFrameThatFaultsInCleanup(int* pointer) {
    pragma(inline, false);
    scope(exit) load(null);
    return load(pointer);
}

// One fault, as the hardware makes it, and the throwable that the thread
// gets. A division trap has no address of an access.
private enum noAddress = size_t.max;

private struct Shape {
    string name;
    void function() fault;
    GuestFault.Kind kind;
    size_t address;
}

private immutable Shape[] shapes = [
    Shape("nullRead", () { load(null); }, GuestFault.Kind.nullDereference, 0),
    Shape("nullWrite", () { store(null); }, GuestFault.Kind.nullDereference, 0),
    Shape("fieldBehindNull", () { load(cast(int*) 8000); },
        GuestFault.Kind.nullDereference, 8000),
    Shape("unmappedAddress", () { load(cast(int*) 0x7000_0000_0000); },
        GuestFault.Kind.invalidAccess, 0x7000_0000_0000),
    Shape("nonCanonicalAddress",
        () { load(cast(int*) 0xdead_beef_dead_beef); },
        GuestFault.Kind.invalidAccess, 0),
    Shape("nullCall", () { call(null); }, GuestFault.Kind.nullCall, 0),
    Shape("unmappedCall", () { call(cast(void function()) 0x7000_0000_0000); },
        GuestFault.Kind.invalidAccess, 0x7000_0000_0000),
    Shape("divisionByZero", () { divide(5, int.max - int.max); },
        GuestFault.Kind.divisionByZero, noAddress),
    Shape("divisionOverflow", () { divide(int.min, int.max - int.max - 1); },
        GuestFault.Kind.divisionOverflow, noAddress),
    Shape("moduloByZero", () { divideLong(5, long.max - long.max); },
        GuestFault.Kind.divisionByZero, noAddress),
    Shape("moduloOverflow", () { divideLong(long.min, long.max - long.max - 1); },
        GuestFault.Kind.divisionOverflow, noAddress),
];

private HardwareFault faultOf(void function() fault) {
    auto run = GuestRun.begin;
    try
        fault();
    catch (HardwareFault caught) {
        takeFault(caught);
        return caught;
    }

    assert(0, "the fault did not end the call");
}

static foreach (shape; shapes) {
    @("faultsignal.guestRun.throws." ~ shape.name)
    unittest {
        installFaultHandlers.shouldBeTrue;

        foreach (round; 0 .. 100) {
            const fault = faultOf(shape.fault);

            fault.kind.should == shape.kind;
            if (shape.address != noAddress)
                fault.address.should == shape.address;
            fault.msg.should == GuestFault.message(shape.kind);
        }
    }
}


@("faultsignal.guestRun.faultIsAHaltThatNoGuestCodeCatches")
unittest {
    installFaultHandlers.shouldBeTrue;

    const Throwable fault = faultOf(shapes[0].fault);

    isHalt(fault).shouldBeTrue;
    (cast(Halted) fault).shouldNotBeNull;
    (cast(Exception) fault).shouldBeNull;
    (cast(Error) fault).shouldBeNull;
}


@("faultsignal.guestRun.throwsAgainAfterACatch")
unittest {
    installFaultHandlers.shouldBeTrue;
    auto run = GuestRun.begin;

    foreach (round; 0 .. 1000) {
        try
            load(null);
        catch (HardwareFault fault) {
            takeFault(fault);
            fault.kind.should == GuestFault.Kind.nullDereference;
            continue;
        }
        assert(0, "the fault did not end the call");
    }
}


@("faultsignal.guestRun.unwindsThroughTheCleanupOfCallerFrames")
unittest {
    installFaultHandlers.shouldBeTrue;
    auto run = GuestRun.begin;
    cleanups = null;

    try
        loadThroughAFrameWithCleanup(null);
    catch (HardwareFault fault) {
        takeFault(fault);
    }

    cleanups.should == [1];
}


@("faultsignal.guestRun.runsNest")
unittest {
    installFaultHandlers.shouldBeTrue;
    auto outer = GuestRun.begin;
    {
        auto inner = GuestRun.begin;
    }

    faultOf(shapes[0].fault).kind.should == GuestFault.Kind.nullDereference;
}


@("faultsignal.guestRun.keepsTheAlternateStackOfTheGuest")
unittest {
    import core.sys.posix.signal: SS_DISABLE, sigaltstack, stack_t;
    import core.thread: Thread;

    installFaultHandlers.shouldBeTrue;
    void* current;
    void* own;
    auto thread = new Thread({
        auto memory = new ubyte[64 * 1024];
        own = memory.ptr;
        stack_t guest;
        guest.ss_sp = memory.ptr;
        guest.ss_size = memory.length;
        sigaltstack(&guest, null);

        {
            auto run = GuestRun.begin;
            stack_t after;
            sigaltstack(null, &after);
            current = after.ss_sp;
        }

        stack_t disabled;
        disabled.ss_flags = SS_DISABLE;
        sigaltstack(&disabled, null);
    });
    thread.start;
    thread.join;

    current.should == own;
}


@("faultsignal.guestRun.manyThreadsWhileAnotherCollects")
unittest {
    import core.atomic: atomicLoad, atomicStore;
    import core.memory: GC;
    import core.thread: Thread;

    installFaultHandlers.shouldBeTrue;
    shared bool done;
    auto collector = new Thread({
        while (!atomicLoad(done)) {
            GC.collect;
            // kcov pins all threads to one CPU. Let the faulting threads run
            // between collections instead of suspending them again at once.
            Thread.yield;
        }
    });
    collector.start;

    enum threadCount = 8;
    enum rounds = 1000;
    shared size_t wrong;
    Thread[] threads;
    foreach (index; 0 .. threadCount) {
        threads ~= new Thread({
            import core.atomic: atomicOp;

            auto run = GuestRun.begin;
            foreach (round; 0 .. rounds) {
                const shape = shapes[(index + round) % shapes.length];
                try
                    shape.fault();
                catch (HardwareFault fault) {
                    takeFault(fault);
                    if (fault.kind != shape.kind)
                        atomicOp!"+="(wrong, 1);
                    continue;
                }
                atomicOp!"+="(wrong, 1);
            }
        });
        threads[$ - 1].start;
    }

    foreach (thread; threads)
        thread.join;
    atomicStore(done, true);
    collector.join;

    atomicLoad(wrong).should == 0;
}


@("faultsignal.guestRun.releasesTheAlternateStackOfARawPthread")
unittest {
    import core.sys.linux.sys.prctl: prctl;
    import core.sys.posix.pthread: pthread_create, pthread_join, pthread_t;
    import core.sys.posix.signal: sigaltstack, stack_t;
    import std.file: readText;

    enum name = "snakebite-fault-stack-leak-test";

    // A foreign thread must release its stack without druntime attachment.
    static extern(C) void* enter(void* result) {
        auto run = GuestRun.begin;
        stack_t current;
        sigaltstack(null, &current);
        // Address reuse by another test must not look like a leaked stack.
        enum setVma = 0x53564d41;
        enum setAnonymousName = 0;
        *cast(int*) result = prctl(setVma, setAnonymousName,
            cast(size_t) current.ss_sp, current.ss_size,
            cast(size_t) (name ~ "\0").ptr);
        return null;
    }

    foreach (round; 0 .. 10) {
        int named;
        pthread_t thread;
        pthread_create(&thread, null, &enter, &named).should == 0;
        pthread_join(thread, null).should == 0;
        named.should == 0;
        name.should.not.be in readText("/proc/self/maps");
    }
}


// A fault that no guest run owns is a defect of the host, and the host
// keeps the default action of the signal. That ends the process, so these
// tests run the test binary as a child process and look at how it died.
private enum childVariable = "SNAKEBITE_UT_FAULT_CHILD";

private struct Child {
    int status;
    string output;
}

private Child runChild(
    in string scenario, string[string] environment = null,
) {
    import std.process: Config, execute;
    import std.file: thisExePath;

    environment[childVariable] = scenario;
    // unit-threaded removes its relative sandbox path in a shared static
    // constructor, before main can dispatch to runFaultChild. Give the child
    // a private working directory so it cannot remove the parent's sandbox.
    const childSandbox = Sandbox();
    const result = execute(
        [thisExePath], environment, Config.none, size_t.max,
        childSandbox.sandboxPath);
    return Child(result.status, result.output);
}

@("faultsignal.hostDefect.childDoesNotRemoveParentSandbox")
unittest {
    const sandbox = Sandbox();
    sandbox.writeFile("parent-fixture", "must survive child startup");

    runChild("faultInCleanup");

    sandbox.shouldExist("parent-fixture");
}

private enum killedBySegmentationFault = -SIGSEGV;
private enum killedByArithmeticFault = -SIGFPE;

@("faultsignal.hostDefect.nullReadOutsideAGuestRunKeepsItsStatus")
unittest {
    const child = runChild("hostNullRead");

    child.status.should == killedBySegmentationFault;
    "snakebite: internal error: signal 11".should.be in child.output;
}

@("faultsignal.hostDefect.divisionOutsideAGuestRunKeepsItsStatus")
unittest {
    runChild("hostDivision").status.should == killedByArithmeticFault;
}

@("faultsignal.hostDefect.faultOfAnotherThreadKeepsItsStatus")
unittest {
    // The main thread runs guest code, the thread that faults does not.
    runChild("hostFaultOnAnotherThread").status
        .should == killedBySegmentationFault;
}

@("faultsignal.hostDefect.faultAfterTheGuestRunEndsKeepsItsStatus")
unittest {
    runChild("hostFaultAfterGuestRun").status
        .should == killedBySegmentationFault;
}

@("faultsignal.hostDefect.signalThatAProgramSentIsNotAFault")
unittest {
    runChild("sentSignalInGuestRun").status.should == killedBySegmentationFault;
}

@("faultsignal.hostDefect.faultWhileAnotherIsUnwindingKeepsItsStatus")
unittest {
    // The cleanup faults after the throw and before the catch.
    runChild("faultInCleanup").status.should == killedBySegmentationFault;
}

@("faultsignal.hostDefect.faultInAGuestRunDoesNotBlameTheHost")
unittest {
    const child = runChild("faultInCleanup");

    "fault of the guest program: signal 11".should.be in child.output;
    "internal error".should.not.be in child.output;
}

@("faultsignal.hostDefect.signalThatTheProgramIgnoredStaysIgnored")
unittest {
    runChild("sentSignalWhileIgnored").status.should == survivedStatus;
}

@("faultsignal.guestRun.thrownObjectSurvivesCollectionsForAThreadOfTheGuest")
unittest {
    // A thread that druntime does not know: the collector does not scan
    // its thread-local memory.
    runChild("faultOnAThreadOfTheGuestAfterCollections").status
        .should == survivedStatus;
}

@("faultsignal.hostDefect.goesToTheHandlerThatWasThereBefore")
unittest {
    runChild("previousHandler").status.should == previousHandlerStatus;
}

@("faultsignal.install.offSwitchKeepsTheCrash")
unittest {
    const child = runChild("guestFaultWithTheHandlersOff",
        ["SNAKEBITE_NO_FAULT_HANDLER": "1"]);

    child.status.should == killedBySegmentationFault;
}

@("faultsignal.install.guestHandlerReplacesOurs")
unittest {
    runChild("guestHandler").status.should == guestHandlerStatus;
}

@("faultsignal.install.haltStaysASignal")
unittest {
    runChild("halt").status.should == -4;
}


private enum previousHandlerStatus = 43;
private enum survivedStatus = 77;
private enum guestHandlerStatus = 42;

extern(C) private void exitWithPreviousHandlerStatus(int) nothrow @nogc {
    import core.sys.posix.unistd: _exit;

    _exit(previousHandlerStatus);
}

extern(C) private void exitWithGuestHandlerStatus(int) nothrow @nogc {
    import core.sys.posix.unistd: _exit;

    _exit(guestHandlerStatus);
}

// The body of the child process: `main` of the test binary calls it first
// when the variable names a scenario. No scenario returns normally: the
// process is meant to die of the fault it makes, and a normal exit is the
// status that tells the parent test that the fault did not kill it.
public int runFaultChild(in string scenario) {
    import core.sys.posix.signal: raise, sigaction, sigaction_t, SIGILL;
    import core.sys.linux.sys.prctl: PR_SET_DUMPABLE, prctl;
    import core.sys.posix.signal: SIG_IGN;
    import core.sys.posix.unistd: alarm;
    import core.thread: Thread;

    // The processes die on purpose: no core dump for each of them. A
    // limit of zero does not stop a helper that the kernel runs for a
    // piped `core_pattern`, a process that is not dumpable does.
    prctl(PR_SET_DUMPABLE, 0, 0, 0, 0);
    // A scenario that does not end is a failure: it dies of SIGALRM.
    alarm(30);

    sigaction_t previous;
    switch (scenario) {
        case "previousHandler":
            previous.sa_handler = &exitWithPreviousHandlerStatus;
            sigaction(SIGSEGV, &previous, null);
            break;
        case "sentSignalWhileIgnored":
            previous.sa_handler = SIG_IGN;
            sigaction(SIGSEGV, &previous, null);
            break;
        default:
            break;
    }

    installFaultHandlers;

    switch (scenario) {
        case "hostNullRead":
            load(null);
            break;
        case "hostDivision":
            divide(1, int.max - int.max);
            break;
        case "hostFaultOnAnotherThread":
            auto run = GuestRun.begin;
            auto thread = new Thread({ load(null); });
            thread.start;
            thread.join;
            break;
        case "hostFaultAfterGuestRun":
            {
                auto run = GuestRun.begin;
            }
            load(null);
            break;
        case "sentSignalInGuestRun":
            auto run = GuestRun.begin;
            raise(SIGSEGV);
            break;
        case "previousHandler":
            load(null);
            break;
        case "faultInCleanup":
            auto run = GuestRun.begin;
            loadThroughAFrameThatFaultsInCleanup(null);
            break;
        case "sentSignalWhileIgnored":
            auto run = GuestRun.begin;
            raise(SIGSEGV);
            return survivedStatus;
        case "faultOnAThreadOfTheGuestAfterCollections":
            return faultOnAThreadOfTheGuest;
        case "guestFaultWithTheHandlersOff":
            auto run = GuestRun.begin;
            load(null);
            break;
        case "guestHandler":
            auto run = GuestRun.begin;
            sigaction_t own;
            own.sa_handler = &exitWithGuestHandlerStatus;
            sigaction(SIGSEGV, &own, null);
            load(null);
            break;
        case "halt":
            import snakebite.backends.haltprocess: haltProcess;

            auto run = GuestRun.begin;
            haltProcess;
            break;
        default:
            return 99;
    }

    return 0;
}

// A thread that `pthread_create` made, as the guest does, runs guest code
// and faults after the main thread has collected garbage and allocated
// objects of the size of the thrown one.
private final class Filler {
    void*[(__traits(classInstanceSize, HardwareFault) + 7) / 8] words;
}

private shared bool guestThreadReady;
private shared bool guestThreadGo;
private shared bool guestThreadCaught;

extern(C) private void* runGuestThread(void*) {
    import core.atomic: atomicLoad, atomicStore;
    import core.sys.posix.unistd: usleep;

    auto run = GuestRun.begin;
    atomicStore(guestThreadReady, true);
    while (!atomicLoad(guestThreadGo))
        usleep(1000);

    try
        load(null);
    catch (HardwareFault fault) {
        takeFault(fault);
        atomicStore(guestThreadCaught,
            fault.kind == GuestFault.Kind.nullDereference);
    }
    return null;
}

private int faultOnAThreadOfTheGuest() @trusted {
    import core.atomic: atomicLoad, atomicStore;
    import core.memory: GC;
    import core.sys.posix.pthread: pthread_create, pthread_join, pthread_t;
    import core.sys.posix.unistd: usleep;

    pthread_t thread;
    pthread_create(&thread, null, &runGuestThread, null);
    while (!atomicLoad(guestThreadReady))
        usleep(1000);

    foreach (round; 0 .. 200) {
        GC.collect;
        foreach (index; 0 .. 500)
            cast(void) new Filler;
    }
    atomicStore(guestThreadGo, true);
    pthread_join(thread, null);

    return atomicLoad(guestThreadCaught) ? survivedStatus : 98;
}

public enum faultChildVariable = childVariable;
