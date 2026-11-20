module snakebite.backends.bytecode.jit;

// The template JIT of the bytecode VM (docs/adr/0016-template-jit.md).
//
// A hot function gets x86-64 code for each instruction that has a template,
// with the operands as immediates. The address of the code of instruction i
// replaces `instructions[i].handler`. The code obeys the `Instruction.Handler`
// calling convention (see the register map below). It has no stack frame,
// and makes no native call. Scratch registers hold operands; guest calls
// and returns also set the handler arguments. A throw needs no unwind
// information: it happens only in real handlers,
// which the JIT code reaches by a tail jump. An instruction without a
// template gets a stub that sets `pc` and jumps to its handler.
//
// The emitter allocates nothing per instruction (it works in reused buffers),
// because the cost of a compile is paid at run time.

private:

import snakebite.host.threads: Continuation;


// The code generator exists only where the register maps below are known.
public enum jitSupported = jitPlatform && jitCompiler;

version (linux) version (X86_64)
    private enum jitPlatform = true;
private static if (!is(typeof(jitPlatform)))
    private enum jitPlatform = false;

version (LDC)
    private enum jitCompiler = true;
else version (DigitalMars)
    private enum jitCompiler = true;
else
    private enum jitCompiler = false;

static if (jitSupported):

import snakebite.backends.bytecode.jitflow: ScalarFlow;

@nogc nothrow:

// Each guest call or backward branch adds `jitStep` to `Function.jitHeat`.
// A carry out of the 32-bit sum means the function has reached the threshold.
private enum jitThreshold = 256;
package enum jitStep = cast(uint) ((1UL << 32) / jitThreshold);

// What the JIT does for one instruction: the kind of template and its
// parameters. Each kind that has parameters has the member of its own name in
// the union; `width` is a fixed operand width, or 0 when the instruction holds
// it. `emitOp` says what each kind emits.
package struct JitOp {
    import snakebite.backends.bytecode.vm: CheckedAccess, CompareKind,
        Comparison, Destination, IndexBase;

    enum Kind : ubyte {
        none, copy, constant, zero, jump, branch, int3, cmp3, fused, fp3,
        fpcmp3, index, checked, castFixed, sliceToPointer, widen, loadInd, storeInd,
        frameAddr, staticLoad, staticStore, staticAddr, boolOp, unary, shift,
        callWindow, returnValue, returnVoid, arrayEqual, signedDivide,
        temporaryTransition, sliceFill, intToFloat,
    }

    enum IntOperation : ubyte { add, or, and, subtract, xor, multiply }
    enum FloatOperation : ubyte { add, subtract, multiply, divide }
    enum ShiftKind : ubyte { left, logicalRight, arithmeticRight }

    // Whether `value`, of width `w`, is an immediate of an ALU op.
    static bool immediate(int w, ulong value, out int imm) @safe @nogc nothrow pure {
        switch (w) {
        case 1: imm = cast(byte) value; return true;
        case 2: imm = cast(short) value; return true;
        case 4: imm = cast(int) value; return true;
        default:
            if (cast(long) value >= int.min && cast(long) value <= int.max) {
                imm = cast(int) value;
                return true;
            }
            return false;
        }
    }

    // `source` is the address of a constant instead of an operand.
    static struct Copy {
        bool staticSource;
    }

    static struct Branch {
        bool jumpIfNonzero;
    }

    // `leftInR0`: the left operand is in the integer register argument.
    // `resultInR0`: the result goes there. `twoAddress`: the destination is
    // also the left operand.
    static struct Int3 {
        IntOperation operation;
        bool constantRight;
        bool leftInR0;
        bool resultInR0;
        bool twoAddress;
    }

    // The byte result goes to the destination.
    static struct Cmp3 {
        Comparison comparison;
        bool signed;
        bool constantRight;
        bool twoAddress;
    }

    // `jumpWhen`: jump when the answer of the comparison is true.
    static struct Fused {
        Comparison comparison;
        CompareKind kind;
        bool jumpWhen;
        bool constantRight;
        bool leftInR0;
    }

    // `leftInFp0`: the left operand is in the floating register argument.
    // `resultInFp0`: the result goes there.
    static struct Fp3 {
        FloatOperation operation;
        bool constantRight;
        bool leftInFp0;
        bool resultInFp0;
    }

    static struct FpCmp3 {
        Comparison comparison;
        bool constantRight;
    }

    static struct Index {
        IndexBase base;
    }

    // `width` is the element size.
    static struct Checked {
        CheckedAccess access;
        bool fixedLength;
        ubyte indexWidth;
        bool signed;
        bool constantValue;
        bool sharedAccess;
    }

    // `width` is the size of the destination.
    static struct CastFixed {
        bool zeroExtend;
        ubyte sourceSize;
    }

    static struct Widen {
        bool zeroExtend;
    }

    // `nonzero`: the result is whether the operand is not zero.
    static struct BoolOp {
        bool nonzero;
    }

    static struct Unary {
        bool complement;
    }

    static struct Shift {
        ShiftKind kind;
        bool constantRight;
        bool twoAddress;
    }

    static struct CallWindow {
        Destination destination;
        bool counted;
        bool indirect;
    }

    static struct SignedDivide {
        bool remainder;
        bool constantRight;
        bool twoAddress;
        // The general two-address handlers divide sign-extended longs.
        bool widenInt;
    }

    Kind kind;
    ubyte width;
    union {
        Copy copy;
        Branch branch;
        Int3 int3;
        Cmp3 cmp3;
        Fused fused;
        Fp3 fp3;
        FpCmp3 fpcmp3;
        Index index;
        Checked checked;
        CastFixed castFixed;
        Widen widen;
        BoolOp boolOp;
        Unary unary;
        Shift shift;
        CallWindow callWindow;
        SignedDivide signedDivide;
    }

    // A kind that has no parameters.
    static JitOp plain(Kind kind, ubyte width = 0) pure nothrow @nogc @safe {
        JitOp op;
        op.kind = kind;
        op.width = width;
        return op;
    }

    // A kind that has parameters, which are the member named like the kind.
    static JitOp make(Kind kind, Parameters)(Parameters parameters,
        ubyte width = 0) pure nothrow @nogc @trusted
    {
        enum member = __traits(allMembers, Kind)[cast(size_t) kind];
        JitOp op;
        op.kind = kind;
        op.width = width;
        __traits(getMember, op, member) = parameters;
        return op;
    }
}

package struct ObservedEdge {
    package enum limit = 2048;
    package ushort pc;
    // A call enters the first instruction and a return resumes in its caller.
    package enum call = ushort.max;
    package enum return_ = call - 1;
    package ushort next;
}


private enum : ubyte {
    RAX = 0, RCX = 1, RDX = 2, RSI = 6, RDI = 7, R8 = 8, R9 = 9, R10 = 10,
    R11 = 11,
}

// The registers of `Instruction.Handler`, by the compiler that built the VM:
// a build has one compiler, and its handlers use that compiler's convention.
// LDC gives System V order: pc rdi, activation rsi, state rdx, frame rcx,
// r0 r8, fp0 xmm0. DMD's `extern(D)` reverses the integer parameters: pc r8,
// activation rcx, state rdx, frame rsi, r0 rdi, fp0 xmm0. `SC2` is a scratch
// register: the one that holds `pc` on entry, which the code never reads.
// Scratch registers are rax, SC2, r9, r10, r11, xmm1 and xmm2 in both maps.
// `checkCallingConvention` compares this map with the compiler at run time.
version (LDC) {
    private enum FRAME = RCX;
    private enum REG0 = R8;
    private enum SC2 = RDI;
    private enum PCREG = RDI;
    private enum ACTIVE = RSI;
} else {
    private enum FRAME = RSI;
    private enum REG0 = RDI;
    private enum SC2 = R8;
    private enum PCREG = R8;
    private enum ACTIVE = RCX;
}
private enum STATE = RDX;

// Prefixes and opcodes of the SSE instructions, which `Asm.sse` and
// `Asm.sseRR` take. The second byte of the opcode is after `0x0F`.
private enum ubyte noPrefix = 0;
private enum ubyte doublePrefix = 0xF2;
private enum ubyte singlePrefix = 0xF3;
private enum ubyte operandSizePrefix = 0x66;
private enum ubyte loadOpcode = 0x10;
private enum ubyte storeOpcode = 0x11;
private enum ubyte moveAlignedOpcode = 0x28;
private enum ubyte compareOpcode = 0x2E;
// `movsxd`.
private enum uint signExtend32Opcode = 0x63;
// `addsd`, `subsd`, `mulsd` and `divsd` after the prefix, by operation.
private static immutable ubyte[4] _floatOpcodes = [0x58, 0x5C, 0x59, 0x5E];
private enum fp0Register = 0;
private enum XMM1 = 1;
private enum XMM2 = 2;

// The operation field of the ALU instructions.
private enum Alu : ubyte { add = 0, or = 1, and = 4, sub = 5, xor = 6, cmp = 7 }

private struct Mem {
    ubyte base;
    int disp;
    int index = -1;
    ubyte scale = 1;
}

private enum : ubyte {
    CC_B = 2, CC_AE = 3, CC_E = 4, CC_NE = 5, CC_BE = 6, CC_A = 7,
    CC_P = 0xA, CC_NP = 0xB, CC_L = 0xC, CC_GE = 0xD, CC_LE = 0xE, CC_G = 0xF,
}


// What the JIT keeps from one compile to the next. It belongs to the JIT lock
// of its `JitInstance`: only `JitLock.owned` gives access to it.
package struct JitState {
    import snakebite.backends.bytecode.vm:
        CallSite, Destination, Function, Instruction, chainedDispatch;

    @nogc nothrow:

    CodeRegion region;
    // Whether the CPU has the BMI2 shifts (`shlx`, `shrx`, `sarx`); without
    // them the shift instructions keep their handlers.
    bool bmi2;
    // Compiles reuse these buffers.
    Scratch!Fixup fixups;
    Scratch!Literal literals;
    Scratch!size_t labels;
    PerfMap perfMap;
    Scratch!ReloadEntry reloadEntries;
    Scratch!(Gen.BranchOnlyCandidate) branchOnlyCandidates;
    Scratch!(Gen.BranchOnlyEntry) branchOnlyEntries;
    Scratch!(Gen.PathScratch, 1) paths;
    Scratch!(ScalarFlow, 1) scalarFlow;
    Scratch!(ScalarEmitter, 1) scalarEmitter;
    // The buffers of one compile in `vm.d`: the template of each instruction,
    // a snapshot of the instructions, and their handlers.
    Scratch!JitOp opScratch;
    Scratch!Instruction snapshotScratch;
    Scratch!(Instruction.Handler) originalScratch;
    // The bodies that `Gen.emitWindowBody` integrates, one for each depth.
    Scratch!(InlineBody, Gen.inlineDepthLimit) inlineBodies;

    // The JIT lock guards this stack. Compilation uses it from a Fiber.
    Continuation compilerStack;

    // Gives back the memory of the region and the buffers.
    void release() {
        region.release;
        fixups.release;
        labels.release;
        literals.release;
        reloadEntries.release;
        branchOnlyCandidates.release;
        branchOnlyEntries.release;
        paths.release;
        scalarFlow.release;
        scalarEmitter.release;
        opScratch.release;
        snapshotScratch.release;
        originalScratch.release;
        inlineBodies.release;
        compilerStack = null;
    }

    static if (chainedDispatch)
    void linkWindow(bool refresh)(const(Instruction)* pc, const(Function)* caller,
        const(CallSite)* site, size_t index, Destination destination,
    ) {
        import core.atomic: atomicLoad, atomicStore, MemoryOrder;
        import snakebite.backends.bytecode.vm: indirectWindowFallback, JitTier;

        const instructions = caller.instructions;
        if (instructions.length < 2 || pc < instructions.ptr
                || pc >= &instructions[$ - 1])
            return;
        const call = cast(size_t) (pc - instructions.ptr);
        if (&instructions[call] !is pc)
            return;

        auto slot = cast(shared(size_t)*) &site.lateWindowEntry;
        const previous = cast(const(ubyte)*)
            atomicLoad!(MemoryOrder.acq)(*slot);
        const linked = previous is null ? 0 : previous[-1];
        const bit = 1u << index;
        auto target = cast(CallSite.IndirectTarget*) site.indirectTargetAt(index);
        static if (refresh) {
            if (target.coldHit is null)
                return;
        } else if (linked & bit)
            return;

        auto arm = Gen.readIndirectArm(*target);
        if (!Gen.encodableWindowArm(arm))
            return;

        static if (refresh) {
            if (atomicLoad!(MemoryOrder.acq)(
                    *cast(shared const(uint)*) &arm.callee.jitState)
                    != JitTier.compiled)
                return;
            const coldHit = target.coldHit;
            target.coldHit = null;
        }
        enum exits = 3 * Gen.handlerJumpBytes;
        enum reserve = 2 * codeAlignment + Gen.windowArmBytes + exits;
        if (region.chunkCapacity - region.chunkUsed < reserve
                && !region.newChunk(chunkSize))
            return;
        const start = region.chunkUsed + codeAlignment;
        Gen g;
        g.a.buf = region.writeBase + start;
        // Keep room for the continuation, the exits and the final alignment.
        g.codeLimit = region.chunkCapacity - start - exits - codeAlignment;
        g.function_ = caller;
        g.instructions = instructions;
        g.fixupScratch = &fixups;
        g.fixups = fixups.ptr;
        g.fixupCap = fixups.cap;
        g.literalScratch = &literals;
        g.scalarScratch = &scalarFlow;
        g.scalarEmitterScratch = &scalarEmitter;
        g.inlineBodies = inlineBodies.reserve(Gen.inlineDepthLimit);
        g.bmi2 = bmi2;
        const op = JitOp.CallWindow(destination, counted: true, indirect: true);
        static if (refresh) {
            g.refreshBase = region.execBase + start;
            g.watchCalleeCall = target.unprofiledCall;
        }
        const copied = g.emitWindowBody(call, *pc, op, site, arm);
        static if (refresh) {
            if (!copied || !arm.expandedWatchedCall)
                return;
        }
        if (copied)
            g.jumpToLive(pc + 1);
        else if (!g.emitCallWindowArm(pc, *pc, op, site, arm))
            return;
        g.patchHere(arm.mismatch);
        if (previous is null)
            g.jumpToOriginal(pc, indirectWindowFallback!true(destination));
        else {
            g.a.movI(RAX, cast(size_t) previous);
            g.a.jmpRax;
        }
        g.patchHere(arm.grow);
        const refreshOnCarry = refresh || (copied && arm.unprofiledCall != size_t.max);
        if (refreshOnCarry)
            g.jumpToOriginal(pc, indirectWindowFallback!false(destination));
        g.patchHere(arm.tierUp);
        g.jumpToOriginal(pc, refreshOnCarry
            ? indirectWindowFallback!(false, true)(destination)
            : indirectWindowFallback!false(destination));
        g.emitLiterals;

        // The byte before the entry indexes the cache records already linked.
        // No caller can enter the new arm until the release store below.
        g.a.buf[-1] = cast(ubyte) (linked | bit);
        region.chunkUsed = (start + g.a.n + codeAlignment - 1)
            & ~(codeAlignment - 1UL);
        if (region.chunkUsed + populateSize / 4 > region.populatedEnd)
            region.populate;
        const code = region.execBase + start;
        static if (!refresh) {
            if (refreshOnCarry) {
                target.unprofiledCall = arm.unprofiledCall;
                target.coldHit = code + arm.hit;
            }
        }
        if (caller.jitName.length)
            perfMap.record(code, g.a.n, "late-guest-window");
        atomicStore!(MemoryOrder.rel)(*slot, cast(size_t) code);
    }

    Emitted emitFunction(Function* function_,
        const(Instruction)[] snapshot, const(JitOp)[] ops,
        const(Instruction.Handler)[] originals,
        const(ObservedEdge)[] observed, bool expandWindows)
    {
        import core.atomic: atomicStore, MemoryOrder;
        import snakebite.backends.bytecode.vm: jitFallback;

        const instructions = function_.instructions;
        const start = region.chunkUsed;
        const handlerBytes = originals.length * Instruction.Handler.sizeof;
        if (region.chunkCapacity - start < handlerBytes)
            return Emitted.full;
        const cap = region.chunkCapacity - start - handlerBytes;
        Gen g;
        g.function_ = function_;
        g.codeLimit = cap;
        g.expandWindows = expandWindows;
        g.a.buf = region.writeBase + start;
        g.fixupScratch = &fixups;
        g.literalScratch = &literals;
        g.scalarScratch = &scalarFlow;
        g.scalarEmitterScratch = &scalarEmitter;
        g.reloadEntryScratch = &reloadEntries;
        g.inlineBodies = inlineBodies.reserve(Gen.inlineDepthLimit);
        g.bmi2 = bmi2;
        g.instructions = instructions;
        g.snapshot = snapshot;
        g.frameSize = function_.frameSize;
        g.constants = function_.constants;
        g.callSites = function_.callSites;
        auto labelMemory = labels.reserve(instructions.length + 1);
        if (labelMemory is null)
            return Emitted.failed;
        g.labels = labelMemory[0 .. instructions.length + 1];
        g.fixups = fixups.ptr;
        g.fixupCap = fixups.cap;

        const path = g.selectObservedPath(function_, ops, observed, paths);
        size_t pathJump;
        enum needsHandlerEntry = size_t.max;
        size_t handlerEntryCount;
        size_t branchOnlyEnd;
        size_t fpRegionEnd;
        size_t intRegionEnd;
        const branchOnly = g.proveBranchOnly(ops, branchOnlyCandidates, branchOnlyEntries);
        bool inlineReturn;
        const hasChecked = g.hasCheckedAccess(ops);
        const scalarEntry = g.emitScalarEntry(ops, originals, inlineReturn, hasChecked);
        foreach (i; 0 .. instructions.length) {
            if (i < branchOnlyEnd)
                continue;
            const original = jitFallback(function_, snapshot[i], originals[i]);
            if (cap - g.a.n - g.literalBytes < maximumBytesPerInstruction)
                return Emitted.full;
            g.labels[i] = g.a.n;
            if (hasChecked && i && !g.checkedLoop.update && !g.fpLoop.backedge
                    && !g.intLoop.backedge && i >= intRegionEnd && i >= fpRegionEnd
                    && g.emitScalarEntry(ops, originals, inlineReturn, hasChecked, i)) {
                g.known = Gen.KnownConstant.init;
                g.intSlots = IntSlots.init;
                g.fpSlots = FpSlots.init;
            }
            if (path.length != 0 && i == path[0].pc) {
                g.a.b(0xE9);
                pathJump = g.a.n;
                g.a.d32(0);
            }
            if (g.checkedLoop.update && i == g.checkedLoop.update) {
                g.jumpToHandler(i, original);
                g.emitCheckedLoopUpdate;
                continue;
            }
            if (g.checkedLoop.update && i == g.checkedLoop.update + 1) {
                g.emitCheckedLoopBackedge;
                g.labels[i] = needsHandlerEntry;
                ++handlerEntryCount;
                continue;
            }
            if (g.intLoop.backedge && i > g.intLoop.backedge) {
                g.intLoop = IntLoop.init;
                g.intSlots = IntSlots.init;
            }
            if (!g.checkedLoop.update && !g.fpLoop.backedge
                    && !g.intLoop.backedge
                    && (ops[i].kind == JitOp.Kind.fused
                        || ops[i].kind == JitOp.Kind.branch))
                g.intLoop = g.planIntLoop(i, ops, originals);
            if (g.intLoop.contains(i)) {
                if (!g.emitIntLoopInstruction(i, ops, original))
                    return Emitted.failed;
                continue;
            }
            if (!g.checkedLoop.update && !g.fpLoop.backedge
                    && !g.intLoop.backedge
                    && ops[i].kind == JitOp.Kind.branch)
                g.fpLoop = g.planFpLoop(i, ops, originals);
            if (g.fpLoop.backedge) {
                if (i == g.fpLoop.head) {
                    g.fpSlots = g.fpLoop.seed;
                    g.fpSlots.reload(g.a);
                    g.fpLoop.headBody = g.a.n;
                } else if (i == g.fpLoop.compare) {
                    g.fpLoop.joinFixups = g.fixupCount;
                } else if (i == g.fpLoop.join) {
                    // The compare preserves the map expected by its target.
                    foreach (f; g.fixups[g.fpLoop.joinFixups .. g.fixupCount])
                        g.patchHere(f.position);
                    g.fixupCount = g.fpLoop.joinFixups;
                }
            }
            if (!g.fpLoop.backedge && !g.checkedLoop.update && !g.intLoop.backedge
                    && i >= intRegionEnd)
                intRegionEnd = g.emitIntRegion(i, ops, originals);
            const saved = g.a.n;
            const savedFixups = g.fixupCount;
            const savedLiterals = g.literalCount;
            if (branchOnly.length && branchOnly[i].approved
                    && !g.fpLoop.backedge && !g.checkedLoop.update
                    && !g.intLoop.backedge) {
                const plan = g.planBranchOnly(i, ops);
                if (!path.length || path[0].pc <= i
                        || path[0].pc >= plan.end) {
                    branchOnlyEnd = plan.end;
                    foreach (ref label; g.labels[i + 1 .. plan.end])
                        label = needsHandlerEntry;
                    handlerEntryCount += plan.end - i - 1;
                    g.emitBranchOnly(i, plan);
                    handlerEntryCount -= plan.count - 1;
                    if (g.outOfMemory)
                        return Emitted.failed;
                    continue;
                }
            }
            if (i >= fpRegionEnd && ops[i].kind == JitOp.Kind.fp3
                    && !g.fpLoop.backedge && !g.checkedLoop.update
                    && !g.intLoop.backedge)
                fpRegionEnd = g.emitFpRegion(i, ops, originals);
            bool done;
            g.usedKnown = false;
            if (originals[i] !is null && ops[i].kind != JitOp.Kind.none)
                done = g.emitOp(i, ops, original);
            else {
                g.fpSlots = FpSlots.init;
                g.intSlots = IntSlots.init;
            }
            if (g.outOfMemory || (g.fpLoop.backedge && (!done || g.usedKnown)))
                return Emitted.failed;
            if (g.fpLoop.backedge && i == g.fpLoop.backedge) {
                g.fpLoop = FpLoop.init;
                g.fpSlots = FpSlots.init;
            }
            if (!done) {
                g.a.n = saved;
                g.fixupCount = savedFixups;
                g.literalCount = savedLiterals;
                if (originals[i] is null)
                    g.a.ud2();
                else
                    g.jumpToHandler(i, original);
                g.known = Gen.KnownConstant.init;
            } else {
                if (g.usedKnown) {
                    g.labels[i] = needsHandlerEntry;
                    ++handlerEntryCount;
                }
                g.rememberConstant(snapshot[i], ops[i]);
            }
        }
        if (cap - g.a.n - g.literalBytes < codeAlignment)
            return Emitted.full;
        g.labels[instructions.length] = g.a.n;
        g.a.ud2();
        if (handlerEntryCount) {
            foreach (i, ref label; g.labels[0 .. instructions.length]) {
                if (label != needsHandlerEntry)
                    continue;
                if (cap - g.a.n - g.literalBytes < maximumBytesPerInstruction)
                    return Emitted.full;
                // Dispatch and branches can enter here without the values
                // that the preceding machine code supplies.
                label = g.a.n;
                g.jumpToHandler(i,
                    jitFallback(function_, snapshot[i], originals[i]));
                if (--handlerEntryCount == 0)
                    break;
            }
        }
        if (g.literalCount && g.a.n + g.literalBytes > int.max)
            return Emitted.failed;
        g.emitLiterals;

        foreach (ref const entry; reloadEntries.ptr[0 .. g.reloadEntryCount]) {
            if (cap - g.a.n < maximumBytesPerInstruction)
                return Emitted.full;
            const body = g.labels[entry.index];
            g.labels[entry.index] = g.a.n;
            entry.fpSlots.reload(g.a);
            entry.intSlots.reload(g.a);
            g.a.b(0xE9);
            g.a.d32(cast(int) (body - (g.a.n + int.sizeof)));
        }

        if (pathJump != 0) {
            const startOfPath = g.a.n;
            auto pathScratch = paths.ptr;
            const loopPlan = pathScratch.best.repeating ? &pathScratch.best : null;
            const target = (loopPlan !is null && g.emitRecordedLoop(path, ops,
                    originals, *pathScratch, *loopPlan)
                || g.emitObservedPath(cap, function_, path, ops,
                    originals, *pathScratch, loopPlan))
                ? startOfPath : pathJump + int.sizeof;
            if (target != startOfPath)
                g.a.n = startOfPath;
            g.patchTo(pathJump, target);
            if (function_.jitName.length && target == startOfPath)
                perfMap.record(region.execBase + start + startOfPath,
                    g.a.n - startOfPath, "observed-guest-path");
        }

        foreach (f; g.fixups[0 .. g.fixupCount])
            *cast(int*) (g.a.buf + f.position) = cast(int) (
                g.labels[f.target] - (f.position + 4));

        const handlerStart = (g.a.n + codeAlignment - 1)
            & ~(codeAlignment - 1UL);
        if (handlerStart > cap)
            return Emitted.full;
        auto identity = cast(Instruction.Handler*) (g.a.buf + handlerStart);
        identity[0 .. originals.length] = originals[];
        const size = (handlerStart + handlerBytes + codeAlignment - 1)
            & ~(codeAlignment - 1UL);
        if (size > region.chunkCapacity - start)
            return Emitted.full;
        region.chunkUsed = start + size;
        if (region.chunkUsed + populateSize / 4 > region.populatedEnd)
            region.populate;

        const code = region.execBase + start;
        function_.jitHandlers =
            cast(const(Instruction.Handler)*) (code + handlerStart);
        if (function_.jitName.length)
            perfMap.record(code, g.a.n, function_.jitName);
        if (scalarEntry)
            g.labels[0] = 0;
        // One aligned 8-byte store with release order for each word, after
        // the code is complete. A thread that runs the function moves to JIT
        // code at its next dispatch.
        foreach (i, ref instruction; instructions)
            atomicStore!(MemoryOrder.rel)(
                *cast(shared(size_t)*) &instruction.handler,
                cast(size_t) (code + g.labels[i]));
        return Emitted.done;
    }
}

// The JIT state of a runner or an inspection. Its owner releases the code
// region after the last use. Every `Function` that the instance compiles
// points here, so that a tier-up finds the state of its owner.
package struct JitInstance {

    // How far this instance's set-up got. It is read without the lock.
    private shared Setup setup;
    private shared int lockWord;
    private shared JitState state;

    void prepareCompilerStack() @system {
        enum compilerStackBytes = 256 * 1024;
        (cast(JitState*) &state).compilerStack =
            new Continuation(idleCompilerStack, compilerStackBytes);
    }

    private static void delegate() idleCompilerStack() @nogc nothrow {
        return delegate() {};
    }

    @nogc nothrow:

    @disable this(this);

    // Unmaps the code and closes the file. The owner calls it when no guest
    // code of the instance can run again; no function may run JIT code of
    // this instance afterwards, and a later compile fails. No lock: nothing
    // else uses the instance then.
    void release() {
        import core.atomic: atomicStore, MemoryOrder;

        (cast(JitState*) &state).release;
        atomicStore!(MemoryOrder.rel)(setup, Setup.unavailable);
    }
}

private struct PerfMap {
    import core.stdc.stdio: FILE;
    import core.sys.posix.sys.types: dev_t, ino_t, pid_t;

    @nogc nothrow:

    private pid_t _pid;
    private dev_t _device;
    private ino_t _inode;
    private bool _available;

    void record(in ubyte* code, in size_t size, in char[] name) {
        import core.stdc.stdio: fclose, fprintf, fputc, perror;
        import core.sys.posix.unistd: getpid;

        const pid = getpid();
        const first = pid != _pid;
        if (!first && !_available)
            return;
        _pid = pid;
        _available = false;

        // A guest can replace any descriptor between compiles, also after fork.
        auto file = openMap(pid, first); // The writer needs a mutable FILE.
        if (file is null)
            return;
        const written = fprintf(file, "%zx %zx ", cast(size_t) code, size) >= 0
            && writeSymbol(file, name) && fputc('\n', file) >= 0;
        if (!written)
            perror("snakebite: cannot write JIT perf map");
        const closed = fclose(file) == 0;
        if (written && !closed)
            perror("snakebite: cannot write JIT perf map");
        _available = written && closed;
    }

    private FILE* openMap(in pid_t pid, in bool first) {
        import core.stdc.stdio: fprintf, perror, snprintf, stderr;
        import core.sys.posix.fcntl: O_APPEND, O_CLOEXEC, O_CREAT, O_EXCL,
            O_NOFOLLOW, O_NONBLOCK, O_WRONLY, open;
        import core.sys.posix.stdio: fdopen;
        import core.sys.posix.sys.stat: fstat, stat_t, S_IRUSR, S_IWUSR;
        import core.sys.posix.unistd: close;

        char[64] path;
        snprintf(path.ptr, path.length, "/tmp/perf-%d.map", pid);
        const flags = O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK;
        const descriptor = first
            ? open(path.ptr, flags | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            : open(path.ptr, flags);
        if (descriptor < 0) {
            perror(path.ptr);
            return null;
        }

        stat_t info;
        if (fstat(descriptor, &info) != 0) {
            perror(path.ptr);
            close(descriptor);
            return null;
        }
        if (!first && (info.st_dev != _device || info.st_ino != _inode)) {
            fprintf(stderr, "snakebite: JIT perf map changed: %s\n", path.ptr);
            close(descriptor);
            return null;
        }
        _device = info.st_dev;
        _inode = info.st_ino;

        auto file = fdopen(descriptor, "a"); // The writer needs a mutable FILE.
        if (file is null) {
            perror(path.ptr);
            close(descriptor);
        }
        return file;
    }

    private static bool writeSymbol(FILE* file, in char[] name) {
        import core.stdc.stdio: fputs, fwrite;

        size_t start;
        foreach (index, character; name) {
            if (character != '\r' && character != '\n')
                continue;
            const length = index - start;
            const escape = character == '\r' ? "\\r" : "\\n";
            if (fwrite(name.ptr + start, char.sizeof, length, file) != length
                    || fputs(escape.ptr, file) < 0)
                return false;
            start = index + 1;
        }
        const length = name.length - start;
        return fwrite(name.ptr + start, char.sizeof, length, file) == length;
    }
}

// The code region grows by chunks. Each chunk has its own memfd file and is
// mapped twice: `writeBase` is read+write, where the JIT emits, and `execBase`
// is read+execute, where the handlers point. No page changes protection.
// Functions are packed with 16-byte alignment, and a function never spans two
// chunks. Memory is made present (`MADV_POPULATE_*`) a part of a chunk at a
// time.
private struct CodeRegion {
    import core.sys.posix.sys.types: pid_t;

    @nogc nothrow:

    private pid_t _process;
    ubyte* writeBase;
    ubyte* execBase;
    size_t chunkCapacity;
    size_t chunkUsed;
    size_t populatedEnd;
    // Every chunk ever mapped, so that `release` can unmap them.
    Chunk* chunks;
    size_t chunkCount;
    size_t chunkRecordCapacity;

    private struct Chunk {
        ubyte* write;
        ubyte* execute;
        size_t size;
    }

    // The code is gone: no function that points into it may run again.
    void release() {
        import core.stdc.stdlib: free;
        import core.sys.posix.sys.mman: munmap;

        foreach (chunk; chunks[0 .. chunkCount]) {
            if (chunk.write !is null)
                munmap(chunk.write, chunk.size);
            if (chunk.execute !is null)
                munmap(chunk.execute, chunk.size);
        }
        free(chunks);
        chunks = null;
        chunkCount = chunkRecordCapacity = 0;
        writeBase = execBase = null;
        chunkCapacity = chunkUsed = populatedEnd = 0;
    }

    bool prepare() {
        import core.sys.posix.sys.mman: munmap;
        import core.sys.posix.unistd: getpid;

        const process = getpid();
        if (process == _process)
            return chunkCapacity != 0;

        // A fork copies the write views of each shared memfd. Keep the execute
        // views because inherited handlers still use them. The child emits into
        // a new chunk, so it cannot overwrite code in the parent.
        foreach (ref chunk; chunks[0 .. chunkCount]) {
            if (chunk.write !is null) {
                munmap(chunk.write, chunk.size);
                chunk.write = null;
            }
        }
        writeBase = execBase = null;
        chunkCapacity = chunkUsed = populatedEnd = 0;
        _process = process;
        return newChunk(chunkSize);
    }

    // Makes a chunk of at least `bytes` the current one. The old chunks stay
    // mapped: their code is in use.
    bool newChunk(size_t bytes) {
        import core.sys.posix.sys.mman: MAP_FAILED, MAP_SHARED, mmap, munmap,
            PROT_EXEC, PROT_READ, PROT_WRITE;
        import core.sys.posix.unistd: close, ftruncate;

        const file = memfd_create("snakebite-jit", MFD_CLOEXEC);
        if (file < 0)
            return false;
        scope(exit) close(file);
        const size = (bytes + chunkSize - 1) & ~(chunkSize - 1);
        if (ftruncate(file, size) != 0)
            return false;
        // `auto`: `munmap` takes a mutable pointer.
        auto write = mmap(null, size, PROT_READ | PROT_WRITE, MAP_SHARED,
            file, 0);
        auto execute = mmap(null, size, PROT_READ | PROT_EXEC, MAP_SHARED,
            file, 0);
        if (write is MAP_FAILED || execute is MAP_FAILED) {
            if (write !is MAP_FAILED)
                munmap(write, size);
            if (execute !is MAP_FAILED)
                munmap(execute, size);
            return false;
        }
        if (chunkCount == chunkRecordCapacity) {
            import core.stdc.stdlib: realloc;

            const capacity = chunkRecordCapacity ? chunkRecordCapacity * 2 : 8;
            auto grown = cast(Chunk*) realloc(chunks, capacity * Chunk.sizeof);
            if (grown is null) {
                munmap(write, size);
                munmap(execute, size);
                return false;
            }
            chunks = grown;
            chunkRecordCapacity = capacity;
        }
        chunks[chunkCount++] = Chunk(cast(ubyte*) write, cast(ubyte*) execute,
            size);
        writeBase = cast(ubyte*) write;
        execBase = cast(ubyte*) execute;
        chunkCapacity = size;
        chunkUsed = 0;
        populatedEnd = 0;
        populate;
        return true;
    }

    void populate() {
        if (populatedEnd + populateSize > chunkCapacity)
            return;
        madvise(writeBase + populatedEnd, populateSize, MADV_POPULATE_WRITE);
        madvise(execBase + populatedEnd, populateSize, MADV_POPULATE_READ);
        populatedEnd += populateSize;
    }
}

private enum chunkSize = 1UL << 20;
private enum populateSize = 1UL << 17;
private enum codeAlignment = 16;
// The most that the code of one instruction can need. Emission checks this much
// room before each instruction.
private enum maximumBytesPerInstruction = 1152;
// Druntime and Phobos declare none of these: no `memfd_create`, no
// `MFD_CLOEXEC`, no `MADV_POPULATE_*`, and `core.sys.linux.sys.mman` declares
// `madvise` only when `_DEFAULT_SOURCE` is true, which it is not for glibc.
private enum MADV_POPULATE_READ = 22;
private enum MADV_POPULATE_WRITE = 23;
private enum MFD_CLOEXEC = 1;

extern(C) private int madvise(void*, size_t, int) nothrow @nogc;
extern(C) private int memfd_create(const(char)* name, uint flags) nothrow @nogc;

// How far the set-up of an instance got: nothing, a usable JIT, or a JIT that
// this instance cannot have (no memfd).
private enum Setup : int { pending, ready, unavailable }

// The JIT lock. A thread takes it without waiting: a thread that waits for the
// lock can wait for a thread that the GC suspended while it held the lock. The
// lock is released when the `JitLock` that holds it goes out of scope.
package struct JitLock {
    import snakebite.backends.bytecode.vm: Function, Instruction;

    package bool onCompilerStack(Work)(scope Work work) {
        import core.thread.fiber: Fiber;
        import snakebite.failure.report: internalFailure;
        import snakebite.host.threads: fiberOfHostCode;

        if (Fiber.getThis is null) {
            work();
            return true;
        }

        auto compiler = state.compilerStack;
        if (compiler is null)
            return false;
        compiler.of = fiberOfHostCode;
        compiler.reset(work);
        const thrown = compiler.call!(Fiber.Rethrow.no);
        compiler.reset(JitInstance.idleCompilerStack);
        compiler.of = null;
        if (thrown !is null)
            internalFailure("unexpected exception during JIT compilation");
        return true;
    }

    @nogc nothrow:

    private bool _held;
    private JitInstance* _instance;

    @disable this(this);

    package static JitLock tryTake(ref JitInstance instance) {
        import core.atomic: cas;

        JitLock lock;
        lock._held = cas(&instance.lockWord, 0, 1);
        lock._instance = &instance;
        return lock;
    }

    ~this() {
        import core.atomic: atomicStore, MemoryOrder;

        if (_held)
            atomicStore!(MemoryOrder.rel)(_instance.lockWord, 0);
    }

    package bool held() const {
        return _held;
    }

    // `state`, which belongs to the JIT lock, for the thread that holds it.
    package ref T owned(T)(return ref shared T state) {
        import snakebite.failure.report: internalFailure;

        if (!_held)
            internalFailure("JIT state used without the JIT lock");
        return *cast(T*) &state;
    }

    // The state of the instance that holds this lock.
    package ref JitState state() {
        return owned(_instance.state);
    }

    // Gives the function JIT code. Returns false when it could not: the
    // function then keeps its handlers. The caller has seen `jitUsable`.
    //
    // The code goes after the code in the current chunk. If the chunk has too
    // little room left, emission stops (it checks before each instruction)
    // and starts again in a new chunk, whose size no function can exceed. A
    // function does not reserve room for its worst case before it emits.
    package bool jitFunction(Function* function_,
        const(Instruction)[] snapshot, const(JitOp)[] ops,
        const(Instruction.Handler)[] originals,
        const(ObservedEdge)[] observed)
    {
        if (snapshot.length == 0)
            return false;
        ref state = this.state;
        auto result = state.emitFunction(function_, snapshot, ops, originals,
            observed, true);
        if (result == Emitted.full) {
            const worst = snapshot.length
                * (maximumBytesPerInstruction + Instruction.Handler.sizeof)
                + 4096;
            if (!state.region.newChunk(worst))
                return false;
            result = state.emitFunction(function_, snapshot, ops, originals,
                observed, true);
            // The fresh chunk is sized for the original templates. A large
            // expanded body can fit at first and leave too little room later.
            if (result == Emitted.full)
                result = state.emitFunction(function_, snapshot, ops, originals,
                    observed, false);
        }
        return result == Emitted.done;
    }
}

// True when a function can get JIT code. The first call for an instance sets
// its region up. The CPU features and the check of the calling convention have
// one answer for the process, so the first instance that gets here makes them.
package bool jitUsable(ref JitLock lock) {
    import core.atomic: atomicLoad, atomicStore, MemoryOrder;

    ref instance = *lock._instance;
    final switch (atomicLoad!(MemoryOrder.acq)(instance.setup)) {
        case Setup.ready: return lock.state.region.prepare;
        case Setup.unavailable: return false;
        case Setup.pending:
            break;
    }
    ref state = lock.state;
    const ok = state.region.prepare;
    if (ok) {
        // Instances that race here can each run the check before one of them
        // sets the flag. The result is the same, and each run uses a little
        // room in the region of its own instance.
        if (!atomicLoad!(MemoryOrder.acq)(_conventionChecked)) {
            checkCallingConvention(state.region);
            atomicStore!(MemoryOrder.rel)(_conventionChecked, true);
        }
        state.bmi2 = processHasBmi2;
    }
    atomicStore!(MemoryOrder.rel)(instance.setup,
        ok ? Setup.ready : Setup.unavailable);
    return ok;
}

// What the CPU and the host binary give for the whole process.
private shared bool _conventionChecked;
// -1 before the first CPUID read.
private shared int _bmi2 = -1;

private bool processHasBmi2() {
    import core.atomic: atomicLoad, atomicStore, MemoryOrder;

    auto known = atomicLoad!(MemoryOrder.acq)(_bmi2);
    if (known < 0) {
        known = cpuHasBmi2 ? 1 : 0;
        atomicStore!(MemoryOrder.rel)(_bmi2, known);
    }
    return known == 1;
}

// Whether the CPU has the BMI2 shifts (`shlx`, `shrx`, `sarx`); without them
// the shift instructions keep their handlers. Druntime's `core.cpuid` has no
// public accessor for BMI2, so this reads CPUID leaf 7 itself.
private bool cpuHasBmi2() {
    uint maximumLeaf;
    asm pure nothrow @nogc {
        mov EAX, 0;
        cpuid;
        mov maximumLeaf, EAX;
    }
    enum structuredExtendedFeatures = 7;
    if (maximumLeaf < structuredExtendedFeatures)
        return false;
    uint features;
    asm pure nothrow @nogc {
        mov EAX, 7;
        mov ECX, 0;
        cpuid;
        mov features, EBX;
    }
    enum bmi2Bit = 1U << 8;
    return (features & bmi2Bit) != 0;
}


// Calls a stub with known argument values and compares what it finds in the
// registers with the map above. The map was read from the disassembly of a
// handler of each compiler; this fails loudly if a compiler version changes
// its convention, instead of running code that reads the wrong registers.
private void checkCallingConvention(ref CodeRegion region) {
    import snakebite.backends.bytecode.vm: Instruction;
    import snakebite.failure.report: internalFailure;
    import std.traits: FunctionAttribute, functionAttributes, functionLinkage,
        Parameters, SetFunctionAttributes;

    alias Arguments = Parameters!(Instruction.Handler);
    enum ulong pcValue = 0x1111_1111_1111_1111;
    enum ulong activeValue = 0x2222_2222_2222_2222;
    enum ulong stateValue = 0x3333_3333_3333_3333;
    enum ulong r0Value = 0x5555_5555_5555_5555;
    enum double fp0Value = 7.25;

    ulong[5] seen;
    Asm a;
    a.buf = region.writeBase;
    a.st(8, Mem(FRAME, 0), PCREG);
    a.st(8, Mem(FRAME, 8), ACTIVE);
    a.st(8, Mem(FRAME, 16), STATE);
    a.st(8, Mem(FRAME, 24), REG0);
    a.sse(doublePrefix, storeOpcode, fp0Register, Mem(FRAME, 32));
    a.aluRR(Alu.xor, 4, RAX, RAX);
    a.b(0xC3);

    alias NoGcHandler = SetFunctionAttributes!(Instruction.Handler,
        functionLinkage!(Instruction.Handler),
        functionAttributes!(Instruction.Handler) | FunctionAttribute.nogc
            | FunctionAttribute.nothrow_);
    const stub = cast(NoGcHandler) region.execBase;
    stub(cast(Arguments[0]) pcValue, cast(Arguments[1]) activeValue,
        cast(Arguments[2]) stateValue, cast(Arguments[3]) seen.ptr,
        r0Value, fp0Value);
    const matches = seen[0] == pcValue && seen[1] == activeValue
        && seen[2] == stateValue && seen[3] == r0Value
        && *cast(double*) &seen[4] == fp0Value;
    if (!matches)
        internalFailure("the registers of the JIT map do not match the "
            ~ "calling convention of this compiler");
}

// A growable buffer that compiles reuse; `release` frees it.
package struct Scratch(T, size_t initialCapacity = 1024) {
    T* ptr;
    size_t cap;

    // At least `n` elements; the contents are undefined. Null if no memory.
    T* reserve(size_t n) {
        import core.stdc.stdlib: free, malloc;

        if (n > cap) {
            auto newCap = cap ? cap : initialCapacity;
            while (newCap < n)
                newCap *= 2;
            free(ptr);
            ptr = cast(T*) malloc(newCap * T.sizeof);
            cap = ptr is null ? 0 : newCap;
        }
        return ptr;
    }

    void release() {
        import core.stdc.stdlib: free;

        free(ptr);
        ptr = null;
        cap = 0;
    }

    // Keeps the contents. Null if no memory.
    T* grow(size_t n) {
        import core.stdc.stdlib: realloc;

        if (n > cap) {
            auto newCap = cap ? cap : 256;
            while (newCap < n)
                newCap *= 2;
            // `auto`: `ptr` takes it, and it must be mutable.
            auto grown = cast(T*) realloc(ptr, newCap * T.sizeof);
            if (grown is null)
                return null;
            ptr = grown;
            cap = newCap;
        }
        return ptr;
    }
}

private static immutable int[4] _chunkSizes = [8, 4, 2, 1];

private struct Fixup {
    size_t position;
    size_t target;
}

private struct Literal {
    size_t displacement;
    ulong bits;
}

private struct Asm {
    @nogc nothrow:

    ubyte* buf;
    size_t n;

    void b(ubyte x) { buf[n++] = x; }
    void d32(int x) { *cast(int*) (buf + n) = x; n += 4; }
    void q64(ulong x) { *cast(ulong*) (buf + n) = x; n += 8; }

    // Prefix, REX, then `opc` (one byte, or `0x0F` and one byte as 0x0Fxx), then
    // ModRM for `m`.
    void memOp(int w, bool byteReg, int reg, in Mem m, uint opc,
        ubyte prefix = 0, bool forceW = false)
    {
        if (prefix)
            b(prefix);
        if (w == 2)
            b(0x66);
        ubyte rex = 0x40;
        if (w == 8 || forceW)
            rex |= 8;
        if (reg >= 8)
            rex |= 4;
        if (m.index >= 8)
            rex |= 2;
        if (m.base >= 8)
            rex |= 1;
        if (rex != 0x40 || (byteReg && reg >= 4))
            b(rex);
        if (opc > 0xFF)
            b(cast(ubyte) (opc >> 8));
        b(cast(ubyte) opc);
        modrm(reg & 7, m);
    }

    void modrm(int reg, in Mem m) {
        const hasIndex = m.index >= 0;
        const small = m.disp >= -128 && m.disp <= 127;
        b(cast(ubyte) (((small ? 1 : 2) << 6) | (reg << 3)
            | (hasIndex ? 4 : (m.base & 7))));
        if (hasIndex) {
            ubyte s;
            switch (m.scale) {
                case 2: s = 1; break;
                case 4: s = 2; break;
                case 8: s = 3; break;
                default: s = 0;
            }
            b(cast(ubyte) ((s << 6) | ((m.index & 7) << 3) | (m.base & 7)));
        }
        if (small)
            b(cast(ubyte) m.disp);
        else
            d32(m.disp);
    }

    // reg, reg. `reg` is the ModRM reg field, `rm` the r/m field.
    void rrOp(int w, bool byteReg, int reg, int rm, uint opc,
        bool forceW = false)
    {
        if (w == 2)
            b(0x66);
        ubyte rex = 0x40;
        if (w == 8 || forceW)
            rex |= 8;
        if (reg >= 8)
            rex |= 4;
        if (rm >= 8)
            rex |= 1;
        if (rex != 0x40 || (byteReg && (reg >= 4 || rm >= 4)))
            b(rex);
        if (opc > 0xFF)
            b(cast(ubyte) (opc >> 8));
        b(cast(ubyte) opc);
        b(cast(ubyte) (0xC0 | ((reg & 7) << 3) | (rm & 7)));
    }

    // Loads and stores of width `w` with no extension.
    void ld(int w, int r, in Mem m) {
        memOp(w, w == 1, r, m, w == 1 ? 0x8A : 0x8B);
    }

    void st(int w, in Mem m, int r) {
        memOp(w, w == 1, r, m, w == 1 ? 0x88 : 0x89);
    }

    // Zero and sign extension to 64 bits.
    void ldzx(int w, int r, in Mem m) {
        switch (w) {
            case 1: memOp(4, byteReg: false, r, m, (0x0F << 8 | 0xB6)); break;
            case 2: memOp(4, byteReg: false, r, m, (0x0F << 8 | 0xB7)); break;
            case 4: memOp(4, byteReg: false, r, m, 0x8B); break;
            default: memOp(8, byteReg: false, r, m, 0x8B);
        }
    }

    void ldsx(int w, int r, in Mem m) {
        switch (w) {
            case 1: memOp(8, byteReg: false, r, m, (0x0F << 8 | 0xBE)); break;
            case 2: memOp(8, byteReg: false, r, m, (0x0F << 8 | 0xBF)); break;
            case 4: memOp(8, byteReg: false, r, m, signExtend32Opcode); break;
            default: memOp(8, byteReg: false, r, m, 0x8B);
        }
    }

    // ALU op reg, mem.
    void alu(Alu op, int w, int r, in Mem m) {
        memOp(w, w == 1, r, m, (op * 8 + (w == 1 ? 2 : 3)));
    }

    // ALU op mem, imm.
    void aluMI(Alu op, int w, in Mem m, int imm) {
        if (w == 1) {
            memOp(w, byteReg: false, op, m, 0x80);
            b(cast(ubyte) imm);
        } else if (imm >= -128 && imm <= 127) {
            memOp(w, byteReg: false, op, m, 0x83);
            b(cast(ubyte) imm);
        } else {
            memOp(w, byteReg: false, op, m, 0x81);
            if (w == 2) { b(cast(ubyte) imm); b(cast(ubyte) (imm >> 8)); }
            else d32(imm);
        }
    }

    // ALU op reg, reg (reg is the destination).
    void aluRR(Alu op, int w, int dst, int src) {
        rrOp(w, w == 1, src, dst, (op * 8 + (w == 1 ? 0 : 1)));
    }

    void aluRI(Alu op, int w, int r, int imm) {
        if (w == 2)
            b(0x66);
        ubyte rex = 0x40;
        if (w == 8)
            rex |= 8;
        if (r >= 8)
            rex |= 1;
        if (rex != 0x40 || (w == 1 && r >= 4))
            b(rex);
        if (w == 1) {
            b(0x80);
            b(cast(ubyte) (0xC0 | (op << 3) | (r & 7)));
            b(cast(ubyte) imm);
        } else if (imm >= -128 && imm <= 127) {
            b(0x83);
            b(cast(ubyte) (0xC0 | (op << 3) | (r & 7)));
            b(cast(ubyte) imm);
        } else {
            b(0x81);
            b(cast(ubyte) (0xC0 | (op << 3) | (r & 7)));
            if (w == 2) { b(cast(ubyte) imm); b(cast(ubyte) (imm >> 8)); }
            else d32(imm);
        }
    }

    // imul reg, mem and imul reg, reg (width 4 or 8).
    void imulM(int w, int r, in Mem m) {
        memOp(w, byteReg: false, r, m, (0x0F << 8 | 0xAF));
    }

    void imulRR(int w, int dst, int src) {
        rrOp(w, byteReg: false, dst, src, (0x0F << 8 | 0xAF));
    }

    void imulRI(int dst, int src, int imm) {
        rrOp(8, byteReg: false, dst, src, 0x69);
        d32(imm);
    }

    // cdq or cqo prepares the implicit high half of the dividend.
    void extendDividend(int w) {
        if (w == 8)
            b(0x48);
        b(0x99);
    }

    void idivM(int w, in Mem m) {
        memOp(w, byteReg: false, 7, m, 0xF7);
    }

    void idivR(int w, int r) {
        rrOp(w, byteReg: false, 7, r, 0xF7);
    }

    void shiftRightI(int w, bool arithmetic, int r, ubyte count) {
        rrOp(w, byteReg: false, arithmetic ? 7 : 5, r,
            count == 1 ? 0xD1 : 0xC1);
        if (count != 1)
            b(count);
    }

    void shiftImmediate(JitOp.ShiftKind kind, int w, int reg, ubyte count) {
        if (!count)
            return;
        ubyte group;
        final switch (kind) with (JitOp.ShiftKind) {
        case left: group = 4; break;
        case logicalRight: group = 5; break;
        case arithmeticRight: group = 7; break;
        }
        const byteReg = w == 1;
        const opcode = count == 1 ? 0xD1 : 0xC1;
        rrOp(w, byteReg, group, reg, opcode - byteReg);
        if (count != 1)
            b(count);
    }

    // BMI2 uses the 32- or 64-bit count mask of the integer shift handlers.
    void shiftVariable(JitOp.ShiftKind kind, int w, int dest, int src, int count) {
        ubyte prefix;
        final switch (kind) with (JitOp.ShiftKind) {
        case left: prefix = 1; break;
        case logicalRight: prefix = 3; break;
        case arithmeticRight: prefix = 2; break;
        }
        b(0xC4);
        b(cast(ubyte) (0x42 | (dest < 8 ? 0x80 : 0) | (src < 8 ? 0x20 : 0)));
        b(cast(ubyte) ((w == 8 ? 0x80 : 0) | ((~count & 15) << 3) | prefix));
        b(0xF7);
        b(cast(ubyte) (0xC0 | ((dest & 7) << 3) | (src & 7)));
    }

    void movRR64(int dst, int src) {
        rrOp(8, byteReg: false, src, dst, 0x89);
    }

    void movzxRR(int w, int dst, int src) {
        switch (w) {
            case 1: rrOp(4, byteReg: true, dst, src, (0x0F << 8 | 0xB6)); break;
            case 2:
                rrOp(4, byteReg: false, dst, src, (0x0F << 8 | 0xB7));
                break;
            default: rrOp(4, byteReg: false, src, dst, 0x89);
        }
    }

    void movsxRR(int w, int r) {
        switch (w) {
            case 1: rrOp(8, byteReg: true, r, r, (0x0F << 8 | 0xBE)); break;
            case 2: rrOp(8, byteReg: false, r, r, (0x0F << 8 | 0xBF)); break;
            case 4: rrOp(8, byteReg: false, r, r, signExtend32Opcode); break;
            default: break;
        }
    }

    // mov store immediate.
    void stI(int w, in Mem m, int imm) {
        if (w == 1) {
            memOp(w, byteReg: false, 0, m, 0xC6);
            b(cast(ubyte) imm);
        } else {
            memOp(w, byteReg: false, 0, m, 0xC7);
            if (w == 2) { b(cast(ubyte) imm); b(cast(ubyte) (imm >> 8)); }
            else d32(imm);
        }
    }

    void movI(int r, ulong v) {
        if (v <= uint.max) {
            if (r >= 8)
                b(0x41);
            b(cast(ubyte) (0xB8 + (r & 7)));
            d32(cast(int) v);
        } else if (cast(long) v >= int.min && cast(long) v <= int.max) {
            b(cast(ubyte) (0x48 | (r >= 8 ? 1 : 0)));
            b(0xC7);
            b(cast(ubyte) (0xC0 | (r & 7)));
            d32(cast(int) v);
        } else {
            b(cast(ubyte) (0x48 | (r >= 8 ? 1 : 0)));
            b(cast(ubyte) (0xB8 + (r & 7)));
            q64(v);
        }
    }

    void lea(int r, in Mem m) {
        memOp(8, byteReg: false, r, m, 0x8D);
    }

    void negNot(bool neg, int w, in Mem m) {
        memOp(w, byteReg: false, neg ? 3 : 2, m,
            w == 1 ? 0xF6 : 0xF7);
    }

    void setcc(int cc, in Mem m) {
        memOp(1, byteReg: false, 0, m, (0x0F << 8 | (0x90 + cc)));
    }

    void setccR(int cc, int r) {
        rrOp(1, byteReg: true, 0, r, (0x0F << 8 | (0x90 + cc)));
    }

    // SSE. `prefix` 0xF2 (sd), 0xF3 (ss), 0x66, or 0.
    void sse(ubyte prefix, ubyte op, int x, in Mem m) {
        memOp(4, byteReg: false, x, m, (0x0F << 8 | op), prefix);
    }

    // ModRM mode 00 and r/m 101 address data relative to the next instruction.
    void sseRip(ubyte prefix, ubyte op, int x) {
        if (prefix)
            b(prefix);
        if (x >= 8)
            b(0x44);
        b(0x0F);
        b(op);
        b(cast(ubyte) (((x & 7) << 3) | 5));
        d32(0);
    }

    void integerToXmm(int xmm, int integer) {
        b(operandSizePrefix);
        rrOp(8, byteReg: false, xmm, integer, 0x0F6E);
    }

    void xmmToInteger(int integer, int xmm) {
        b(operandSizePrefix);
        rrOp(8, byteReg: false, xmm, integer, 0x0F7E);
    }

    void sseRR(ubyte prefix, ubyte op, int dst, int src) {
        if (prefix)
            b(prefix);
        ubyte rex = 0x40;
        if (dst >= 8) rex |= 4;
        if (src >= 8) rex |= 1;
        if (rex != 0x40)
            b(rex);
        b(0x0F);
        b(op);
        b(cast(ubyte) (0xC0 | ((dst & 7) << 3) | (src & 7)));
    }

    private enum ubyte[2] _ud2Encoding = [0x0F, 0x0B];
    enum ud2Size = _ud2Encoding.length;

    void ud2() {
        static foreach (index; 0 .. ud2Size)
            b(_ud2Encoding[index]);
    }

    // `jmp rax`.
    void jmpRax() { b(0xFF); b(0xE0); }

    void jmpM(in Mem target) { memOp(4, byteReg: false, 4, target, 0xFF); }

    void repStosb() { b(0xF3); b(0xAA); }
}

private alias FpSlots = ScalarFpSlots!(3, 4);

private struct ScalarFpSlots(int first, int capacity) {
    @nogc nothrow:

    // XMM3 through XMM6 are caller-saved in both handler conventions.
    enum firstRegister = first;
    enum count = capacity;

    static struct Slot {
        int offset = -1;
        int width;
    }

    Slot[count] slots;
    size_t next;

    int find(in Mem mem, int width) const pure @safe {
        if (mem.base == FRAME)
            foreach (i, ref const slot; slots)
                if (slot.offset == mem.disp && slot.width == width)
                    return firstRegister + cast(int) i;
        return -1;
    }

    int assign(in Mem dest, int width, int left, int right) pure @safe {
        // SSE overwrites its left operand. If the right operand is distinct,
        // keep its register until the arithmetic instruction has read it.
        const avoid = right == left ? -1 : right;
        int reg = find(dest, width);
        if (reg < 0 || reg == avoid) {
            do {
                reg = firstRegister + cast(int) next;
                next = (next + 1) % count;
            } while (reg == avoid);
        }
        foreach (ref slot; slots)
            if (slot.offset < dest.disp + width
                    && dest.disp < slot.offset + slot.width)
                slot = Slot.init;
        slots[reg - firstRegister] = Slot(dest.disp, width);
        return reg;
    }

    bool empty() const pure @safe {
        foreach (ref const slot; slots)
            if (slot.offset >= 0)
                return false;
        return true;
    }

    bool bounds(out long first, out long end) const pure @safe {
        import std.algorithm.comparison: max, min;

        first = int.max;
        foreach (ref const slot; slots)
            if (slot.offset >= 0) {
                first = min(first, slot.offset);
                end = max(end, cast(long) slot.offset + slot.width);
            }
        return end != 0;
    }

    void reload(ref Asm a) const {
        foreach (i, ref const slot; slots)
            if (slot.offset >= 0)
                a.sse(slot.width == 8 ? doublePrefix : singlePrefix, loadOpcode,
                    firstRegister + cast(int) i, Mem(FRAME, slot.offset));
    }
}

private struct IntSlot {
    int offset;
    int width;
    int reg;
}

private struct IntSlots {
    @nogc nothrow:

    IntSlot newest;
    IntSlot older;
    ubyte base = FRAME;

    int find(in Mem m, int width) const pure @safe {
        if (m.base != base)
            return -1;
        if (newest.width == width && newest.offset == m.disp)
            return newest.reg;
        if (older.width == width && older.offset == m.disp)
            return older.reg;
        return -1;
    }

    int copyRegister() const pure @safe {
        const lastReg = newest.width ? newest.reg : older.reg;
        return lastReg == R11 ? SC2 : R11;
    }

    void forget(in Mem dest, int width, int overwrittenReg = -1) pure @safe {
        if (dest.base != base) {
            newest = older = IntSlot.init;
            return;
        }
        if (overwritten(newest, dest.disp, width, overwrittenReg))
            newest = IntSlot.init;
        if (overwritten(older, dest.disp, width, overwrittenReg))
            older = IntSlot.init;
    }

    static bool overwritten(in IntSlot slot, int offset, int width,
        int reg) pure @safe
    {
        return slot.width && (slot.reg == reg
            || (slot.offset < offset + width && offset < slot.offset + slot.width));
    }

    void rememberCopy(in Mem dest, int width, int reg) pure @safe {
        forget(dest, width, reg);
        if (newest.width)
            older = newest;
        newest = IntSlot(dest.disp, width, reg);
    }

    bool empty() const pure @safe {
        return !newest.width && !older.width;
    }

    bool overlaps(in Mem dest, int width) const pure @safe {
        return overwritten(newest, dest.disp, width, -1)
            || overwritten(older, dest.disp, width, -1);
    }

    void reload(ref Asm a) const {
        if (newest.width)
            a.ld(newest.width, newest.reg, Mem(FRAME, newest.offset));
        if (older.width)
            a.ld(older.width, older.reg, Mem(FRAME, older.offset));
    }
}

private struct IntLoop {
    enum limit = 64;

    size_t head;
    size_t backedge;
    ulong path;
    IntSlots seed;
    size_t headBody;
    size_t afterHeader;
    size_t forwardFixup;

    bool contains(size_t index) const pure @safe @nogc nothrow {
        return backedge && index >= head && index <= backedge
            && (path & (1UL << (index - head))) != 0;
    }
}

private struct ReloadEntry {
    size_t index;
    FpSlots fpSlots;
    IntSlots intSlots;
}

private struct CheckedEntry {
    size_t index;
    size_t afterLoad;
}

private struct CheckedLoop {
    size_t update;
    int indexSlot;
    int stepSlot;
    int limitSlot;
    int protectedStart;
    int protectedEnd;
    size_t body;
    size_t updateFixup;
}

private struct ReceiverRange {
    Mem slot;
    int first = int.max;
    int end;

    void include(int offset, int width) pure @safe @nogc nothrow {
        import std.algorithm.comparison: min, max;
        first = min(first, offset);
        end = max(end, offset + width);
    }
}

private struct IntRegion {
    enum limit = 32;
    enum width = int.sizeof;
    enum pointer = R9;

    static struct Step {
        size_t pc;
        size_t target = size_t.max;
        size_t next;
        Mem dest;
        Mem left;
        Mem right;
        bool literal;
        int result = -1;
        int leftReg = -1;
        int rightReg = -1;
        int pointerLoads;
    }

    Step[limit] steps;
    size_t length;
    ReceiverRange writes;
}

private struct FpRegion {
    enum instructionLimit = 64;
    enum ubyte[3] pointerRegisters = [R9, R10, R11];
    enum int width = double.sizeof;

    enum Kind : ubyte { arithmetic, copy, squareRoot }

    static struct Step {
        Kind kind;
        JitOp.Fp3 fp;
        Mem destination;
        Mem left;
        size_t literalAddress;
        Mem right;
    }

    static struct Ranges {
        ReceiverRange[pointerRegisters.length] entries;
        size_t count;
    }

    Step[instructionLimit] steps;
    size_t length;
    Ranges ranges;
}

private struct FpLoop {
    size_t head;
    size_t compare;
    size_t join;
    size_t backedge;
    FpSlots seed;
    size_t headBody;
    size_t joinFixups;
}

// The state of one level of `Gen.emitWindowBody`. A body is complete before
// the next one at its depth starts.
private struct InlineBody {
    import snakebite.backends.bytecode.vm: Instruction;

    Gen gen;
    Instruction[Gen.inlineInstructionLimit] instructions;
    JitOp[Gen.inlineInstructionLimit] ops;
    Instruction.Handler[Gen.inlineInstructionLimit] originals;
    size_t[Gen.inlineInstructionLimit + 1] labels;
}


private struct ScalarEmitter {
    import snakebite.backends.bytecode.vm: CallSite, CompareKind, Comparison, DispatchState,
        Instruction;
    import snakebite.native.value: shiftCount;
    import snakebite.stack.frames: FrameStack;

    @nogc nothrow:

    alias Flow = ScalarFlow;
    alias Plan = Flow.Program;
    alias Kind = Plan.Kind;
    alias Lane = Flow.Lane;
    alias Value = Flow.Value;
    alias Block = Flow.Block;
    alias Node = Flow.Node;
    alias Origin = Flow.Origin;
    enum none = Flow.none;
    private static immutable ubyte[Flow.gpCount] _gp = [RAX, R9, R10, R11, SC2, ACTIVE, REG0];

    private enum LocationKind : ubyte { none, integer, floating, frame, literal, address, memory }

    private static struct Location {
        LocationKind kind;
        ulong bits;
        ubyte width;
    }

    private static struct Move {
        Location from;
        Location to;
    }

    private static struct Branch {
        size_t[2] patches;
        ubyte count;
        ushort block;
        ushort target;
    }

    Gen* gen;
    Flow* flow;
    const(Instruction.Handler)[] originals;
    ushort recordedEntry = none;
    size_t[Plan.instructionLimit] offsets;
    Branch[Plan.instructionLimit * 2] branches;
    size_t branchCount;
    size_t[Plan.slotLimit * 7 + 1] misses;
    size_t missCount;
    Move[Plan.slotLimit] moveScratch;
    ushort[Plan.instructionLimit] redirects;
    ushort[Plan.instructionLimit] order;
    ushort freeGp;
    ushort freeFp;
    bool inlineReturn;
    bool failed;

    ref Asm a() { return gen.a; }

    bool emit() {
        guards;
        entry;
        const count = layout;
        foreach (position, i; order[0 .. count]) {
            if (!space(Gen.handlerJumpBytes + 128))
                return false;
            ref const block = flow.blocks[i];
            offsets[i] = a.n;
            foreach (ref const node; flow.nodes[block.firstNode .. block.endNode]) {
                if (node.used && !emitNode(node))
                    return false;
            }
            const following = position + 1 == count ? none : order[position + 1];
            if (!finish(block, i, following))
                return false;
        }

        foreach (ref const branch; branches[0 .. branchCount]) {
            ref const target = flow.blocks[branch.target];
            const offset = offsets[redirects[branch.target]];
            if (branch.block != none && movesNeeded(flow.blocks[branch.block], target)) {
                foreach (patch; branch.patches[0 .. branch.count])
                    gen.patchHere(patch);
                edge(flow.blocks[branch.block], target);
                if (!space(8))
                    return false;
                gen.jmpLocalTo(offset);
            } else {
                foreach (patch; branch.patches[0 .. branch.count])
                    gen.patchTo(patch, offset);
            }
        }
        foreach (miss; misses[0 .. missCount])
            gen.patchHere(miss);
        return !failed;
    }

    private ushort layout() {
        foreach (id; 0 .. flow.blockCount) {
            auto target = cast(ushort) id;
            foreach (step; 0 .. flow.blockCount) {
                const next = emptySuccessor(target);
                if (next == none)
                    break;
                target = next;
                if (step + 1 == flow.blockCount)
                    target = cast(ushort) id;
            }
            redirects[id] = target;
        }
        enum scale = 100;
        enum likely = 90;
        enum unlikely = scale - likely;

        struct Edge {
            ushort from;
            ushort to;
            uint probability;
            ulong weight;
        }

        Edge[Plan.instructionLimit * 2] edges;
        size_t edgeCount;
        foreach (id, ref const block; flow.blocks[0 .. flow.blockCount]) {
            if (redirects[id] != id)
                continue;
            const conditional = block.next != none && block.target != none;
            const pc = flow.terminalPc(block);
            const step = flow.ranges.resolved[pc];
            uint taken = scale;
            if (conditional) {
                taken = scale / 2;
                if (block.loopExit != none)
                    taken = block.loopExit == block.target ? unlikely : likely;
                else if (step.target <= pc)
                    taken = likely;
                else if (step.comparison == Comparison.equal
                        || step.comparison == Comparison.notEqual)
                    taken = (step.comparison == Comparison.notEqual) == step.jumpWhen
                        ? likely : unlikely;
            }
            if (block.target != none)
                edges[edgeCount++] = Edge(cast(ushort) id, redirects[block.target], taken);
            if (block.next != none)
                edges[edgeCount++] = Edge(cast(ushort) id, redirects[block.next],
                    conditional ? scale - taken : scale);
        }

        uint[Plan.instructionLimit] arrivals, pending, total;
        // Propagate the static probabilities through the graph. A bounded
        // number of visits also handles loops with no estimated exit.
        enum initialWeight = 1 << 16;
        arrivals[redirects[0]] = initialWeight;
        foreach (visit; 0 .. 64) {
            foreach (id; 0 .. flow.blockCount)
                total[id] += arrivals[id];
            pending[] = 0;
            foreach (ref const edge; edges[0 .. edgeCount])
                pending[edge.to] += arrivals[edge.from] * edge.probability / scale;
            arrivals[] = pending[];
        }
        foreach (ref edge; edges[0 .. edgeCount])
            edge.weight = cast(ulong) total[edge.from] * edge.probability;

        ushort[Plan.instructionLimit] next, prev;
        next[] = prev[] = none;
        foreach (pass; 0 .. edgeCount) {
            size_t best = edgeCount;
            foreach (i, ref const edge; edges[0 .. edgeCount])
                if (edge.weight && (best == edgeCount || edge.weight > edges[best].weight))
                    best = i;
            if (best == edgeCount)
                break;
            ref edge = edges[best];
            edge.weight = 0;
            const from = edge.from;
            const to = edge.to;
            if (from == to || next[from] != none || prev[to] != none || to == redirects[0])
                continue;
            ushort head = from;
            while (prev[head] != none)
                head = prev[head];
            if (head == to) {
                // This edge closes a trace. Keep the conditional as its
                // last instruction so the loop needs no extra jump.
                ushort tail = from;
                while (tail != none && (flow.blocks[tail].next == none
                        || flow.blocks[tail].target == none))
                    tail = prev[tail];
                if (tail == none || tail == from)
                    continue;
                prev[next[tail]] = none;
                next[tail] = none;
            }
            next[from] = to;
            prev[to] = from;
        }

        ushort count;
        for (auto head = redirects[0]; head != none;) {
            for (auto id = head; id != none; id = next[id]) {
                order[count++] = id;
                total[id] = 0;
            }
            head = none;
            foreach (id, freq; total[0 .. flow.blockCount])
                if (redirects[id] == id && prev[id] == none && freq
                        && (head == none || freq > total[head]))
                    head = cast(ushort) id;
        }

        // Integer rounding can leave a rare reachable trace with no weight.
        Flow.Set placed;
        foreach (id; order[0 .. count])
            placed.add(id);
        foreach (id; 0 .. flow.blockCount)
            if (redirects[id] == id && !placed.has(id))
                order[count++] = cast(ushort) id;
        return count;
    }

    private ushort emptySuccessor(ushort id) {
        ref const block = flow.blocks[id];
        const next = block.next == none ? block.target : block.next;
        if (next == none || block.next != none && block.target != none
                || movesNeeded(block, flow.blocks[next]))
            return none;
        foreach (ref const node; flow.nodes[block.firstNode .. block.endNode])
            if (node.used)
                return none;
        return next;
    }

    private bool space(size_t bytes) {
        const used = a.n + gen.literalBytes;
        if (used <= gen.codeLimit && bytes <= gen.codeLimit - used)
            return true;
        failed = true;
        return false;
    }

    private void guard(int cc) {
        misses[missCount++] = gen.jccLocal(cc);
    }

    private void guards() {
        if (flow.ranges.hasFloats && space(32)) {
            enum masks = 0x1F80;
            const environment = Mem(STATE, DispatchState.jitFloatEnvironment.offsetof);
            a.memOp(4, false, 3, environment, 0x0FAE); // STMXCSR
            a.ld(4, RAX, environment);
            a.aluRI(Alu.and, 4, RAX, masks);
            a.aluRI(Alu.cmp, 4, RAX, masks);
            guard(CC_NE);
        }
        const frameSize = flow.ranges.program.frameSize;
        foreach (i, ref const slice; flow.ranges.slices[0 .. flow.ranges.program.slotCount]) {
            if (!slice.required)
                continue;
            if (!space(96))
                return;
            const pointer = flow.ranges.program.slots[slice.pointer].offset;
            const length = flow.ranges.program.slots[i].offset;
            a.ld(8, R10, Mem(FRAME, pointer));
            a.ld(8, R11, Mem(FRAME, length));
            if (slice.required <= int.max) {
                a.aluRI(Alu.cmp, 8, R11, cast(int) slice.required);
            } else {
                a.movI(RAX, slice.required);
                a.aluRR(Alu.cmp, 8, R11, RAX);
            }
            guard(CC_B);

            a.aluRR(Alu.add, 8, R11, R10);
            guard(CC_B);
            a.lea(RAX, Mem(FRAME, frameSize));
            a.aluRR(Alu.cmp, 8, R10, RAX);
            const above = gen.jccLocal(CC_AE);
            a.aluRR(Alu.cmp, 8, R11, FRAME);
            guard(CC_A);
            gen.patchHere(above);
        }
        foreach (i, ref const span; flow.ranges.spans[0 .. flow.ranges.program.slotCount]) {
            if (!span.end)
                continue;
            if (!space(128))
                return;
            const root = flow.ranges.program.slots[i];
            a.ld(8, R10, Mem(FRAME, root.offset));
            a.lea(R11, Mem(R10, cast(int) span.end - 1));
            a.aluRR(Alu.cmp, 8, R11, R10);
            guard(CC_B);
            a.ld(8, R9, Mem(STATE, DispatchState.frames.offsetof));
            a.lea(RAX, Mem(R10, cast(int) span.first));
            a.alu(Alu.cmp, 8, RAX, Mem(R9, FrameStack.baseOffset));
            guard(CC_B);
            a.alu(Alu.cmp, 8, R11, Mem(R9, FrameStack.fastEndOffset));
            guard(CC_AE);
            a.lea(R10, Mem(FRAME, frameSize));
            a.aluRR(Alu.cmp, 8, RAX, R10);
            const above = gen.jccLocal(CC_AE);
            a.aluRR(Alu.cmp, 8, R11, FRAME);
            guard(CC_AE);
            gen.patchHere(above);
        }
    }

    private void entry() {
        ref const block = flow.blocks[0];
        freeGp = cast(ushort) (Flow.bankMask(Lane.integer) & ~(1U << Flow.gpResult));
        freeFp = cast(ushort) (Flow.bankMask(Lane.floating) & ~1U);
        foreach (home, id; block.incoming[0 .. flow.ranges.program.slotCount]) {
            if (id != none && flow.values[id].used)
                move(homeLocation(cast(ushort) home), location(id));
        }
    }

    private bool emitNode(in Node node) {
        if (!space(120))
            return false;
        freeGp = node.availableGp;
        freeFp = node.availableFp;
        const out_ = location(node.output);
        const left = location(node.left);
        const right = location(node.right);
        final switch (node.action) with (Flow.Action) {
        case load: {
            const memory = memoryOf(node);
            if (out_.kind == LocationKind.floating)
                a.sse(prefix(node.width), loadOpcode, cast(int) out_.bits, memory);
            else {
                const dest = out_.kind == LocationKind.integer ? cast(int) out_.bits : takeGp;
                a.ldzx(node.width, dest, memory);
                saveInteger(dest, out_);
            }
            break;
        }
        case store: {
            if (node.address == none) {
                move(left, Location(LocationKind.frame, node.offset, node.width));
                break;
            }
            if (left.kind == LocationKind.floating) {
                const memory = memoryOf(node);
                a.sse(prefix(node.width), storeOpcode, cast(int) left.bits, memory);
            } else if (left.kind == LocationKind.integer) {
                const memory = memoryOf(node);
                a.st(node.width, memory, cast(int) left.bits);
            } else {
                const memory = memoryOf(node);
                int immediate;
                if (left.kind == LocationKind.literal && Gen.immOf(node.width, left.bits, immediate))
                    a.stI(node.width, memory, immediate);
                else
                    a.st(node.width, memory, integer(left));
            }
            break;
        }
        case operation:
            return emitOperation(node, out_, left, right);
        }
        return true;
    }

    private Mem memoryOf(in Node node, int addressScratch = -1) {
        if (node.address == none)
            return Mem(FRAME, cast(int) node.offset);
        const base = integer(location(node.address), addressScratch);
        if (node.indexed)
            return Mem(cast(ubyte) base, cast(int) node.offset, integer(location(node.right)),
                node.stride);
        return Mem(cast(ubyte) base, cast(int) node.offset);
    }

    private static bool memoryOperand(in Location value) {
        return value.kind == LocationKind.frame || value.kind == LocationKind.memory;
    }

    private Mem operandMemory(in Location value, int addressScratch = -1) {
        return value.kind == LocationKind.frame ? Frame(value)
            : memoryOf(flow.nodes[value.bits], addressScratch);
    }

    private bool emitOperation(in Node node, in Location dest,
        in Location left, in Location right)
    {
        ref const step = flow.ranges.resolved[node.pc];
        const w = step.left.width;
        final switch (step.kind) with (Kind) {
        case integer, shift:
            return emitInteger(step, node.integerOperands, dest, left, right);
        case intToFloat:
            emitIntToFloat(step.sourceUnsigned, w, dest, left);
            return true;
        case index:
            return emitIndex(step.stride, dest, left, right);
        case floating, sqrt, doubleFloat: {
            const fp = dest.kind == LocationKind.floating ? cast(int) dest.bits : takeFp;
            const prefix = prefix(w);
            if (step.kind == sqrt) {
                enum sqrtOpcode = 0x51;
                if (memoryOperand(left))
                    a.sse(prefix, sqrtOpcode, fp, operandMemory(left));
                else
                    a.sseRR(prefix, sqrtOpcode, fp, this.floating(left, fp));
            } else if (step.kind == doubleFloat) {
                assignFloat(left, fp);
                a.sseRR(prefix, _floatOpcodes[JitOp.FloatOperation.add], fp, fp);
            } else {
                const opcode = _floatOpcodes[step.floating];
                assignFloat(left, fp);
                if (memoryOperand(right))
                    a.sse(prefix, opcode, fp, operandMemory(right));
                else if (right.kind == LocationKind.literal)
                    literalSse(prefix, opcode, fp, right.bits);
                else
                    a.sseRR(prefix, opcode, fp, this.floating(right));
            }
            saveFloat(fp, dest);
            return true;
        }
        case compare:
            if (!this.compare(step, left, right))
                return false;
            if (dest.kind == LocationKind.frame)
                a.setcc(intCondition(step), Frame(dest));
            else if (dest.kind == LocationKind.integer)
                a.setccR(intCondition(step), cast(int) dest.bits);
            else
                return false;
            return true;
        case branch:
            return this.compare(step, left, right);
        case exit, jump, move, returnVoid, returnValue, checked, arrayLoad, arrayStore:
            return false;
        }
    }

    private void emitIntToFloat(bool sourceUnsigned, int w, in Location dest,
        in Location left)
    {
        enum convertOpcode = 0x0F2A;
        const fp = dest.kind == LocationKind.floating ? cast(int) dest.bits : takeFp;
        const p = prefix(dest.width);
        if (w == int.sizeof && !sourceUnsigned && memoryOperand(left)) {
            a.memOp(w, false, fp, operandMemory(left), convertOpcode, p);
        } else {
            auto source = w == int.sizeof && !sourceUnsigned ? integer(left) : takeGp;
            if (w < int.sizeof || sourceUnsigned) {
                assignInteger(left, source);
                if (sourceUnsigned)
                    a.movzxRR(w, source, source);
                else
                    a.movsxRR(w, source);
            }
            const encodedWidth = w == int.sizeof && sourceUnsigned ? long.sizeof : int.sizeof;
            a.b(p);
            a.rrOp(encodedWidth, false, fp, source, convertOpcode);
        }
        saveFloat(fp, dest);
    }

    private void saveFloat(int source, in Location dest) {
        if (dest.kind == LocationKind.frame)
            a.sse(prefix(dest.width), storeOpcode, source, Frame(dest));
        else if (dest.kind == LocationKind.integer)
            a.xmmToInteger(cast(int) dest.bits, source);
    }

    private bool emitInteger(in Plan.Operation step, in Flow.IntegerOperands operands,
        in Location dest, in Location left, in Location right)
    {
        alias Reg = Flow.IntegerOperands.Register;
        enum firstTemporary = Reg.firstTemporary;
        int[firstTemporary + Flow.gpCount] physical;
        physical[Reg.none] = -1;
        physical[Reg.left] = cast(int) left.bits;
        physical[Reg.right] = cast(int) right.bits;
        physical[Reg.output] = cast(int) dest.bits;
        foreach (ref reg; physical[firstTemporary .. firstTemporary + operands.temporaries])
            reg = takeGp;
        const result = physical[operands.result];
        const w = step.left.width;
        final switch (operands.form) with (Flow.IntegerOperands.Form) {
        case frameImmediate:
            a.aluMI(Gen.aluOf(step.integer), w, Frame(dest), operands.immediate);
            return true;
        case immediateShift:
            assignInteger(left, result);
            a.shiftImmediate(step.shift, w, result, cast(ubyte) shiftCount(right.bits, w));
            break;
        case variableShift: {
            const count = integer(right, physical[operands.right]);
            auto source = integer(left, physical[operands.left]);
            if (operands.extension != Reg.none) {
                const widened = physical[operands.extension];
                if (step.shift == JitOp.ShiftKind.arithmeticRight) {
                    if (widened != source)
                        a.movRR64(widened, source);
                    a.movsxRR(w, widened);
                } else {
                    a.movzxRR(w, widened, source);
                }
                source = widened;
            }
            a.shiftVariable(step.shift, w < int.sizeof ? int.sizeof : w, result, source, count);
            break;
        }
        case immediate:
            if (step.integer == JitOp.IntOperation.multiply)
                a.imulRI(result, integer(left, result), operands.immediate);
            else {
                assignInteger(left, result);
                a.aluRI(Gen.aluOf(step.integer), w, result, operands.immediate);
            }
            break;
        case memory:
            assignInteger(left, result);
            if (step.integer == JitOp.IntOperation.multiply) {
                if (w != long.sizeof && w != int.sizeof)
                    return false;
                a.imulM(w, result, operandMemory(right, physical[operands.address]));
            } else {
                a.alu(Gen.aluOf(step.integer), w, result,
                    operandMemory(right, physical[operands.address]));
            }
            break;
        case registers:
            assignInteger(left, result);
            const source = integer(right, physical[operands.right]);
            if (step.integer == JitOp.IntOperation.multiply) {
                if (w != long.sizeof && w != int.sizeof)
                    return false;
                a.imulRR(w, result, source);
            } else {
                a.aluRR(Gen.aluOf(step.integer), w, result, source);
            }
            break;
        }
        saveInteger(result, dest);
        return true;
    }

    private bool emitIndex(int stride, in Location dest, in Location left, in Location right) {
        const accumulator = dest.kind == LocationKind.integer ? cast(int) dest.bits : takeGp;
        if (right.kind == LocationKind.literal && right.bits <= int.max / stride) {
            const base = integer(left, accumulator);
            a.lea(accumulator, Mem(cast(ubyte) base, cast(int) (right.bits * stride)));
        } else if (Flow.scaled(stride)) {
            const index = integer(right);
            const base = integer(left);
            a.lea(accumulator, Mem(cast(ubyte) base, 0, index, cast(ubyte) stride));
        } else {
            const index = integer(right, accumulator);
            a.imulRI(accumulator, index, stride);
            if (left.kind == LocationKind.frame)
                a.alu(Alu.add, 8, accumulator, Frame(left));
            else if (left.kind == LocationKind.integer)
                a.aluRR(Alu.add, 8, accumulator, cast(int) left.bits);
            else
                a.aluRR(Alu.add, 8, accumulator, integer(left));
        }
        saveInteger(accumulator, dest);
        return true;
    }

    private bool compare(in Plan.Operation step, in Location aOp, in Location bOp) {
        const w = step.left.width;
        if (step.compareKind == CompareKind.floating) {
            const ccPrefix = w == 8 ? operandSizePrefix : noPrefix;
            const reverse = step.comparison == Comparison.lessThan
                || step.comparison == Comparison.lessOrEqual;
            const a = reverse ? bOp : aOp;
            const b = reverse ? aOp : bOp;
            const left = floating(a);
            if (b.kind == LocationKind.frame)
                this.a.sse(ccPrefix, compareOpcode, left, Frame(b));
            else if (b.kind == LocationKind.literal)
                literalSse(ccPrefix, compareOpcode, left, b.bits);
            else
                this.a.sseRR(ccPrefix, compareOpcode, left, floating(b));
            return true;
        }
        int immediate;
        const fits = bOp.kind == LocationKind.literal && Gen.immOf(w, bOp.bits, immediate);
        if (aOp.kind == LocationKind.frame && fits) {
            a.aluMI(Alu.cmp, w, Frame(aOp), immediate);
            return true;
        }
        const left = integer(aOp);
        if (fits)
            a.aluRI(Alu.cmp, w, left, immediate);
        else if (bOp.kind == LocationKind.frame)
            a.alu(Alu.cmp, w, left, Frame(bOp));
        else
            a.aluRR(Alu.cmp, w, left, integer(bOp));
        return true;
    }

    private static int intCondition(in Plan.Operation step) {
        return Gen.integerBranchCc(JitOp.Fused(step.comparison,
            step.compareKind, true));
    }

    private Branch conditional(in Plan.Operation step, ushort block, ushort target) {
        Branch branch;
        branch.block = block;
        branch.target = target;
        if (step.compareKind == CompareKind.floating) {
            final switch (step.comparison) with (Comparison) {
            case greaterThan, greaterOrEqual, lessThan, lessOrEqual:
                const strict = step.comparison == greaterThan || step.comparison == lessThan;
                branch.patches[branch.count++] = gen.jccLocal(
                    (strict ? CC_A : CC_AE) ^ !step.jumpWhen);
                break;
            case equal, notEqual:
                if ((step.comparison == equal) == step.jumpWhen) {
                    const skip = gen.jccLocal(CC_P);
                    branch.patches[branch.count++] = gen.jccLocal(CC_E);
                    gen.patchHere(skip);
                } else {
                    branch.patches[branch.count++] = gen.jccLocal(CC_P);
                    branch.patches[branch.count++] = gen.jccLocal(CC_NE);
                }
                break;
            }
        } else {
            branch.patches[branch.count++] = gen.jccLocal(intCondition(step) ^ !step.jumpWhen);
        }
        return branch;
    }

    private bool finish(in Block block, ushort id, ushort following) {
        import snakebite.backends.bytecode.vm: jitFallback;

        const pc = flow.terminalPc(block);
        ref const step = flow.ranges.resolved[pc];
        if (step.kind == Kind.exit || step.kind == Kind.returnValue || step.kind == Kind.returnVoid) {
            const canonical = step.kind != Kind.returnVoid;
            size_t count;
            foreach (home, value; block.outgoing[0 .. flow.ranges.program.slotCount])
                if (value != none && (home == flow.fp0Slot || home == flow.r0Slot
                        || canonical && flow.modified.has(home)))
                    moveScratch[count++] = Move(location(value), homeLocation(cast(ushort) home));
            parallelMoves(moveScratch[0 .. count]);
            if (!space(192))
                return false;
            // Chained dispatch retains the real activation in the state.
            // An inline window changes FRAME but leaves that activation current.
            a.ld(8, ACTIVE, Mem(STATE, DispatchState.current.offsetof));
            if (recordedEntry != none) {
                const target = cast(ushort) step.bias;
                if (target == recordedEntry)
                    gen.jumpToHandler(target, originals[target]);
                else
                    gen.jumpToPathExit(target);
                return true;
            }
            if (step.kind == Kind.returnVoid) {
                if (gen.inlineCaller !is null) {
                    inlineReturn = true;
                    return gen.emitInlineReturn(pc, false);
                }
                return gen.emitReturn(pc, false, originals[pc]);
            }
            if (step.kind == Kind.returnValue && gen.inlineCaller !is null) {
                inlineReturn = true;
                return gen.emitInlineReturn(pc, true);
            }
            if (originals[pc] is null)
                a.ud2;
            else
                gen.jumpToHandler(pc, jitFallback(gen.function_, gen.snapshot[pc], originals[pc]));
            return true;
        }

        ushort target = block.next == none ? block.target : block.next;
        if (step.kind == Kind.branch && block.target != block.next) {
            if (redirects[block.target] == following && redirects[block.next] != following) {
                Plan.Operation inverse = step;
                inverse.jumpWhen = !inverse.jumpWhen;
                branches[branchCount++] = conditional(inverse, id, block.next);
                target = block.target;
            } else {
                branches[branchCount++] = conditional(step, id, block.target);
            }
        }
        if (target == none)
            return false;
        edge(block, flow.blocks[target]);
        if (!space(8))
            return false;
        if (redirects[target] != following) {
            a.b(0xE9);
            const patch = a.n;
            a.d32(0);
            // The copies are already on this edge.
            branches[branchCount++] = Branch([patch, 0], 1, none, target);
        }
        return true;
    }

    private bool movesNeeded(in Block from, in Block to) {
        foreach (home, id; to.incoming[0 .. flow.ranges.program.slotCount]) {
            if (id != none && flow.values[id].used && !flow.frameResident(id)
                    && location(id) != location(from.outgoing[home]))
                return true;
        }
        return false;
    }

    private void edge(in Block from, in Block to) {
        size_t count;
        foreach (home, id; to.incoming[0 .. flow.ranges.program.slotCount]) {
            if (id != none && flow.values[id].used && !flow.frameResident(id))
                moveScratch[count++] = Move(location(from.outgoing[home]), location(id));
        }
        parallelMoves(moveScratch[0 .. count]);
    }

    private void parallelMoves(Move[] moves) {
        freeGp = Flow.bankMask(Lane.integer);
        freeFp = Flow.bankMask(Lane.floating);
        foreach (i, ref const transfer; moves) {
            protect(transfer.from);
            protect(transfer.to);
            foreach (ref const earlier; moves[0 .. i]) {
                if (samePlace(earlier.to, transfer.to) && earlier.from != transfer.from) {
                    failed = true;
                    return;
                }
            }
        }
        const availableGp = freeGp;
        const availableFp = freeFp;
        while (moves.length) {
            freeGp = availableGp;
            freeFp = availableFp;
            foreach (ref const waiting; moves)
                protect(waiting.from);
            bool progress;
            foreach (i, ref const transfer; moves) {
                bool occupied;
                foreach (j, ref const waiting; moves)
                    occupied |= j != i && samePlace(transfer.to, waiting.from);
                if (!occupied || samePlace(transfer.from, transfer.to)) {
                    move(transfer.from, transfer.to);
                    moves[i] = moves[$ - 1];
                    moves = moves[0 .. $ - 1];
                    progress = true;
                    break;
                }
            }
            if (!progress) {
                if (!space(32))
                    return;
                const transfer = moves[0];
                if (transfer.from.kind == transfer.to.kind
                        && transfer.from.kind == LocationKind.integer) {
                    a.rrOp(8, false, cast(int) transfer.from.bits,
                        cast(int) transfer.to.bits, 0x87);
                } else if (transfer.from.kind == transfer.to.kind
                        && transfer.from.kind == LocationKind.floating) {
                    const left = cast(int) transfer.from.bits;
                    const right = cast(int) transfer.to.bits;
                    enum xorPacked = 0x57;
                    a.sseRR(noPrefix, xorPacked, left, right);
                    a.sseRR(noPrefix, xorPacked, right, left);
                    a.sseRR(noPrefix, xorPacked, left, right);
                } else {
                    const width = transfer.from.width;
                    const scratch = !freeGp && (width == 4 || width == 8)
                        ? Location(LocationKind.floating, takeFp, width)
                        : Location(LocationKind.integer, takeGp, width);
                    if (failed)
                        return;
                    move(transfer.from, scratch);
                    foreach (ref waiting; moves)
                        if (samePlace(waiting.from, transfer.from))
                            waiting.from = scratch;
                    continue;
                }
                moves = moves[1 .. $];
                foreach (ref waiting; moves)
                    if (samePlace(waiting.from, transfer.to))
                        waiting.from = transfer.from;
                    else if (samePlace(waiting.from, transfer.from))
                        waiting.from = transfer.to;
            }
            if (failed)
                return;
        }
    }

    private void protect(in Location value) {
        if (value.kind == LocationKind.floating)
            freeFp &= cast(ushort) ~(1U << value.bits);
        else if (value.kind == LocationKind.integer)
            foreach (i, reg; _gp)
                if (value.bits == reg)
                    freeGp &= cast(ushort) ~(1U << i);
    }

    private static bool samePlace(in Location a, in Location b) {
        return a.kind == b.kind && a.bits == b.bits
            && (a.kind == LocationKind.floating || a.kind == LocationKind.integer
                || a.kind == LocationKind.frame);
    }

    private Location homeLocation(ushort home) {
        ref const slot = flow.ranges.program.slots[home];
        if (home == flow.fp0Slot)
            return Location(LocationKind.floating, fp0Register, slot.width);
        if (home == flow.r0Slot)
            return Location(LocationKind.integer, REG0, slot.width);
        return Location(LocationKind.frame, slot.offset, slot.width);
    }

    private Location location(ushort id) {
        if (id == none)
            return Location.init;
        ref const value = flow.values[id];
        final switch (value.origin) with (Origin) {
        case literal: return Location(LocationKind.literal, value.bits, value.width);
        case address: return Location(LocationKind.address, value.bits, value.width);
        case phi, produced:
            if (value.folded)
                return Location(LocationKind.memory, value.first, value.width);
            if (value.spilled)
                return homeLocation(value.home);
            if (!value.used)
                return Location.init;
            if (value.lane == Lane.floating)
                return Location(LocationKind.floating, value.color, value.width);
            return Location(LocationKind.integer, _gp[value.color], value.width);
        }
    }

    private void move(in Location source, in Location dest) {
        if (source == dest || !space(32))
            return;
        final switch (dest.kind) with (LocationKind) {
        case none, literal, address, memory:
            return;
        case integer:
            assignInteger(source, cast(int) dest.bits);
            return;
        case floating:
            assignFloat(source, cast(int) dest.bits);
            return;
        case frame:
            if (source.kind == floating && (dest.width == 4 || dest.width == 8)) {
                a.sse(prefix(dest.width), storeOpcode, cast(int) source.bits, Frame(dest));
            } else if (source.kind == literal) {
                int immediate;
                if (Gen.immOf(dest.width, source.bits, immediate))
                    a.stI(dest.width, Frame(dest), immediate);
                else
                    a.st(dest.width, Frame(dest), this.integer(source));
            } else {
                const reg = this.integer(source);
                a.st(dest.width, Frame(dest), reg);
            }
            return;
        }
    }

    private int takeGp() {
        return _gp[take(freeGp)];
    }

    private int takeFp() {
        return take(freeFp);
    }

    private int take(ref ushort available) {
        import core.bitop: bsf;

        if (!available) {
            failed = true;
            return 0;
        }
        const first = bsf(available);
        available &= available - 1;
        return first;
    }

    private int integer(in Location value, int scratch = -1) {
        if (value.kind == LocationKind.integer)
            return cast(int) value.bits;
        const reg = scratch >= 0 ? scratch : takeGp;
        assignInteger(value, reg);
        return reg;
    }

    private void assignInteger(in Location value, int reg) {
        final switch (value.kind) with (LocationKind) {
        case integer:
            if (reg != value.bits)
                a.movRR64(reg, cast(int) value.bits);
            break;
        case floating:
            a.xmmToInteger(reg, cast(int) value.bits);
            break;
        case frame:
            a.ldzx(value.width, reg, Frame(value));
            break;
        case memory:
            a.ldzx(value.width, reg, operandMemory(value));
            break;
        case literal:
            a.movI(reg, value.bits);
            break;
        case address:
            a.lea(reg, Mem(FRAME, cast(int) value.bits));
            break;
        case none:
            failed = true;
            break;
        }
    }

    private void saveInteger(int source, in Location dest) {
        if (dest.kind == LocationKind.integer) {
            if (dest.bits != source)
                a.movRR64(cast(int) dest.bits, source);
        } else if (dest.kind == LocationKind.frame)
            a.st(dest.width, Frame(dest), source);
        else if (dest.kind == LocationKind.floating)
            a.integerToXmm(cast(int) dest.bits, source);
    }

    private int floating(in Location value, int scratch = -1) {
        if (value.kind == LocationKind.floating)
            return cast(int) value.bits;
        const reg = scratch >= 0 ? scratch : takeFp;
        assignFloat(value, reg);
        return reg;
    }

    private void assignFloat(in Location value, int reg) {
        final switch (value.kind) with (LocationKind) {
        case floating:
            if (reg != value.bits)
                a.sseRR(noPrefix, moveAlignedOpcode, reg, cast(int) value.bits);
            break;
        case frame, memory:
            if (value.width == 4 || value.width == 8)
                a.sse(prefix(value.width), loadOpcode, reg, operandMemory(value));
            else
                a.integerToXmm(reg, this.integer(value));
            break;
        case literal:
            literalSse(prefix(value.width), loadOpcode, reg, value.bits);
            break;
        case integer, address:
            a.integerToXmm(reg, this.integer(value));
            break;
        case none:
            failed = true;
            break;
        }
    }

    private void literalSse(ubyte prefix, ubyte opcode, int reg, ulong bits) {
        if (gen.literalScratch.grow(gen.literalCount + 1) is null) {
            failed = true;
            return;
        }
        a.sseRip(prefix, opcode, reg);
        gen.literalScratch.ptr[gen.literalCount++] = Literal(a.n - int.sizeof, bits);
    }

    private static ubyte prefix(int width) {
        return width == double.sizeof ? doublePrefix : singlePrefix;
    }

    private static Mem Frame(in Location location) {
        return Mem(FRAME, cast(int) location.bits);
    }
}

private struct Gen {
    import snakebite.backends.bytecode.vm: Activation, CallSite,
        chainedDispatch, CheckedAccess, CompareKind, Comparison, Destination,
        DispatchState, Function, indirectBit, IndexBase, Instruction;
    import snakebite.stack.frames: FrameStack;
    import snakebite.native.value: arrayLengthOffset, arrayPointerOffset,
        shiftCount;

    @nogc nothrow:

    Asm a;
    Scratch!Fixup* fixupScratch;
    Scratch!Literal* literalScratch;
    Scratch!(ScalarFlow, 1)* scalarScratch;
    Scratch!(ScalarEmitter, 1)* scalarEmitterScratch;
    Scratch!ReloadEntry* reloadEntryScratch;
    InlineBody* inlineBodies;
    FpSlots fpSlots;
    FpLoop fpLoop;
    IntSlots intSlots;
    IntLoop intLoop;
    size_t intLoopInstruction = size_t.max;
    CheckedEntry checkedEntry;
    CheckedLoop checkedLoop;
    bool readIntSlot;
    size_t reloadEntryCount;
    bool bmi2;
    const(Function)* function_;
    size_t codeLimit;
    bool expandWindows;
    const(ubyte)* refreshBase;
    size_t watchCalleeCall = size_t.max;
    size_t watchedCall = size_t.max;
    size_t unprofiledCall = size_t.max;
    bool expandedWatchedCall;
    const(Instruction)[] instructions;
    const(Instruction)[] snapshot;
    size_t frameSize;
    const(long)[] constants;
    const(CallSite)[] callSites;
    // Set while emitting a body whose activation has yet to be installed.
    const(Gen)* inlineCaller;
    const(CallSite)* inlineSite;
    const(CallSite.FastCall)* inlineLayout;
    size_t inlineCall;
    uint inlineDepth;
    bool inlineResultMayBeNull;
    size_t[] labels;
    Fixup* fixups;
    size_t fixupCount;
    size_t fixupCap;
    size_t literalCount;
    bool outOfMemory;

    static struct KnownConstant {
        size_t offset;
        size_t width;
        ulong bits;

        bool covers(size_t raw, size_t size) const pure nothrow @nogc @safe {
            return width != 0 && raw == offset && size <= width;
        }
    }

    KnownConstant known;
    bool usedKnown;

    void rememberConstant(in Instruction ins, in JitOp op) {
        KnownConstant next;
        if (!(ins.destination & indirectBit)) {
            with (JitOp.Kind) {
                if (op.kind == constant)
                    next = KnownConstant(ins.destination, ins.width,
                        cast(ulong) constants[ins.source]);
                else if (op.kind == zero)
                    next = KnownConstant(ins.destination, ins.width, 0);
                else if (op.kind == copy) {
                    const width = op.width ? op.width : ins.width;
                    if (isLiteralCopy(ins, op, width))
                        next = KnownConstant(ins.destination, width,
                            constantAt(ins.source, cast(int) width));
                    else if (usedKnown)
                        next = KnownConstant(ins.destination, width, known.bits);
                }
            }
        }
        known = next;
    }

    static bool isLiteralCopy(in Instruction ins, in JitOp op, size_t width) {
        return op.copy.staticSource
            && ins.sourceWidth == Instruction.immutableSource && goodWidth(width);
    }

    void fix(size_t target) {
        if (fixupCount == fixupCap) {
            // `auto`: `fixups` takes it, and it must be mutable.
            auto grown = fixupScratch.grow(fixupCap ? fixupCap * 2 : 256);
            if (grown is null) {
                outOfMemory = true;
                return;
            }
            fixups = grown;
            fixupCap = fixupScratch.cap;
        }
        fixups[fixupCount++] = Fixup(a.n, target);
        a.d32(0);
    }

    size_t literalBytes() const {
        return literalCount * ulong.sizeof;
    }

    void emitLiterals() {
        foreach (literal; literalScratch.ptr[0 .. literalCount]) {
            *cast(int*) (a.buf + literal.displacement) = cast(int) (
                a.n - (literal.displacement + int.sizeof));
            a.q64(literal.bits);
        }
    }

    static struct FloatRight {
        Mem memory;
        size_t literalAddress;
    }

    bool floatRight(ubyte scratch, size_t raw, bool constant, out FloatRight r) {
        if (!constant)
            return opnd(raw, scratch, r.memory);
        r.literalAddress = raw;
        return true;
    }

    void sseRight(int width, ubyte prefix, ubyte opcode, int x, in FloatRight r) {
        if (!r.literalAddress) {
            a.sse(prefix, opcode, x, r.memory);
            return;
        }
        if (literalScratch.grow(literalCount + 1) is null) {
            outOfMemory = true;
            return;
        }
        a.sseRip(prefix, opcode, x);
        literalScratch.ptr[literalCount++] = Literal(a.n - int.sizeof,
            constantAt(r.literalAddress, width));
    }

    void jmpTo(size_t target) {
        a.b(0xE9);
        fix(target);
    }

    void jccTo(int cc, size_t target, size_t localTarget = 0) {
        a.b(0x0F);
        a.b(cast(ubyte) (0x80 + cc));
        if (localTarget)
            a.d32(cast(int) (localTarget - (a.n + int.sizeof)));
        else
            fix(target);
    }

    // A forward jump inside the code of one instruction; returns the position
    // to patch.
    size_t jccLocal(int cc) {
        a.b(0x0F);
        a.b(cast(ubyte) (0x80 + cc));
        const p = a.n;
        a.d32(0);
        return p;
    }

    void patchTo(size_t p, size_t target) {
        *cast(int*) (a.buf + p) = cast(int) (target - (p + int.sizeof));
    }

    void patchHere(size_t p) {
        patchTo(p, a.n);
    }

    // The branch target stored as an address in a field.
    bool targetIndex(size_t field, out size_t index) {
        const first = cast(size_t) instructions.ptr;
        if (field < first)
            return false;
        const d = field - first;
        if (d % Instruction.sizeof != 0 || d / Instruction.sizeof
                >= instructions.length)
            return false;
        index = d / Instruction.sizeof;
        return true;
    }

    // A storage operand. An indirect one loads its address slot into `scratch`.
    // A template can reuse a pointer if its register stays live until the access.
    bool opnd(bool reusePointer = false)(size_t raw, ubyte scratch, out Mem m) {
        if (raw & indirectBit) {
            Mem addressSlot;
            if (!storageOperand(raw, scratch, m, addressSlot))
                return false;
            static if (reusePointer) {
                const cached = cachedInt(addressSlot, 8);
                if (cached >= 0) {
                    m.base = cast(ubyte) cached;
                    return true;
                }
            }
            a.ld(8, scratch, addressSlot);
            return true;
        }
        return frameOperand(raw, m);
    }

    static bool storageOperand(size_t raw, ubyte scratch, out Mem value,
        out Mem addressSlot)
    {
        import snakebite.backends.bytecode.vm: addressSlotOf;

        if (!(raw & indirectBit))
            return frameOperand(raw, value);
        if (!frameOperand(addressSlotOf(raw), addressSlot)
                || !frameOperand(cast(uint) raw, value))
            return false;
        value.base = scratch;
        return true;
    }

    static bool frameOperand(size_t raw, out Mem m) pure @safe {
        if (raw > 0x7fff_0000)
            return false;
        m = Mem(FRAME, cast(int) raw);
        return true;
    }

    // `size` bytes from `s` to `d`, in chunks. Overlap is not allowed.
    void copyChunks(Mem s, Mem d, size_t size) {
        size_t off = 0;
        while (size - off >= 16) {
            auto ss = s; ss.disp += cast(int) off;
            auto dd = d; dd.disp += cast(int) off;
            a.sse(noPrefix, loadOpcode, XMM1, ss);
            a.sse(noPrefix, storeOpcode, XMM1, dd);
            off += 16;
        }
        foreach (c; _chunkSizes) {
            if (size - off >= c) {
                auto ss = s; ss.disp += cast(int) off;
                auto dd = d; dd.disp += cast(int) off;
                a.ld(c, RAX, ss);
                a.st(c, dd, RAX);
                off += c;
            }
        }
    }

    static struct WindowArm {
        const(Function)* callee;
        const(CallSite.FastCall)* fast;
        const(void)* entry;
        ptrdiff_t adjustment;
        size_t mismatch;
        size_t hit;
        size_t unprofiledCall = size_t.max;
        bool expandedWatchedCall;
        size_t grow;
        size_t tierUp;

        bool hasPlace() const pure nothrow @nogc @safe {
            return callee.returnPlace.offset != size_t.max;
        }

        bool hasWindows() const pure nothrow @nogc @safe {
            return callee.windowSlot != size_t.max;
        }
    }

    // The reservation also covers the fallback and any FP seed loads.
    private enum windowArmBytes = 23 + 35 + 40 + 71 + 31 + 51;
    private enum handlerJumpBytes = 22;
    private enum lateDispatchBytes = 25 + handlerJumpBytes;
    private enum fpSeedBytes = 8 * FpSlots.count;
    static assert(CallSite.maxIndirectTargets * windowArmBytes
        + handlerJumpBytes + lateDispatchBytes + fpSeedBytes <= maximumBytesPerInstruction);
    static assert(Activation.sizeof <= byte.max + 1
        && Instruction.sizeof <= byte.max
        && FrameStack.fastEndOffset <= byte.max
        && FrameStack.topOffset <= byte.max
        && FrameStack.baseOffset <= byte.max
        && FrameStack.cleanupMarkOffset <= byte.max
        && DispatchState.frames.offsetof <= byte.max
        && DispatchState.current.offsetof <= byte.max);
    static foreach (register; [RAX, R9, R10, R11, FRAME, STATE, ACTIVE, PCREG])
        static assert((register & 7) != 4);
    static assert(FRAME < 8 && FpSlots.firstRegister + FpSlots.count <= 8);

    bool emitCallWindow(size_t i, in JitOp.CallWindow op,
        Instruction.Handler original)
    {
        import core.atomic: atomicLoad, MemoryOrder;

        const site = &callSites[snapshot[i].source];
        if (site.windowSlot > int.max || site.windowDisp > int.max
                || site.windowScratch > int.max)
            return false;

        WindowArm[CallSite.maxIndirectTargets] arms;
        size_t count;
        const link = op.indirect && op.counted && inlineCaller is null;
        if (op.indirect) {
            static if (chainedDispatch) {
                if (site.calleeSlotOffset > int.max)
                    return false;
                foreach (index; 0 .. CallSite.maxIndirectTargets) {
                    const arm = readIndirectArm(*site.indirectTargetAt(index));
                    if (arm.entry is null) {
                        if (index == 0 && inlineDepth == 1
                                && unprofiledCall == size_t.max)
                            unprofiledCall = i;
                        break;
                    }
                    if (encodableWindowArm(arm))
                        arms[count++] = arm;
                }
            } else
                return false;
        } else {
            const fast = &site.fast;
            if (atomicLoad!(MemoryOrder.acq)(
                    *cast(shared(uint)*) &fast.state)
                    != CallSite.FastCall.State.ready)
                return false;
            arms[count++] = WindowArm(fast.callee, fast);
            if (!encodableWindowArm(arms[0]))
                return false;
        }

        size_t end;
        foreach (ref arm; arms[0 .. count]) {
            const previous = a.n;
            if (expandWindows && emitWindowBody(i, snapshot[i], op, site, arm)) {
                expandedWatchedCall |= i == watchedCall;
                jmpTo(i + 1);
            } else {
                if (inlineCaller !is null)
                    continue;
                if (!emitCallWindowArm(&instructions[i], snapshot[i], op,
                        site, arm))
                    return false;
            }
            if (end != 0 && op.indirect)
                patchTo(arms[end - 1].mismatch, previous);
            arms[end++] = arm;
        }
        if (!end && !link)
            return false;
        if (op.indirect && end)
            patchHere(arms[end - 1].mismatch);
        static if (chainedDispatch) {
            import snakebite.backends.bytecode.vm: indirectWindowFallback;

            if (link) {
                // An x86 load acquires the destination published by the linker.
                a.movI(RAX, cast(size_t) &site.lateWindowEntry);
                a.ld(8, RAX, Mem(RAX, 0));
                a.aluRI(Alu.cmp, 8, RAX, 0);
                const uncached = jccLocal(CC_E);
                a.jmpRax;
                patchHere(uncached);
                jumpToHandler(i, indirectWindowFallback!true(op.destination));
            }
        }
        foreach (ref const arm; arms[0 .. end]) {
            patchHere(arm.grow);
            if (op.counted)
                patchHere(arm.tierUp);
        }
        jumpToHandler(i, original);
        return true;
    }

    static if (chainedDispatch) {
        static WindowArm readIndirectArm(in ref CallSite.IndirectTarget target) {
            import core.atomic: atomicLoad, MemoryOrder;

            const entry = atomicLoad!(MemoryOrder.acq)(target.entry);
            if (entry is null)
                return WindowArm.init;
            const callee = target.callee;
            return WindowArm(callee, &callee.windowFacts, entry,
                target.adjustment);
        }
    }

    static bool encodableWindowArm(in ref WindowArm arm) {
        if (arm.callee is null)
            return false;
        const fast = arm.fast;
        return arm.adjustment >= int.min && arm.adjustment <= int.max
            && (arm.adjustment == 0 || arm.callee.contextOffset <= int.max)
            && fast.frameBytes <= int.max && fast.frameOffset <= int.max
            && fast.reachBytes <= int.max
            && (!arm.hasPlace || fast.placeStore <= int.max)
            && (!arm.hasWindows || (fast.windowStore <= int.max
                && fast.windowBase <= int.max));
    }

    void emitWindowChecks(in JitOp.CallWindow op, const(CallSite)* site,
        ref WindowArm arm)
    {
        const entry = arm.entry;
        if (entry !is null) {
            a.movI(RAX, cast(size_t) entry);
            a.alu(Alu.cmp, 8, RAX, Mem(FRAME, cast(int) site.calleeSlotOffset));
            arm.mismatch = jccLocal(CC_NE);
        }
        arm.hit = a.n;
        if (refreshBase !is null) {
            // Keep the match transfer the same size in the timing control.
            a.b(0x48);
            a.b(0xB8);
            const address = a.n;
            a.q64(0);
            a.jmpRax;
            *cast(ulong*) (a.buf + address) = cast(size_t) (refreshBase + a.n);
        }
        loadWindow(site);
        guardWindow(op, arm);
    }

    void guardWindow(in JitOp.CallWindow op, ref WindowArm arm) {
        a.lea(RAX, Mem(R11, cast(int) arm.fast.reachBytes));
        a.alu(Alu.cmp, 8, RAX, Mem(R9, FrameStack.fastEndOffset));
        arm.grow = jccLocal(CC_A);

        if (op.counted) {
            a.movI(PCREG, cast(size_t) arm.callee);
            const heat = Mem(PCREG, Function.jitHeat.offsetof);
            a.ld(4, RAX, heat);
            a.aluRI(Alu.add, 4, RAX, jitStep);
            // Let the counting handler perform the event on carry.
            arm.tierUp = jccLocal(CC_B);
            a.st(4, heat, RAX);
        }
    }

    void loadWindow(const(CallSite)* site) {
        a.ld(8, R9, Mem(STATE, DispatchState.frames.offsetof));
        a.ld(8, R10, Mem(FRAME, cast(int) site.windowSlot));
        a.lea(R11, Mem(R10, cast(int) site.windowDisp));
    }

    bool prepareWindow(in Instruction ins, in JitOp.CallWindow op,
        const(CallSite)* site, in ref WindowArm arm)
    {
        Mem place;
        if (op.destination == Destination.discard)
            place = Mem(R10, cast(int) site.windowScratch);
        else if (!opnd(ins.destination, RAX, place))
            return false;
        a.lea(RAX, place);
        a.st(8, Mem(R11, Activation.returnPlace.offsetof), RAX);
        setWindowFrame(arm);
        return true;
    }

    void setWindowFrame(in WindowArm arm) {
        const callee = arm.callee;
        const fast = arm.fast;
        const adjustment = arm.adjustment;
        a.lea(FRAME, Mem(R11, cast(int) fast.frameOffset));
        if (arm.hasPlace)
            a.st(8, Mem(FRAME, cast(int) fast.placeStore), RAX);
        if (adjustment != 0) {
            const context = Mem(FRAME, cast(int) callee.contextOffset);
            a.ld(8, RAX, context);
            a.aluRI(Alu.add, 8, RAX, cast(int) adjustment);
            a.st(8, context, RAX);
        }
        if (arm.hasWindows) {
            a.lea(RAX, Mem(R11, cast(int) fast.windowBase));
            a.st(8, Mem(FRAME, cast(int) fast.windowStore), RAX);
        }
    }

    void activateWindow(const(Instruction)* pc, const(Function)* callee,
        const(CallSite.FastCall)* fast)
    {
        a.ld(8, RAX, Mem(R9, FrameStack.topOffset));
        a.alu(Alu.sub, 8, RAX, Mem(R9, FrameStack.baseOffset));
        a.st(8, Mem(R11, Activation.frameMark.offsetof), RAX);
        a.lea(RAX, Mem(R11, cast(int) fast.frameBytes));
        a.st(8, Mem(R9, FrameStack.topOffset), RAX);
        a.ld(8, RAX, Mem(R9, FrameStack.cleanupMarkOffset));
        a.st(8, Mem(R11, Activation.cleanupMark.offsetof), RAX);

        // A throw from the callee uses the call site in the parent.
        a.movI(PCREG, cast(size_t) pc);
        a.st(8, Mem(ACTIVE, Activation.pc.offsetof), PCREG);
        a.lea(RAX, Mem(PCREG, Instruction.sizeof));
        a.st(8, Mem(ACTIVE, Activation.resume.offsetof), RAX);
        a.st(8, Mem(R11, Activation.parent.offsetof), ACTIVE);
        a.movI(RAX, cast(size_t) callee);
        a.st(8, Mem(R11, Activation.function_.offsetof), RAX);
        a.st(8, Mem(R11, Activation.frame.offsetof), FRAME);
        a.st(8, Mem(STATE, DispatchState.current.offsetof), R11);
        a.movRR64(ACTIVE, R11);
    }

    bool emitCallWindowArm(const(Instruction)* pc, in Instruction ins,
        in JitOp.CallWindow op, const(CallSite)* site, ref WindowArm arm)
    {
        emitWindowChecks(op, site, arm);
        if (!prepareWindow(ins, op, site, arm))
            return false;
        activateWindow(pc, arm.callee, arm.fast);
        jumpToLive(arm.callee.instructions.ptr);
        return true;
    }

    private enum transferPathValues = true;
    private enum pathAddress = FpSlots.firstRegister;
    private bool emittingPath;
    private int retainedWidth;
    private size_t pathMemoryGuard;
    private bool retainedAcrossCall;
    private bool reusedAcrossCall;

    private enum pathBudget = 96;
    private enum pathDepth = 4;

    const(ObservedEdge)[] selectObservedPath(const(Function)* function_,
        const(JitOp)[] ops, const(ObservedEdge)[] observed,
        ref Scratch!(PathScratch, 1) storage)
    {
        if (observed.length == 0 || function_.returnPlace.offset != size_t.max)
            return null;

        size_t bestScore;
        const(ObservedEdge)[] best;
        const(ObservedEdge)[] bestLoop;
        size_t bestLoopScore;
        foreach (start, edge; observed) {
            const startsAtCall = edge.next == ObservedEdge.call;
            if (!startsAtCall && ops[edge.pc].kind != JitOp.Kind.fused)
                continue;
            ushort[pathDepth] resumes;
            size_t depth;
            size_t returns;
            size_t length;
            size_t finished;
            size_t completedReturns;
            size_t expected = edge.pc;
            foreach (step; observed[start .. $]) {
                if ((startsAtCall && length == pathBudget) || step.pc != expected)
                    break;
                const op = ops[step.pc];
                if (step.next == ObservedEdge.call
                        && op.kind == JitOp.Kind.callWindow) {
                    if (depth == pathDepth
                            || !observedWindow(function_, step.pc,
                                op.callWindow).callee)
                        break;
                    resumes[depth++] = cast(ushort) (step.pc + 1);
                    expected = 0;
                } else if (step.next == ObservedEdge.return_
                        && op.kind == JitOp.Kind.returnVoid) {
                    if (!depth)
                        break;
                    expected = resumes[--depth];
                    ++returns;
                    if (startsAtCall && !depth) {
                        finished = length + 1;
                        completedReturns = returns;
                    }
                } else if (step.next < ops.length && pathOp(op)) {
                    expected = step.next;
                    if (!startsAtCall && depth == 0 && step.next == edge.pc) {
                        if (returns && op.kind == JitOp.Kind.jump) {
                            finished = length + 1;
                            completedReturns = returns;
                        }
                        break;
                    }
                } else
                    break;
                ++length;
            }
            if (!finished)
                continue;
            const candidate = observed[start .. start + finished];
            size_t hits;
            bool earlier;
            foreach (other, entry; observed[0 .. $ - finished + 1]) {
                if (entry == edge && candidate == observed[other .. other + finished]) {
                    if (!startsAtCall && other < start) {
                        earlier = true;
                        break;
                    }
                    ++hits;
                }
            }
            if (earlier || hits < 2)
                continue;
            if (!startsAtCall) {
                auto scratch = storage.reserve(1);
                if (scratch is null)
                    continue;
                ref plan = scratch.candidate;
                plan.guards.count = 0;
                plan.memory = PathMemory.init;
                if (!analyzePath(candidate, ops, *scratch, true))
                    continue;
                plan.memory = PathMemory.init;
                plan.actions[0 .. finished] = PathAction.init;
                if (!analyzePath(candidate, ops, *scratch, false))
                    continue;
                size_t savings;
                if (plan.memory.descriptor.width) {
                    if (!plan.actions[plan.memory.first].checked.skipBounds
                            || plan.memory.maximumIndex < 0)
                        continue;
                    const guardCost = 36 + 2 * plan.guards.count;
                    if (plan.memory.saved <= guardCost)
                        continue;
                    savings = plan.memory.saved - guardCost;
                } else {
                    // A virtual call and return eliminate the frame
                    // setup even on a path with no array accesses.
                    enum frameTransferCost = 8;
                    savings = completedReturns * frameTransferCost;
                }
                const loopScore = hits * savings;
                if (loopScore > bestLoopScore) {
                    bestLoopScore = loopScore;
                    bestLoop = candidate;
                    const checks = plan.guards.count;
                    scratch.best.guards.count = checks;
                    scratch.best.guards.guards[0 .. checks] = plan.guards.guards[0 .. checks];
                    scratch.best.memory = plan.memory;
                    scratch.best.repeating = true;
                    scratch.best.actions[0 .. finished] = plan.actions[0 .. finished];
                }
                continue;
            }
            const score = hits * completedReturns;
            if (score >= bestScore
                    && (score > bestScore || candidate.length > best.length)) {
                bestScore = score;
                best = candidate;
            }
        }
        if (bestLoopScore > bestScore)
            return bestLoop;
        if (!best.length || storage.reserve(1) is null)
            return null;
        storage.ptr.best.repeating = false;
        return best;
    }

    static bool pathOp(in JitOp op) {
        with (JitOp.Kind)
            return op.kind == copy || op.kind == jump
                || (op.kind == checked && !op.checked.sharedAccess)
                || (op.kind == int3 && !op.int3.resultInR0 && !op.int3.leftInR0)
                || (op.kind == fused && !op.fused.leftInR0
                    && op.fused.kind != CompareKind.floating);
    }

    WindowArm observedWindow(const(Function)* function_, size_t i,
        in JitOp.CallWindow op)
    {
        import core.atomic: atomicLoad, MemoryOrder;

        const site = &callSites[snapshot[i].source];
        if (op.indirect || op.destination != Destination.discard
                || site.windowSlot > int.max || site.windowDisp > int.max
                || site.windowScratch > int.max
                || atomicLoad!(MemoryOrder.acq)(
                    *cast(shared(uint)*) &site.fast.state)
                    != CallSite.FastCall.State.ready
                || site.fast.callee !is function_)
            return WindowArm.init;
        const arm = WindowArm(function_, &site.fast);
        return encodableWindowArm(arm) ? arm : WindowArm.init;
    }

    private struct PathCall {
        size_t pc;
        int parent = -1;
        WindowArm arm;
        int frameInWindow;
    }

    private struct PathPlace {
        int offset;
        bool window;

        bool overlaps(PathPlace other, int width, int otherWidth) const @nogc nothrow {
            return window == other.window
                && offset < cast(long) other.offset + otherWidth
                && other.offset < cast(long) offset + width;
        }
    }

    private struct PathValue {
        uint identity;
        ubyte width;
        ulong bits;

        PathValue shifted(ulong difference) const @nogc nothrow {
            const sum = bits + difference;
            const mask = ulong.max >> ((ulong.sizeof - width) * 8);
            return PathValue(identity, width, sum & mask);
        }
    }

    private struct PathValues {
        @nogc nothrow:
        private struct Slot {
            PathPlace place;
            PathValue value;
            bool entry;
        }

        Slot[2 * ObservedEdge.limit] slots = void;
        size_t count;
        uint nextIdentity = 1;

        PathValue lookup(PathPlace place, ubyte width) {
            bool entry = !place.window;
            foreach_reverse (ref const slot; slots[0 .. count]) {
                if (!place.overlaps(slot.place, width, slot.value.width))
                    continue;
                if (slot.place == place && slot.value.width == width)
                    return slot.value;
                entry = false;
                break;
            }
            const value = PathValue(nextIdentity++, width);
            if (!write(place, value, entry))
                return PathValue.init;
            return value;
        }

        PathValue current(PathPlace place, ubyte width) const {
            foreach_reverse (ref const slot; slots[0 .. count]) {
                if (!place.overlaps(slot.place, width, slot.value.width))
                    continue;
                if (slot.place == place && slot.value.width == width)
                    return slot.value;
                break;
            }
            return PathValue.init;
        }

        bool write(PathPlace place, PathValue value, bool entry = false) {
            if (count == slots.length)
                return false;
            slots[count++] = Slot(place, value, entry);
            return true;
        }

        bool entryPlace(PathValue value, out PathPlace place) const {
            if (!value.identity)
                return false;
            foreach (ref const slot; slots[0 .. count]) {
                if (slot.entry && slot.value.identity == value.identity) {
                    place = slot.place;
                    return true;
                }
            }
            return false;
        }
    }

    bool pathWindowFrame(const(CallSite)* site, in WindowArm arm,
        const(PathCall)[] calls, int parent, out int frame)
    {
        long offset = cast(long) site.windowDisp + arm.fast.frameOffset;
        if (parent >= 0) {
            const enclosing = calls[parent];
            offset += cast(long) enclosing.frameInWindow + enclosing.arm.fast.windowBase
                - enclosing.arm.fast.frameOffset;
        }
        if (offset < 0 || offset > int.max)
            return false;
        frame = cast(int) offset;
        return true;
    }

    bool pathPlace(size_t raw, const(PathCall)[] calls, int pending,
        out PathPlace place, uint width = 0)
    {
        const inWindow = (raw & indirectBit) != 0;
        if (inWindow && ((raw >> 32) & 0x7fff_ffff) != function_.windowSlot)
            return false;
        if (!inWindow && width && function_.windowSlot != size_t.max
                && raw < function_.windowSlot + size_t.sizeof
                && function_.windowSlot < raw + width)
            return false;
        long offset = inWindow ? cast(uint) raw : cast(long) raw;
        if (pending >= 0) {
            const call = calls[pending];
            offset += call.frameInWindow;
            if (inWindow)
                offset += cast(long) call.arm.fast.windowBase - call.arm.fast.frameOffset;
        }
        if (offset < 0 || offset > int.max)
            return false;
        place = PathPlace(cast(int) offset, inWindow || pending >= 0);
        return true;
    }

    private struct PathGuard {
        PathPlace place;
        PathValue entry;
        ulong required;
    }

    private struct PathGuards {
        @nogc nothrow:
        PathGuard[pathDepth] guards = void;
        size_t count;

        PathValue substitute(PathValue value, const ref PathValues values) const {
            PathPlace place;
            if (!count || !values.entryPlace(value, place))
                return value;
            foreach (ref const guard; guards[0 .. count])
                if (guard.place == place && guard.entry.width == value.width)
                    return PathValue(0, value.width, guard.required)
                        .shifted(value.bits);
            return value;
        }

        bool constrain(PathValue value, ulong bits, const ref PathValues values) {
            PathPlace place;
            if (!values.entryPlace(value, place))
                return true;
            const entry = PathValue(value.identity, value.width);
            const required = PathValue(0, value.width, bits).shifted(-value.bits).bits;
            foreach (ref const guard; guards[0 .. count])
                if (guard.entry == entry)
                    return guard.required == required;
            if (count == guards.length)
                return false;
            guards[count++] = PathGuard(place, entry, required);
            return true;
        }
    }

    bool constrainPath(in ObservedEdge step, in JitOp.Fused comparison,
        ref PathGuards guards, ref PathValues values,
        const(PathCall)[] calls, int pending)
    {
        const ins = snapshot[step.pc];
        if (!comparison.constantRight || !goodWidth(ins.width))
            return true;
        size_t target;
        if (!targetIndex(ins.sourceWidth, target))
            return false;
        const taken = step.next == target;
        const condition = taken == comparison.jumpWhen;
        if (!(condition && comparison.comparison == Comparison.equal)
                && !(!condition && comparison.comparison == Comparison.notEqual))
            return true;
        PathPlace place;
        if (!pathPlace(ins.destination, calls, pending, place, cast(uint) ins.width))
            return false;
        const width = cast(ubyte) ins.width;
        return guards.constrain(values.lookup(place, width),
            constantAt(ins.source, width), values);
    }

    private struct PathAddress {
        PathValue base;
        uint displacement;
        ubyte width;
    }

    bool pathAddressOf(size_t raw, ubyte width, ref PathValues values,
        const(PathCall)[] calls, int pending, out PathAddress address)
    {
        if (!(raw & indirectBit))
            return false;
        PathPlace base;
        const slot = (raw >> 32) & 0x7fff_ffff;
        if (!pathPlace(slot, calls, pending, base, size_t.sizeof))
            return false;
        const value = values.lookup(base, size_t.sizeof);
        const displacement = cast(uint) raw;
        if (!value.identity || value.bits || displacement > 0x7fff_0000)
            return false;
        address = PathAddress(value, displacement, width);
        return true;
    }

    bool trackPathCopy(in Instruction ins, in JitOp op,
        ref PathValues values, const(PathCall)[] calls, int pending,
        const ref PathGuards guards, PathCopy* copy)
    {
        const width = op.width ? op.width : ins.width;
        PathPlace dest, source;
        if (!goodWidth(width)
                || !pathPlace(ins.destination, calls, pending, dest, cast(uint) width))
            return false;
        if (isLiteralCopy(ins, op, width))
            return values.write(dest, PathValue(0, cast(ubyte) width,
                constantAt(ins.source, cast(int) width)));
        if (op.copy.staticSource)
            return values.write(dest, PathValue(values.nextIdentity++, cast(ubyte) width));
        if (!pathPlace(ins.source, calls, pending, source, cast(uint) width))
            return false;
        const value = values.lookup(source, cast(ubyte) width);
        if (!value.width)
            return false;
        if (copy !is null) {
            const forwarded = guards.substitute(value, values);
            const previous = values.current(dest, cast(ubyte) width);
            if (previous.width && guards.substitute(previous, values) == forwarded)
                copy.kind = PathCopy.Kind.redundant;
            else if (!forwarded.identity) {
                int immediate;
                if (immOf(cast(int) width, forwarded.bits, immediate))
                    *copy = PathCopy(PathCopy.Kind.immediate, immediate);
            }
        }
        return values.write(dest, value);
    }

    bool trackPathInteger(in Instruction ins, in JitOp op, ref PathMemory memory,
        ref PathValues values, const(PathCall)[] calls, int pending)
    {
        const arithmetic = op.int3;
        const w = op.width ? op.width : ins.width;
        if (!goodWidth(w) || !arithmetic.constantRight)
            return false;
        const width = cast(ubyte) w;
        const leftRaw = arithmetic.twoAddress ? ins.destination : ins.source;
        PathPlace dest, left;
        if (!pathPlace(ins.destination, calls, pending, dest, width)) {
            if (ins.destination != leftRaw)
                return false;
            PathAddress address;
            if (!pathAddressOf(ins.destination, width, values, calls, pending, address)
                    || !memory.noteScalar(address))
                return false;
            return true;
        }
        if (!pathPlace(leftRaw, calls, pending, left, width))
            return false;
        const prior = values.lookup(left, width);
        const right = constantAt(integerRightOperand(ins, arithmetic.twoAddress), width);
        if (!prior.width)
            return false;
        with (JitOp.IntOperation) final switch (arithmetic.operation) {
            case add:
                return values.write(dest, prior.shifted(right));
            case subtract:
                return values.write(dest, prior.shifted(-right));
            case multiply, and, or, xor:
                return values.write(dest, PathValue(values.nextIdentity++, width));
        }
    }

    private struct PathIndex {
        PathValue value;
        bool signed;
    }

    private struct PathElement {
        PathIndex index;
        PathValue value;
        PathPlace place;
        size_t operand = size_t.max;
    }

    private struct PathChecked {
        bool skipBounds;
        bool skipStore;
        size_t forwarded = size_t.max;
    }

    private struct PathMemory {
        PathAddress descriptor;
        PathAddress[ScalarFlow.Program.slotLimit] scalars;
        size_t scalarCount;
        PathPlace receiver;
        int width;
        int maximumIndex = -1;
        size_t first = size_t.max;
        size_t saved;

        bool noteScalar(in PathAddress address) @nogc nothrow {
            foreach (ref const scalar; scalars[0 .. scalarCount]) {
                if (scalar == address)
                    return true;
                if (scalar.base != address.base
                        || (scalar.displacement < cast(ulong) address.displacement + address.width
                            && address.displacement < cast(ulong) scalar.displacement + scalar.width))
                    return false;
            }
            if (scalarCount == scalars.length)
                return false;
            scalars[scalarCount++] = address;
            return true;
        }
    }

    private struct PathCopy {
        enum Kind : ubyte { normal, redundant, immediate }
        Kind kind;
        int immediate;
    }

    private struct PathAction {
        PathChecked checked;
        PathCopy copy;
    }

    private struct PathPlan {
        PathGuards guards;
        PathMemory memory;
        PathAction[ObservedEdge.limit] actions;
        bool repeating;
    }

    private struct PathMemoryFacts {
        PathIndex[ObservedEdge.limit] bounded = void;
        size_t checks;
        PathElement[ObservedEdge.limit] elements = void;
        size_t known;
    }

    private struct PathScratch {
        PathPlan best;
        PathPlan candidate;
        PathValues values;
        PathMemoryFacts facts;
        PathCall[ObservedEdge.limit] calls;
        PathExit[3 * ObservedEdge.limit + 16] exits;
        RecordedLoop recorded;
    }

    private struct RecordedLoop {
        @nogc nothrow:

        alias Program = ScalarFlow.Program;
        alias Operation = Program.Operation;
        alias Operand = Program.Operand;
        alias Mode = Program.Mode;
        alias Kind = Program.Kind;
        enum none = Program.none;

        Operand[2 * ObservedEdge.limit + 1] references;
        Operand[Program.slotLimit] scalar;
        Operation[Program.instructionLimit] conditions;
        bool[Program.instructionLimit] entryOnly;
        Operation[Program.slotLimit] snapshot;
        ScalarFlow.Set storedOnExit;
        size_t conditionCount;
        size_t snapshotCount;
        uint heatStep;
        size_t reach;
        Program* program;
        Operand length;
        Operand pointer;
        bool failed;

        ushort append(Operation step) {
            if (program.length == program.operations.length) {
                failed = true;
                return 0;
            }
            const pc = program.length++;
            if (step.kind != Kind.exit)
                step.next = cast(ushort) (pc + 1);
            program.operations[pc] = step;
            return pc;
        }

        Operand temp(ubyte width) {
            const id = program.newTemporary(width);
            failed |= id == none;
            return Operand(Mode.temporary, width, 0, id);
        }

        static Operand literal(ulong bits, ubyte width) {
            return Operand(Mode.literal, width, 0, bits);
        }

        static Operand home(in PathPlace place, ubyte width) {
            return Operand(Mode.frame, width, 0, cast(size_t) place.offset);
        }

        Operand locate(PathValue value, const ref PathValues values, bool preflight = false) {
            if (!value.identity)
                return literal(value.bits, value.width);
            auto operand = references[value.identity];
            if (preflight || operand.mode == Mode.unused) {
                PathPlace place;
                if (!values.entryPlace(value, place)) {
                    failed = true;
                    return Operand.init;
                }
                operand = home(place, value.width);
                references[value.identity] = operand;
            }
            if (!value.bits)
                return operand;
            const result = temp(value.width);
            const add = Operation(Kind.integer, JitOp.IntOperation.add,
                output: result, left: operand, right: literal(value.bits, value.width));
            if (preflight)
                condition(add);
            else
                append(add);
            return result;
        }

        void condition(in Operation test) {
            foreach (ref const earlier; conditions[0 .. conditionCount])
                if (earlier == test)
                    return;
            if (conditionCount == conditions.length) {
                failed = true;
                return;
            }
            conditions[conditionCount++] = test;
        }

        void findInvariants(scope const(Operation)[] body) {
            bool[Program.slotLimit] changes;
            bool varying(in Operand input) {
                if (input.mode == Mode.temporary)
                    return changes[input.word];
                if (input.mode != Mode.frame)
                    return false;
                foreach (ref const step; body) {
                    const output = step.output;
                    if (output.mode == Mode.frame && output.word < input.word + input.width
                            && input.word < output.word + output.width)
                        return true;
                }
                return false;
            }
            foreach (i, ref const step; conditions[0 .. conditionCount]) {
                const variant = varying(step.left) || varying(step.right);
                entryOnly[i] = !variant;
                if (step.output.mode == Mode.temporary)
                    changes[step.output.word] = variant;
            }
        }

        ushort checkedEntry(ushort body, ushort entry, size_t heatAddress, bool resume) {
            const first = program.length;
            foreach (i, ref const test; conditions[0 .. conditionCount])
                if (!resume || !entryOnly[i])
                    append(test);
            if (heatStep) {
                const heat = temp(size_t.sizeof);
                append(Operation(Kind.move, output: heat, left: literal(heatAddress, size_t.sizeof)));
                const prior = temp(uint.sizeof);
                const access = Operand(Mode.indirectTemporary, uint.sizeof, 0, heat.word);
                append(Operation(Kind.move, output: prior, left: access));
                append(Operation(Kind.branch, compareKind: CompareKind.unsigned,
                    comparison: Comparison.greaterThan, jumpWhen: true, left: prior,
                    right: literal(uint.max - heatStep, uint.sizeof)));
                const updated = temp(uint.sizeof);
                append(Operation(Kind.integer, JitOp.IntOperation.add,
                    output: updated, left: prior, right: literal(heatStep, uint.sizeof)));
                append(Operation(Kind.move, output: access, left: updated));
            }
            const jump = append(Operation(Kind.jump, target: body));
            const failure = program.length;
            if (resume)
                foreach (ref const store; snapshot[0 .. snapshotCount])
                    append(store);
            append(Operation(Kind.exit, bias: entry));
            if (failed)
                return first;
            foreach (ref step; program.operations[first .. jump])
                if (step.kind == Kind.branch)
                    step.target = failure;
            program.operations[jump].next = none;
            return first;
        }
    }

    bool emitRecordedLoop(const(ObservedEdge)[] path, const(JitOp)[] ops,
        const(Instruction.Handler)[] originals, ref PathScratch scratch,
        ref const PathPlan plan)
    {
        static if (!chainedDispatch)
            return false;
        if (scalarScratch is null || function_.frameSize >= RecordedLoop.Program.r0
                || function_.closureOffset != size_t.max || function_.exceptionHandlers.length)
            return false;
        auto flow = scalarScratch.reserve(1);
        auto emitter = scalarEmitterScratch.reserve(1);
        if (flow is null || emitter is null)
            return false;

        ref trace = scratch.recorded;
        trace = RecordedLoop.init;
        trace.program = &flow.ranges.program;
        trace.program.length = trace.program.slotCount = 0;
        trace.program.frameSize = cast(ushort) function_.frameSize;
        alias P = RecordedLoop;
        const receiver = P.home(plan.memory.receiver, size_t.sizeof);
        P.Operand receiverField(uint offset, ubyte width) {
            return P.Operand(P.Mode.indirect, width, offset, receiver.word);
        }
        const descriptor = plan.memory.descriptor.displacement;
        if (plan.memory.descriptor.width) {
            // The memory prefix can read the descriptor only after a branch
            // that can bypass its first access has been checked.
            foreach (edge; path[1 .. plan.memory.first])
                if (ops[edge.pc].kind == JitOp.Kind.fused)
                    return false;
            trace.length = trace.temp(size_t.sizeof);
            trace.pointer = trace.temp(size_t.sizeof);
            trace.append(P.Operation(P.Kind.move, output: trace.length,
                left: receiverField(cast(uint) (descriptor + arrayLengthOffset), size_t.sizeof)));
            trace.append(P.Operation(P.Kind.move, output: trace.pointer,
                left: receiverField(cast(uint) (descriptor + arrayPointerOffset), size_t.sizeof)));
        }
        const entryJump = trace.append(P.Operation(P.Kind.jump));
        const first = trace.program.length;
        foreach (i, ref const address; plan.memory.scalars[0 .. plan.memory.scalarCount]) {
            trace.scalar[i] = trace.temp(address.width);
            trace.append(P.Operation(P.Kind.move, output: trace.scalar[i],
                left: receiverField(address.displacement, address.width)));
        }
        const body = trace.program.length;
        if (!lowerRecordedIteration(path, ops, scratch, plan))
            return false;
        trace.findInvariants(trace.program.operations[body .. trace.program.length]);
        const firstBackedge = trace.append(P.Operation(P.Kind.jump));
        const repeat = trace.program.length;
        foreach (pc; body .. firstBackedge)
            trace.append(trace.program.operations[pc]);
        const repeatBackedge = trace.append(P.Operation(P.Kind.jump));
        const heat = cast(size_t) &function_.jitHeat;
        const entry = trace.checkedEntry(first, path[0].pc, heat, false);
        const reentry = trace.checkedEntry(repeat, path[0].pc, heat, true);
        if (trace.failed)
            return false;
        trace.program.operations[entryJump].next = entry;
        trace.program.operations[firstBackedge].next = reentry;
        trace.program.operations[repeatBackedge].next = reentry;
        if (!flow.prepareRecorded(trace.storedOnExit))
            return false;

        const start = a.n;
        const savedLiterals = literalCount;
        const savedFixups = fixupCount;
        bool published;
        scope (exit) if (!published) {
            a.n = start;
            literalCount = savedLiterals;
            fixupCount = savedFixups;
        }
        auto exits = scratch.exits[];
        size_t exitCount;
        if (codeLimit - a.n < maximumBytesPerInstruction + 128 * plan.memory.scalarCount)
            return false;
        known = KnownConstant.init;
        intSlots = IntSlots.init;
        fpSlots = FpSlots.init;
        const firstOp = ops[path[0].pc];
        const firstIns = snapshot[path[0].pc];
        size_t branchTarget, branchExit, branchJump;
        if (firstOp.kind != JitOp.Kind.fused || !targetIndex(firstIns.sourceWidth, branchTarget)
                || !emitFused(firstIns, firstOp.fused, branchTarget, 0, path[0].pc + 1,
                    path[0].next, &branchExit, &branchJump))
            return false;
        exits[exitCount++] = PathExit(path[0].pc, branchJump);
        foreach (ref const guard; plan.guards.guards[0 .. plan.guards.count]) {
            a.ld(guard.entry.width, RAX, Mem(FRAME, guard.place.offset));
            int immediate;
            if (immOf(guard.entry.width, guard.required, immediate))
                a.aluRI(Alu.cmp, guard.entry.width, RAX, immediate);
            else {
                a.movI(SC2, guard.required);
                a.aluRR(Alu.cmp, guard.entry.width, RAX, SC2);
            }
            exits[exitCount++] = PathExit(path[0].pc, jccLocal(CC_NE));
        }
        if (trace.reach) {
            a.ld(8, R9, Mem(STATE, DispatchState.frames.offsetof));
            a.ld(8, R10, Mem(FRAME, cast(int) function_.windowSlot));
            a.lea(RAX, Mem(R10, cast(int) trace.reach));
            a.alu(Alu.cmp, 8, RAX, Mem(R9, FrameStack.fastEndOffset));
            exits[exitCount++] = PathExit(path[0].pc, jccLocal(CC_A));
        }
        if (plan.memory.descriptor.width)
            guardPathMemory(plan.memory, path[0].pc, -1, exits, exitCount);
        else if (plan.memory.scalarCount) {
            a.ld(8, R9, Mem(STATE, DispatchState.frames.offsetof));
            foreach (ref const scalar; plan.memory.scalars[0 .. plan.memory.scalarCount]) {
                a.ld(8, R10, Mem(FRAME, plan.memory.receiver.offset));
                a.aluRI(Alu.add, 8, R10, cast(int) scalar.displacement);
                exits[exitCount++] = PathExit(path[0].pc, jccLocal(CC_B));
                a.movRR64(SC2, R10);
                a.aluRI(Alu.add, 8, SC2, scalar.width);
                exits[exitCount++] = PathExit(path[0].pc, jccLocal(CC_B));
                guardPathStack(path[0].pc, -1, exits, exitCount, R10, SC2);
            }
        }

        *emitter = ScalarEmitter.init;
        emitter.gen = &this;
        emitter.flow = flow;
        emitter.originals = originals;
        emitter.recordedEntry = path[0].pc;
        if (!emitter.emit || codeLimit - a.n < handlerJumpBytes)
            return false;
        foreach (exit; exits[0 .. exitCount])
            patchHere(exit.firstJump);
        jumpToHandler(path[0].pc, originals[path[0].pc]);
        published = true;
        return true;
    }

    bool lowerRecordedIteration(const(ObservedEdge)[] path, const(JitOp)[] ops,
        ref PathScratch scratch, ref const PathPlan plan)
    {
        import std.algorithm.comparison: max;

        alias P = RecordedLoop;
        ref trace = scratch.recorded;
        ref values = scratch.values;
        values.count = 0;
        values.nextIdentity = 1;
        ref facts = scratch.facts;
        facts.checks = facts.known = 0;
        ref analysis = scratch.candidate;
        analysis.memory = PathMemory.init;
        analysis.guards = plan.guards;
        analysis.actions[0 .. path.length] = PathAction.init;
        PathCall[pathDepth] frames = void;
        int pending = -1;
        ulong[ScalarFlow.Program.slotLimit] effects;
        foreach (position, edge; path) {
            const ins = snapshot[edge.pc];
            const op = ops[edge.pc];
            const calls = frames[0 .. pending + 1];
            with (JitOp.Kind) switch (op.kind) {
            case callWindow: {
                const arm = observedWindow(function_, edge.pc, op.callWindow);
                const site = &callSites[ins.source];
                int child;
                if (!pathWindowFrame(site, arm, calls, pending, child))
                    return false;
                const reach = cast(size_t) child - arm.fast.frameOffset + arm.fast.reachBytes;
                if (reach > int.max)
                    return false;
                trace.reach = max(trace.reach, reach);
                if (op.callWindow.counted) {
                    trace.heatStep += jitStep;
                    if (trace.heatStep < jitStep)
                        return false;
                }
                const parent = pending++;
                frames[pending] = PathCall(edge.pc, parent, arm, child);
                break;
            }
            case returnVoid:
                --pending;
                break;
            case jump:
                break;
            case copy:
                if (!trackPathCopy(ins, op, values, calls, pending, plan.guards, null))
                    return false;
                break;
            case int3: {
                const width = cast(ubyte) (op.width ? op.width : ins.width);
                PathPlace dest;
                if (pathPlace(ins.destination, calls, pending, dest, width)) {
                    if (op.int3.operation != JitOp.IntOperation.add
                            && op.int3.operation != JitOp.IntOperation.subtract)
                        return false;
                    if (!trackPathInteger(ins, op, analysis.memory, values, calls, pending))
                        return false;
                    break;
                }
                PathAddress address;
                if (!pathAddressOf(ins.destination, width, values, calls, pending, address))
                    return false;
                PathPlace receiver;
                if (!values.entryPlace(address.base, receiver) || receiver != plan.memory.receiver)
                    return false;
                bool found;
                foreach (i, ref const scalar; plan.memory.scalars[0 .. plan.memory.scalarCount]) {
                    if (scalar.displacement != address.displacement || scalar.width != address.width)
                        continue;
                    const right = constantAt(integerRightOperand(ins, op.int3.twoAddress), width);
                    if (op.int3.operation == JitOp.IntOperation.add)
                        effects[i] += right;
                    else if (op.int3.operation == JitOp.IntOperation.subtract)
                        effects[i] -= right;
                    else
                        return false;
                    found = true;
                    break;
                }
                if (!found)
                    return false;
                break;
            }
            case fused:
                if (!recordedCondition(edge, ins, op.fused, calls, pending, values, plan.guards, trace))
                    return false;
                break;
            case checked:
                if (!trackPathChecked(position, ins, op, values, calls, pending,
                        analysis, facts, false)
                        || !recordedArray(ins, op, calls, pending, values, facts,
                            analysis.actions[position].checked, plan.memory.maximumIndex,
                            plan.guards, trace))
                    return false;
                break;
            default:
                return false;
            }
        }

        foreach (ref const guard; plan.guards.guards[0 .. plan.guards.count]) {
            const finalValue = plan.guards.substitute(
                values.current(guard.place, guard.entry.width), values);
            if (finalValue != PathValue(0, guard.entry.width, guard.required))
                return false;
        }

        // A successful lap has returned all logical calls. Subsequent
        // interpreter entry needs the actual caller slots.
        const slots = values.slots[0 .. values.count];
        foreach (ref const slot; slots) {
            if (!slot.entry || slot.value == values.current(slot.place, slot.value.width)
                    || !plan.guards.substitute(slot.value, values).identity)
                continue;
            const variable = P.home(slot.place, slot.value.width);
            const saved = trace.temp(slot.value.width);
            trace.append(P.Operation(P.Kind.move, output: saved, left: variable));
            trace.references[slot.value.identity] = saved;
        }
        foreach (i, ref const slot; slots) {
            if (slot.place.window || slot.entry)
                continue;
            bool overwritten;
            foreach (ref const later; slots[i + 1 .. $]) {
                if (!slot.place.overlaps(later.place, slot.value.width, later.value.width))
                    continue;
                if (slot.place != later.place || slot.value.width != later.value.width)
                    return false;
                overwritten = true;
                break;
            }
            if (overwritten)
                continue;
            const home = P.home(slot.place, slot.value.width);
            const value = trace.locate(plan.guards.substitute(slot.value, values), values);
            const store = P.Operation(P.Kind.move, output: home, left: value);
            bool loopInput;
            bool overlapsInput;
            foreach (ref const read; slots[0 .. i]) {
                loopInput |= read.entry && read.place == slot.place && read.value.width == slot.value.width;
                overlapsInput |= read.entry
                    && read.place.overlaps(slot.place, read.value.width, slot.value.width);
            }
            if (loopInput) {
                trace.append(store);
            } else {
                const canonical = trace.program.slotOf(home);
                if (canonical == P.none || trace.snapshotCount == trace.snapshot.length)
                    return false;
                trace.storedOnExit.add(canonical);
                trace.snapshot[trace.snapshotCount++] = store;
                if (value.mode == P.Mode.temporary && !overlapsInput && value.width == home.width) {
                    ref spill = trace.program.slots[value.word];
                    if (!spill.spillHome) {
                        spill.offset = cast(ushort) home.word;
                        spill.spillHome = true;
                    }
                }
            }
        }
        foreach (i, ref const scalar; plan.memory.scalars[0 .. plan.memory.scalarCount]) {
            const delta = PathValue(0, scalar.width).shifted(effects[i]).bits;
            if (!delta)
                continue;
            const value = trace.scalar[i];
            trace.append(P.Operation(P.Kind.integer, JitOp.IntOperation.add,
                output: value, left: value, right: P.literal(delta, scalar.width)));
            trace.append(P.Operation(P.Kind.move,
                output: P.Operand(P.Mode.indirect, scalar.width, scalar.displacement,
                    cast(size_t) plan.memory.receiver.offset), left: value));
        }
        return !trace.failed;
    }

    bool recordedCondition(in ObservedEdge edge, in Instruction ins, in JitOp.Fused op,
        const(PathCall)[] calls, int pending, ref PathValues values, ref const PathGuards guards,
        ref RecordedLoop trace)
    {
        alias P = RecordedLoop;
        PathPlace leftPlace, rightPlace;
        size_t target;
        const width = cast(ubyte) ins.width;
        if (!targetIndex(ins.sourceWidth, target)
                || !pathPlace(ins.destination, calls, pending, leftPlace, width)
                || !op.constantRight && !pathPlace(ins.source, calls, pending, rightPlace, width))
            return false;
        const left = guards.substitute(values.lookup(leftPlace, width), values);
        const right = op.constantRight ? PathValue(0, width, constantAt(ins.source, width))
            : guards.substitute(values.lookup(rightPlace, width), values);
        if (!left.width || !right.width)
            return false;
        const satisfies = (edge.next == target) == op.jumpWhen;
        if (!left.identity && !right.identity)
            return ScalarFlow.Ranges.testComparison(left.bits, right.bits, width,
                op.comparison, op.kind) == satisfies;

        trace.condition(P.Operation(P.Kind.branch, compareKind: op.kind,
            comparison: op.comparison, jumpWhen: !satisfies,
            left: trace.locate(left, values, true), right: trace.locate(right, values, true)));
        return !trace.failed;
    }

    bool recordedArray(in Instruction ins, in JitOp op, const(PathCall)[] calls, int pending,
        ref PathValues values, ref const PathMemoryFacts facts, in PathChecked action,
        int maximumIndex, ref const PathGuards guards, ref RecordedLoop trace)
    {
        alias P = RecordedLoop;
        alias Access = CheckedAccess;
        const checked = op.checked;
        PathPlace indexPlace;
        if (!pathPlace(cast(uint) ins.width, calls, pending, indexPlace, checked.indexWidth))
            return false;
        const index = guards.substitute(values.lookup(indexPlace, checked.indexWidth)
            .shifted(cast(long) cast(int) (ins.width >> 32)), values);
        if (checked.access == Access.storeUnchecked) {
            bool bounded = !index.identity && maximumIndex >= 0 && index.bits <= maximumIndex;
            if (index.identity)
                foreach (ref const bound; facts.bounded[0 .. facts.checks])
                    bounded |= bound.value == index && bound.signed == checked.signed;
            if (!bounded)
                return false;
        }
        if (index.identity && !action.skipBounds && checked.access != Access.storeUnchecked) {
            auto preflight = trace.locate(index, values, true);
            if (index.width == int.sizeof && checked.signed)
                trace.condition(P.Operation(P.Kind.branch, compareKind: CompareKind.signed,
                    comparison: Comparison.lessThan, jumpWhen: true, left: preflight,
                    right: P.literal(0, int.sizeof)));
            if (preflight.mode == P.Mode.frame && index.width < size_t.sizeof) {
                const narrow = trace.temp(index.width);
                trace.condition(P.Operation(P.Kind.move, output: narrow, left: preflight));
                preflight = narrow;
            }
            preflight.width = size_t.sizeof;
            trace.condition(P.Operation(P.Kind.branch, compareKind: CompareKind.unsigned,
                comparison: Comparison.greaterOrEqual, jumpWhen: true,
                left: preflight, right: trace.length));
        }
        if (checked.access == Access.check || action.skipStore)
            return !trace.failed;
        PathPlace place;
        if (!checked.constantValue && !pathPlace(ins.destination, calls, pending, place, op.width))
            return false;
        const load = checked.access == Access.load;
        const value = checked.constantValue ? PathValue(0, op.width, constantAt(ins.destination, op.width))
            : guards.substitute(values.current(place, op.width), values);
        if (!value.width)
            return false;
        if (load && value.identity != values.nextIdentity - 1)
            return true;
        const operand = load ? trace.temp(op.width) : trace.locate(value, values);
        if (load)
            trace.references[value.identity] = operand;
        if (!index.identity) {
            const offset = index.bits * op.width;
            if (offset > int.max)
                return false;
            const memory = P.Operand(P.Mode.indirectTemporary, op.width, cast(uint) offset,
                trace.pointer.word);
            trace.append(P.Operation(P.Kind.move, output: load ? operand : memory,
                left: load ? memory : operand));
        } else {
            trace.append(P.Operation(load ? P.Kind.arrayLoad : P.Kind.arrayStore,
                stride: op.width, output: load ? operand : P.Operand.init,
                left: trace.locate(index, values), right: load ? P.Operand.init : operand,
                slice: trace.pointer));
        }
        return !trace.failed;
    }

    bool trackPathChecked(size_t position, in Instruction ins, in JitOp op,
        ref PathValues values, const(PathCall)[] calls, int pending,
        ref PathPlan plan, ref PathMemoryFacts facts, bool gatherGuards)
    {
        const p = op.checked;
        auto memory = &plan.memory;
        const check = p.access == CheckedAccess.check;
        PathAddress descriptor;
        enum descriptorBytes = arrayPointerOffset + size_t.sizeof;
        if (p.sharedAccess || p.fixedLength
                || !pathAddressOf(ins.source, descriptorBytes, values, calls, pending,
                    descriptor)
                || (memory.descriptor.width && memory.descriptor != descriptor))
            return false;
        memory.descriptor = descriptor;
        if (!check) {
            if (memory.width && memory.width != op.width)
                return false;
            memory.width = op.width;
        }
        if (memory.first == size_t.max) {
            if (p.access == CheckedAccess.storeUnchecked || pending >= 0
                    || !values.entryPlace(descriptor.base, memory.receiver)
                    || values.current(memory.receiver, size_t.sizeof) != descriptor.base)
                return false;
            memory.first = position;
        }
        PathPlace indexPlace;
        if (!pathPlace(cast(uint) ins.width, calls, pending, indexPlace, p.indexWidth))
            return false;
        auto index = values.lookup(indexPlace, p.indexWidth);
        if (!index.width)
            return false;
        index = index.shifted(cast(long) cast(int) (ins.width >> 32));
        if (!gatherGuards)
            index = plan.guards.substitute(index, values);
        if (!index.identity)
            index = PathValue(0, size_t.sizeof, p.signed && index.width == int.sizeof
                ? cast(ulong) cast(long) cast(int) index.bits : index.bits);
        const location = PathIndex(index, index.identity && p.signed);
        auto action = &plan.actions[position].checked;
        if (!gatherGuards && p.access != CheckedAccess.storeUnchecked) {
            if (!index.identity) {
                const extended = index.bits;
                if (extended > int.max)
                    return false;
                const boundedIndex = cast(int) extended;
                if (boundedIndex > memory.maximumIndex)
                    memory.maximumIndex = boundedIndex;
                action.skipBounds = true;
            } else {
                foreach (ref const earlier; facts.bounded[0 .. facts.checks])
                    if (earlier == location) {
                        action.skipBounds = true;
                        break;
                    }
                if (!action.skipBounds)
                    facts.bounded[facts.checks++] = location;
            }
            if (action.skipBounds)
                memory.saved += 3;
        }
        if (check)
            return true;
        PathPlace valuePlace;
        if (!p.constantValue
                && !pathPlace(ins.destination, calls, pending, valuePlace, op.width))
            return false;
        PathElement* previous;
        if (!gatherGuards)
            foreach (ref earlier; facts.elements[0 .. facts.known])
                if (earlier.index == location) {
                    previous = &earlier;
                    break;
                }
        if (p.access == CheckedAccess.load) {
            const fresh = PathValue(values.nextIdentity++, op.width);
            const value = previous is null ? fresh : previous.value;
            if (previous !is null && previous.operand != size_t.max) {
                PathPlace readable;
                if (pathPlace(previous.operand, calls, pending, readable, op.width)
                        && readable == previous.place
                        && values.current(readable, op.width) == value) {
                    action.forwarded = previous.operand;
                    memory.saved += 2;
                }
            }
            if (!gatherGuards) {
                const replacement = PathElement(location, value,
                    valuePlace, ins.destination);
                if (previous is null)
                    facts.elements[facts.known++] = replacement;
                else
                    *previous = replacement;
            }
            return values.write(valuePlace, value);
        }
        const value = p.constantValue
            ? PathValue(0, op.width, constantAt(ins.destination, op.width))
            : values.lookup(valuePlace, op.width);
        if (!value.width)
            return false;
        if (gatherGuards)
            return true;
        if (previous !is null && previous.value == value) {
            action.skipStore = true;
            memory.saved += 3;
        } else {
            size_t preserved;
            foreach (ref const earlier; facts.elements[0 .. facts.known])
                if (!earlier.index.value.identity && !index.identity
                        && earlier.index.value.bits != index.bits)
                    facts.elements[preserved++] = earlier;
            facts.known = preserved;
            facts.elements[facts.known++] = PathElement(location, value);
        }
        return true;
    }

    bool analyzePath(const(ObservedEdge)[] edges, const(JitOp)[] ops,
        ref PathScratch scratch, bool gatherGuards)
    {
        ref plan = scratch.candidate;
        ref values = scratch.values;
        values.count = 0;
        values.nextIdentity = 1;
        ref facts = scratch.facts;
        facts.checks = 0;
        facts.known = 0;
        PathCall[pathDepth] frames = void;
        int pending = -1;
        PathGuards ignored;
        foreach (position, ref const step; edges) {
            const op = ops[step.pc];
            ref const ins = snapshot[step.pc];
            const calls = frames[0 .. pending + 1];
            with (JitOp.Kind) switch (op.kind) {
                case callWindow:
                    if (pending + 1 == pathDepth)
                        return false;
                    const arm = observedWindow(function_, step.pc, op.callWindow);
                    int child;
                    if (!arm.callee || arm.adjustment || arm.hasPlace || !arm.hasWindows
                            || arm.fast.windowStore != function_.windowSlot
                            || !pathWindowFrame(&callSites[ins.source], arm, calls,
                                pending, child))
                        return false;
                    frames[pending + 1] = PathCall(step.pc, pending, arm, child);
                    ++pending;
                    break;
                case returnVoid:
                    if (pending < 0)
                        return false;
                    --pending;
                    break;
                case jump:
                    break;
                case copy:
                    if (!trackPathCopy(ins, op, values, calls, pending, plan.guards,
                            gatherGuards ? null : &plan.actions[position].copy))
                        return false;
                    break;
                case int3:
                    if (!trackPathInteger(ins, op, plan.memory, values, calls, pending))
                        return false;
                    break;
                case fused:
                    if (!constrainPath(step, op.fused, gatherGuards ? plan.guards : ignored,
                            values, calls, pending))
                        return false;
                    break;
                case checked:
                    if (!trackPathChecked(position, ins, op, values, calls, pending,
                            plan, facts, gatherGuards))
                        return false;
                    break;
                default:
                    return false;
            }
        }
        auto memory = &plan.memory;
        if (pending >= 0)
            return false;
        if (!memory.descriptor.width) {
            if (!memory.scalarCount)
                return true;
            const base = memory.scalars[0].base;
            return values.entryPlace(base, memory.receiver)
                && values.current(memory.receiver, size_t.sizeof) == base;
        }
        if (memory.width == 0
                || values.current(memory.receiver, size_t.sizeof) != memory.descriptor.base)
            return false;
        foreach (ref const scalar; memory.scalars[0 .. memory.scalarCount]) {
            const descriptor = memory.descriptor;
            if (scalar.base != descriptor.base
                    || (scalar.displacement < cast(ulong) descriptor.displacement + descriptor.width
                        && descriptor.displacement < cast(ulong) scalar.displacement + scalar.width))
                return false;
        }
        return true;
    }

    private struct PathExit {
        size_t target;
        size_t firstJump;
        size_t secondJump;
        int call = -1;
    }

    private enum pathLength = FpSlots.firstRegister + 1;
    private enum pathPointer = FpSlots.firstRegister + 2;

    void guardPathMemory(in PathMemory memory, size_t pc, int pending,
        PathExit[] exits, ref size_t count)
    {
        a.ld(8, R10, Mem(FRAME, memory.receiver.offset));
        a.aluRI(Alu.add, 8, R10, cast(int) memory.descriptor.displacement);
        exits[count++] = PathExit(pc, jccLocal(CC_B), 0, pending);
        a.movRR64(R11, R10);
        a.aluRI(Alu.add, 8, R11, memory.descriptor.width);
        exits[count++] = PathExit(pc, jccLocal(CC_B), 0, pending);
        a.ld(8, R9, Mem(STATE, DispatchState.frames.offsetof));
        guardPathStack(pc, pending, exits, count, R10, R11);

        // The range includes the index of the first load, so a failing load
        // can resume before it reads the pointer field.
        a.ld(8, RAX, Mem(R10, arrayLengthOffset));
        a.aluRI(Alu.cmp, 8, RAX, memory.maximumIndex);
        exits[count++] = PathExit(pc, jccLocal(CC_BE), 0, pending);
        a.integerToXmm(pathLength, RAX);
        a.ld(8, R11, Mem(R10, arrayPointerOffset));
        a.integerToXmm(pathPointer, R11);
        a.movI(SC2, size_t.max / memory.width);
        a.aluRR(Alu.cmp, 8, RAX, SC2);
        exits[count++] = PathExit(pc, jccLocal(CC_A), 0, pending);
        a.lea(RAX, Mem(R11, 0, RAX, cast(ubyte) memory.width));
        a.aluRR(Alu.cmp, 8, RAX, R11);
        exits[count++] = PathExit(pc, jccLocal(CC_B), 0, pending);
        guardPathStack(pc, pending, exits, count, R11, RAX);
        guardPathOverlap(pc, pending, exits, count, memory.descriptor.width);
        foreach (index, ref const scalar; memory.scalars[0 .. memory.scalarCount]) {
            const delta = cast(int) (scalar.displacement
                - memory.descriptor.displacement);
            a.aluRI(delta < 0 ? Alu.sub : Alu.add, 8, R10, delta < 0 ? -delta : delta);
            exits[count++] = PathExit(pc, jccLocal(CC_B), 0, pending);
            guardPathOverlap(pc, pending, exits, count, scalar.width);
            guardPathStack(pc, pending, exits, count, R10, SC2);
            if (index + 1 < memory.scalarCount) {
                a.ld(8, R10, Mem(FRAME, memory.receiver.offset));
                a.aluRI(Alu.add, 8, R10, cast(int) memory.descriptor.displacement);
            }
        }
    }

    void guardPathStack(size_t pc, int pending, PathExit[] exits,
        ref size_t count, int low, int high)
    {
        a.alu(Alu.cmp, 8, low, Mem(R9, FrameStack.fastEndOffset));
        const past = jccLocal(CC_AE);
        a.alu(Alu.cmp, 8, high, Mem(R9, FrameStack.baseOffset));
        exits[count++] = PathExit(pc, jccLocal(CC_A), 0, pending);
        patchHere(past);
    }

    void guardPathOverlap(size_t pc, int pending, PathExit[] exits,
        ref size_t count, int width)
    {
        a.movRR64(SC2, R10);
        a.aluRI(Alu.add, 8, SC2, width);
        exits[count++] = PathExit(pc, jccLocal(CC_B), 0, pending);
        a.aluRR(Alu.cmp, 8, RAX, R10);
        const before = jccLocal(CC_BE);
        a.aluRR(Alu.cmp, 8, R11, SC2);
        exits[count++] = PathExit(pc, jccLocal(CC_B), 0, pending);
        patchHere(before);
    }

    bool emitObservedPath(size_t cap, const(Function)* function_,
        const(ObservedEdge)[] path, const(JitOp)[] ops,
        const(Instruction.Handler)[] originals,
        ref PathScratch scratch, const(PathPlan)* plan)
    {
        auto calls = scratch.calls[0 .. path.length];
        auto exits = scratch.exits[0 .. 3 * path.length + 16];
        size_t callCount;
        size_t exitCount;
        int pending = -1;
        size_t continuation;
        emittingPath = transferPathValues && plan is null;
        scope (exit) emittingPath = false;
        known = KnownConstant.init;
        fpSlots = FpSlots.init;
        intSlots = IntSlots.init;
        const entry = a.n;
        if (plan !is null)
            foreach (ref const guard; plan.guards.guards[0 .. plan.guards.count]) {
                const width = guard.entry.width;
                if (cap - a.n < maximumBytesPerInstruction)
                    return false;
                a.ld(width, RAX, Mem(FRAME, guard.place.offset));
                int immediate;
                if (immOf(width, guard.required, immediate))
                    a.aluRI(Alu.cmp, width, RAX, immediate);
                else {
                    a.movI(SC2, guard.required);
                    a.aluRR(Alu.cmp, width, RAX, SC2);
                }
                exits[exitCount++] = PathExit(path[0].pc, jccLocal(CC_NE));
            }
        foreach (position, step; path) {
            if (cap - a.n < maximumBytesPerInstruction)
                return false;
            const i = step.pc;
            const op = ops[i];
            pathMemoryGuard = 0;
            // The path's copy cache survives only consecutive scalar copies.
            // Other instructions can change the frame or clobber its registers.
            const carryCopy = plan !is null && isScalarCopy(i, op);
            if (!carryCopy)
                intSlots = IntSlots.init;
            ref const ins = snapshot[i];
            with (JitOp.Kind) switch (op.kind) {
                case callWindow: {
                    auto arm = observedWindow(function_, i, op.callWindow);
                    if (arm.callee is null)
                        return false;
                    const site = &callSites[ins.source];
                    loadWindow(site);
                    guardWindow(op.callWindow, arm);
                    exits[exitCount++] = PathExit(i, arm.grow, arm.tierUp, pending);
                    setWindowFrame(arm);
                    retainedAcrossCall = retainedWidth != 0;
                    calls[callCount] = PathCall(i, pending, arm);
                    pending = cast(int) callCount++;
                    break;
                }
                case returnVoid: {
                    const call = calls[pending];
                    pending = call.parent;
                    continuation = call.pc + 1;
                    if (pending < 0)
                        a.ld(8, FRAME, Mem(ACTIVE, Activation.frame.offsetof));
                    else {
                        const parent = calls[pending].arm.fast;
                        const child = call.arm.fast;
                        const site = &callSites[snapshot[call.pc].source];
                        const delta = cast(long) parent.windowBase
                            + cast(long) site.windowDisp
                            + cast(long) child.frameOffset
                            - cast(long) parent.frameOffset;
                        if (delta > int.max || delta < -int.max)
                            return false;
                        a.lea(FRAME, Mem(FRAME, -cast(int) delta));
                    }
                    retainedAcrossCall = retainedWidth != 0;
                    break;
                }
                case jump: {
                    size_t target;
                    if (!targetIndex(ins.destination, target) || step.next != target)
                        return false;
                    break;
                }
                case fused: {
                    size_t target, exit;
                    size_t jump;
                    if (!targetIndex(ins.sourceWidth, target)
                            || !emitFused(ins, op.fused, target,
                                0, i + 1, step.next, &exit, &jump))
                        return false;
                    exits[exitCount++] = PathExit(exit, jump, 0, pending);
                    break;
                }
                case checked: {
                    size_t jump;
                    if (op.checked.access == CheckedAccess.load
                            && !pathFrameStorage(ins.destination, function_.windowSlot))
                        forgetPathValue;
                    if (plan !is null && position == plan.memory.first) {
                        if (pending >= 0)
                            return false;
                        guardPathMemory(plan.memory, i, pending, exits[], exitCount);
                    }
                    if (!emitChecked(i, ins, op, step.next, &jump, null,
                            plan is null ? null : &plan.actions[position].checked))
                        return false;
                    if (jump != 0)
                        exits[exitCount++] = PathExit(i + 1, jump, 0, pending);
                    break;
                }
                case copy:
                    if (!pathFrameStorage(ins.destination, function_.windowSlot))
                        forgetPathValue;
                    if (step.next != i + 1)
                        return false;
                    if (carryCopy) {
                        const copy = plan.actions[position].copy;
                        final switch (copy.kind) with (PathCopy.Kind) {
                            case redundant:
                                break;
                            case immediate: {
                                Mem destination;
                                if (!opnd(ins.destination, R9, destination))
                                    return false;
                                const width = cast(int) (op.width ? op.width : ins.width);
                                a.stI(width, destination, copy.immediate);
                                finishCopy(destination, width, true);
                                break;
                            }
                            case normal:
                                if (!emitTemplate(i, ops, op, originals[i],
                                        copyRun: true, carryCopy: true))
                                    return false;
                                break;
                        }
                    } else if (!emitTemplate(i, ops, op, originals[i]))
                        return false;
                    break;
                case int3:
                    if (step.next != i + 1 || !emitTemplate(i, ops, op, originals[i]))
                        return false;
                    break;
                default:
                    return false;
            }
            if (pathMemoryGuard != 0)
                exits[exitCount++] = PathExit(i, pathMemoryGuard, 0, pending);
        }
        if (cap - a.n < maximumBytesPerInstruction || pending >= 0
                || (emittingPath && !reusedAcrossCall))
            return false;
        if (plan is null)
            jumpToPathExit(continuation);
        else {
            a.b(0xE9);
            const back = a.n;
            a.d32(0);
            patchTo(back, entry);
        }
        foreach (exit; exits[0 .. exitCount]) {
            if (cap - a.n < maximumBytesPerInstruction * pathDepth)
                return false;
            patchHere(exit.firstJump);
            if (exit.secondJump)
                patchHere(exit.secondJump);
            if (!restorePathFrames(calls[0 .. callCount], exit.call, ops))
                return false;
            if (exit.target == path[0].pc)
                jumpToHandler(exit.target, originals[exit.target]);
            else
                jumpToPathExit(exit.target);
        }
        return true;
    }

    void jumpToPathExit(size_t i) {
        if (i >= instructions.length) {
            a.ud2();
            return;
        }
        jumpToLive(&instructions[i]);
    }

    static bool pathFrameStorage(size_t raw, size_t windowSlot) pure @safe {
        return !(raw & indirectBit)
            || ((raw >> 32) & 0x7fff_ffff) == windowSlot;
    }

    void forgetPathValue() {
        retainedWidth = 0;
        retainedAcrossCall = false;
    }

    bool restorePathFrames(const(PathCall)[] calls, int pending, const(JitOp)[] ops) {
        if (pending < 0)
            return true;

        a.ld(8, FRAME, Mem(ACTIVE, Activation.frame.offsetof));
        int[pathDepth] chain = void;
        size_t count;
        for (; pending >= 0; pending = calls[pending].parent)
            chain[count++] = pending;
        foreach_reverse (member; chain[0 .. count]) {
            const call = &calls[member];
            const site = &callSites[snapshot[call.pc].source];
            loadWindow(site);
            if (!prepareWindow(snapshot[call.pc], ops[call.pc].callWindow,
                    site, call.arm))
                return false;
            activateWindow(&instructions[call.pc], call.arm.callee,
                call.arm.fast);
        }
        return true;
    }

    void jumpToLive(const(Instruction)* pc) {
        a.movI(PCREG, cast(size_t) pc);
        a.st(8, Mem(ACTIVE, Activation.pc.offsetof), PCREG);
        a.jmpM(Mem(PCREG, Instruction.handler.offsetof));
    }


    private enum inlineInstructionLimit = 100;
    private enum inlineDepthLimit = 3;
    private enum inlineCodeLimit = 8 * 1024;

    bool hasCheckedAccess(const(JitOp)[] ops) const {
        if (ops.length > ScalarFlow.Program.instructionLimit)
            return false;
        foreach (ref const op; ops)
            if (ScalarFlow.Program.supportsChecked(op))
                return true;
        return false;
    }

    bool emitScalarEntry(const(JitOp)[] ops,
        const(Instruction.Handler)[] originals, ref bool inlineReturn, bool versionSlices,
        size_t entry = 0)
    {
        static if (!chainedDispatch)
            return false;
        if (scalarScratch is null)
            return false;
        auto flow = scalarScratch.reserve(1);
        if (flow is null
                || !flow.prepare(function_, snapshot, ops, cast(ushort) entry, versionSlices, bmi2))
            return false;

        // A guard miss continues into the ordinary template for this PC.
        const limit = codeLimit;
        scope (exit) codeLimit = limit;
        if (entry)
            codeLimit -= maximumBytesPerInstruction;

        const start = a.n;
        const savedFixups = fixupCount;
        const savedLiterals = literalCount;
        auto emitter = scalarEmitterScratch.reserve(1);
        if (emitter is null)
            return false;
        *emitter = ScalarEmitter.init;
        emitter.gen = &this;
        emitter.flow = flow;
        emitter.originals = originals;
        if (!emitter.emit) {
            a.n = start;
            fixupCount = savedFixups;
            literalCount = savedLiterals;
            return false;
        }
        inlineReturn |= emitter.inlineReturn;
        return true;
    }

    bool emitWindowBody(size_t i, in Instruction ins, in JitOp.CallWindow op,
        const(CallSite)* site, ref WindowArm arm)
    {
        import snakebite.backends.bytecode.vm: readJitBody;

        const callee = arm.callee;
        const n = callee.instructions.length;
        if (inlineBodies is null || callee.jit !is function_.jit
                || inlineDepth >= inlineDepthLimit
                || n == 0 || n > inlineInstructionLimit)
            return false;
        for (const(Gen)* ancestor = &this; ancestor !is null;
                ancestor = ancestor.inlineCaller)
            if (ancestor.function_ is callee)
                return false;
        if (codeLimit - a.n < maximumBytesPerInstruction)
            return false;

        auto level = &inlineBodies[inlineDepth];
        auto body = level.instructions[0 .. n];
        auto ops = level.ops[0 .. n];
        auto originals = level.originals[0 .. n];
        if (!readJitBody(callee, body, ops, originals))
            return false;

        const start = a.n;
        emitWindowChecks(op, site, arm);
        a.st(8, Mem(R11, Activation.parent.offsetof), FRAME);
        if (!prepareWindow(ins, op, site, arm)) {
            a.n = start;
            return false;
        }

        auto child = &level.gen;
        *child = Gen.init;
        child.a = a;
        child.codeLimit = codeLimit - maximumBytesPerInstruction;
        if (child.codeLimit > start + inlineCodeLimit)
            child.codeLimit = start + inlineCodeLimit;
        child.fixupScratch = fixupScratch;
        child.fixups = fixups;
        child.fixupCap = fixupCap;
        child.fixupCount = fixupCount;
        child.literalScratch = literalScratch;
        child.scalarScratch = scalarScratch;
        child.scalarEmitterScratch = scalarEmitterScratch;
        child.inlineBodies = inlineBodies;
        child.literalCount = literalCount;
        child.bmi2 = bmi2;
        child.function_ = callee;
        child.instructions = callee.instructions;
        child.snapshot = body;
        child.frameSize = callee.frameSize;
        child.constants = callee.constants;
        child.callSites = callee.callSites;
        child.inlineCaller = &this;
        child.inlineSite = site;
        child.inlineLayout = arm.fast;
        child.inlineCall = i;
        child.inlineDepth = inlineDepth + 1;
        child.expandWindows = true;
        child.watchedCall = watchCalleeCall;
        child.inlineResultMayBeNull = op.destination == Destination.indirect;
        child.labels = level.labels[0 .. n + 1];

        const done = child.emitInlineInstructions(ops, originals, fixupCount);
        // A nested emitter can grow the shared scratch buffer even on refusal.
        fixups = fixupScratch.ptr;
        fixupCap = fixupScratch.cap;
        if (!done) {
            a.n = start;
            return false;
        }

        a = child.a;
        literalCount = child.literalCount;
        arm.unprofiledCall = child.unprofiledCall;
        arm.expandedWatchedCall = child.expandedWatchedCall;
        return true;
    }

    bool emitInlineInstructions(const(JitOp)[] ops,
        const(Instruction.Handler)[] originals, size_t firstFixup)
    {
        import snakebite.backends.bytecode.vm: jitCountsBranch, JitTier;

        bool returned;
        const published = function_.jitHandlers !is null;
        const hasChecked = published && hasCheckedAccess(ops);
        if (published)
            emitScalarEntry(ops, originals, returned, hasChecked);
        foreach (i, ref const op; ops) {
            if (a.n + literalBytes + maximumBytesPerInstruction > codeLimit)
                return false;
            labels[i] = a.n;
            // Either edge of a branch can enter with different registers.
            intSlots = IntSlots.init;
            fpSlots = FpSlots.init;
            if (hasChecked && i)
                emitScalarEntry(ops, originals, returned, hasChecked, i);
            const original = originals[i];
            if (original is null) {
                a.ud2();
                continue;
            }

            const saved = a.n;
            const savedFixups = fixupCount;
            const savedLiterals = literalCount;
            size_t tierUp;
            const heat = Mem(PCREG, Function.jitHeat.offsetof);
            if (function_.jitHandlers is null && jitCountsBranch(original)) {
                a.movI(PCREG, cast(size_t) function_);
                a.ld(4, RAX, heat);
                a.aluRI(Alu.add, 4, RAX, jitStep);
                tierUp = jccLocal(CC_B);
                a.st(4, heat, RAX);
            }

            const body = a.n;
            bool done;
            switch (op.kind) with (JitOp.Kind) {
                case returnValue, returnVoid:
                    done = emitInlineReturn(i, op.kind == returnValue);
                    returned |= done;
                    break;
                case temporaryTransition:
                    // The cleanup state belongs to a real activation.
                    break;
                default:
                    done = emitTemplate(i, ops, op, original);
                    break;
            }
            if (outOfMemory)
                return false;
            if (!done) {
                a.n = saved;
                fixupCount = savedFixups;
                literalCount = savedLiterals;
                jumpToHandler(i, original);
            } else if (tierUp) {
                a.b(0xE9);
                const skip = a.n;
                a.d32(0);
                patchHere(tierUp);
                // A compiled handler does not count this branch. Complete
                // the event here if another entry has published the code.
                a.aluMI(Alu.cmp, 4, Mem(PCREG, Function.jitState.offsetof),
                    JitTier.compiled);
                const pending = jccLocal(CC_NE);
                a.st(4, heat, RAX);
                jmpLocalTo(body);
                patchHere(pending);
                jumpToHandler(i, original);
                patchHere(skip);
            }
        }
        if (!returned || a.n + literalBytes + maximumBytesPerInstruction > codeLimit)
            return false;

        a.ud2();
        labels[$ - 1] = a.n;
        a.ld(8, FRAME, inlineActivationField(Activation.parent.offsetof));
        foreach (fixup; fixups[firstFixup .. fixupCount])
            patchTo(fixup.position, labels[fixup.target]);
        return true;
    }

    Mem inlineActivationField(size_t offset) const {
        return Mem(FRAME, cast(int) (offset - inlineLayout.frameOffset));
    }

    bool emitInlineReturn(size_t i, bool hasValue) {
        const ins = snapshot[i];
        if (hasValue && ins.width > 64)
            return false;
        if (hasValue && ins.width != 0 && !emitReturnValue(ins,
                inlineActivationField(Activation.returnPlace.offsetof),
                inlineResultMayBeNull))
            return false;
        jmpTo(instructions.length);
        return true;
    }

    void materialize(const ref Gen body) {
        const parent = body.inlineCaller;
        if (parent.inlineCaller is null)
            a.ld(8, FRAME, Mem(ACTIVE, Activation.frame.offsetof));
        else
            materialize(*parent);
        loadWindow(body.inlineSite);
        a.lea(FRAME, Mem(R11, cast(int) body.inlineLayout.frameOffset));
        activateWindow(&parent.instructions[body.inlineCall], body.function_,
            body.inlineLayout);
    }

    bool emitReturn(size_t i, bool hasValue, Instruction.Handler original) {
        const ins = snapshot[i];
        if (hasValue && ins.width > 64)
            return false;

        a.ld(8, R10, Mem(ACTIVE, Activation.parent.offsetof));
        a.aluRI(Alu.cmp, 8, R10, 0);
        const root = jccLocal(CC_E);
        a.ld(8, R9, Mem(STATE, DispatchState.frames.offsetof));
        a.ld(8, R11, Mem(R9, FrameStack.cleanupMarkOffset));
        a.alu(Alu.cmp, 8, R11, Mem(ACTIVE, Activation.cleanupMark.offsetof));
        const cleanup = jccLocal(CC_NE);

        if (hasValue && ins.width != 0 && !emitReturnValue(ins,
                Mem(ACTIVE, Activation.returnPlace.offsetof), true))
            return false;

        a.ld(8, RAX, Mem(ACTIVE, Activation.frameMark.offsetof));
        a.alu(Alu.add, 8, RAX, Mem(R9, FrameStack.baseOffset));
        a.st(8, Mem(R9, FrameStack.topOffset), RAX);
        a.st(8, Mem(STATE, DispatchState.current.offsetof), R10);
        a.movRR64(ACTIVE, R10);
        a.ld(8, FRAME, Mem(ACTIVE, Activation.frame.offsetof));
        a.ld(8, PCREG, Mem(ACTIVE, Activation.resume.offsetof));
        a.jmpM(Mem(PCREG, Instruction.handler.offsetof));

        patchHere(root);
        patchHere(cleanup);
        jumpToHandler(i, original);
        return true;
    }

    bool emitReturnValue(in Instruction ins, in Mem place, bool mayBeNull) {
        Mem source;
        if (!opnd(ins.source, SC2, source))
            return false;
        a.ld(8, R11, place);
        size_t discard;
        if (mayBeNull) {
            a.aluRI(Alu.cmp, 8, R11, 0);
            discard = jccLocal(CC_E);
        }
        a.lea(RAX, source);
        a.aluRR(Alu.cmp, 8, RAX, R11);
        const aliased = jccLocal(CC_E);
        copyChunks(source, Mem(R11, 0), ins.width);
        patchHere(aliased);
        if (mayBeNull)
            patchHere(discard);
        return true;
    }

    // The value of `width` bytes at a constant-pool address, zero-extended.
    static ulong constantAt(size_t address, int w) {
        switch (w) {
            case 1: return *cast(const ubyte*) address;
            case 2: return *cast(const ushort*) address;
            case 4: return *cast(const uint*) address;
            default: return *cast(const ulong*) address;
        }
    }

    alias immOf = JitOp.immediate;

    bool storeConstant(int w, in Mem d, ulong value) {
        int imm;
        if (immOf(w, value, imm)) {
            a.stI(w, d, imm);
            return true;
        }
        a.movI(RAX, value);
        a.st(8, d, RAX);
        return false;
    }

    static bool goodWidth(size_t w) {
        return w == 1 || w == 2 || w == 4 || w == 8;
    }

    static int signedCc(Comparison comparison) {
        static immutable ubyte[6] t = [CC_L, CC_LE, CC_G, CC_GE, CC_E, CC_NE];
        return t[comparison];
    }

    static int unsignedCc(Comparison comparison) {
        static immutable ubyte[6] t = [CC_B, CC_BE, CC_A, CC_AE, CC_E, CC_NE];
        return t[comparison];
    }

    void jmpLocalTo(size_t offset) {
        a.b(0xE9);
        a.d32(cast(int) (offset - (a.n + 4)));
    }

    void jumpToHandler(size_t i, Instruction.Handler handler) {
        if (inlineCaller !is null) {
            materialize(this);
            jumpToLive(&instructions[i]);
            return;
        }
        jumpToOriginal(&instructions[i], handler);
    }

    void jumpToOriginal(const(Instruction)* pc, Instruction.Handler handler) {
        // The unchained dispatcher gets its register arguments from the state.
        static if (!chainedDispatch) {
            a.st(8, Mem(STATE, DispatchState.r0.offsetof), REG0);
            a.sse(doublePrefix, storeOpcode, fp0Register,
                Mem(STATE, DispatchState.fp0.offsetof));
        }
        a.movI(PCREG, cast(size_t) pc);
        a.movI(RAX, cast(size_t) handler);
        a.jmpRax;
    }

    CheckedLoop planCheckedLoop(size_t i, const(JitOp)[] ops) {
        import std.algorithm.comparison: min, max;

        const store = snapshot[i];
        const check = ops[i].checked;
        size_t update;
        if (!i || check.access != CheckedAccess.store || !check.constantValue
                || check.fixedLength || check.indexWidth != int.sizeof
                || !check.signed || ops[i].width != ubyte.sizeof
                || !targetIndex(store.sourceWidth, update)
                || update <= i + 1 || ops.length - update < 3)
            return CheckedLoop.init;

        const header = snapshot[i - 1];
        const test = ops[i - 1];
        const index = cast(uint) store.width;
        size_t exit;
        if (test.kind != JitOp.Kind.fused || test.fused.kind != CompareKind.signed
                || test.fused.constantRight || test.fused.leftInR0
                || integerBranchCc(test.fused) != CC_G
                || header.width != int.sizeof || header.destination != index
                || !targetIndex(header.sourceWidth, exit) || exit != update + 2)
            return CheckedLoop.init;

        const ins = snapshot[update];
        const add = ops[update];
        const width = add.width ? add.width : ins.width;
        size_t head;
        if (add.kind != JitOp.Kind.int3
                || add.int3.operation != JitOp.IntOperation.add
                || add.int3.constantRight || add.int3.leftInR0
                || add.int3.resultInR0 || width != int.sizeof
                || ins.destination != index
                || (!add.int3.twoAddress && ins.source != index)
                || ops[update + 1].kind != JitOp.Kind.jump
                || !targetIndex(snapshot[update + 1].destination, head)
                || head != i - 1)
            return CheckedLoop.init;

        const step = add.int3.twoAddress ? ins.source : ins.sourceWidth;
        const size_t[4] slots = [index, step, header.source, store.source];
        const size_t[4] widths = [int.sizeof, int.sizeof, int.sizeof,
            arrayPointerOffset + size_t.sizeof];
        auto start = size_t.max;
        size_t end;
        foreach (n, offset; slots) {
            Mem operand;
            if (!frameOperand(offset, operand) || offset > frameSize
                    || widths[n] > frameSize - offset)
                return CheckedLoop.init;
            const past = offset + widths[n];
            foreach (other, earlier; slots[0 .. n])
                if (offset < earlier + widths[other] && earlier < past)
                    return CheckedLoop.init;
            start = min(start, offset);
            end = max(end, past);
        }
        return CheckedLoop(update, cast(int) index, cast(int) slots[1],
            cast(int) header.source, cast(int) start, cast(int) end);
    }

    IntLoop planIntLoop(size_t head, const(JitOp)[] ops,
        const(Instruction.Handler)[] originals)
    {
        foreach (backedge; head + 1 .. ops.length) {
            if (backedge - head >= IntLoop.limit)
                break;
            size_t target;
            if (!intLoopTarget(backedge, ops[backedge], target) || target != head)
                continue;
            const plan = proveIntLoop(head, backedge, ops, originals);
            if (plan.backedge)
                return plan;
            break;
        }
        return IntLoop.init;
    }

    bool intLoopTarget(size_t index, in JitOp op, out size_t target) {
        const ins = snapshot[index];
        switch (op.kind) with (JitOp.Kind) {
            case jump: return targetIndex(ins.destination, target);
            case branch: return targetIndex(ins.source, target);
            case fused: return targetIndex(ins.sourceWidth, target);
            default: return false;
        }
    }

    IntLoop proveIntLoop(size_t head, size_t backedge, const(JitOp)[] ops,
        const(Instruction.Handler)[] originals)
    {
        enum unavailable = size_t.max;
        size_t[IntLoop.limit] next = unavailable;
        // A path with two possible routes to the backedge needs a join proof.
        // Work backwards through forward edges to find a single route.
        for (size_t i = backedge + 1; i-- > head;) {
            if (originals[i] is null || !intLoopOp(i, ops[i]))
                continue;
            size_t target;
            const branch = intLoopTarget(i, ops[i], target);
            if (i == backedge) {
                if (branch)
                    next[i - head] = head;
                continue;
            }
            const taken = branch && target > i && target <= backedge
                && next[target - head] != unavailable;
            const fallthrough = ops[i].kind != JitOp.Kind.jump
                && next[i + 1 - head] != unavailable;
            if (taken != fallthrough)
                next[i - head] = taken ? target : i + 1;
        }
        if (next[0] == unavailable)
            return IntLoop.init;

        IntLoop plan;
        plan.head = head;
        plan.backedge = backedge;
        foreach (pass; 0 .. 2) {
            for (size_t i = head; i != backedge; i = next[i - head]) {
                plan.path |= 1UL << (i - head);
                const op = ops[i];
                if (op.kind != JitOp.Kind.copy)
                    continue;
                const ins = snapshot[i];
                const width = cast(int) opWidth(ins, op);
                Mem dest, source, address;
                frameOperand(ins.destination, dest);
                storageOperand(ins.source, R10, source, address);
                const advances = !op.copy.staticSource && source.base != FRAME
                    && address.disp == dest.disp && width == size_t.sizeof;
                if (pass == 0 && advances && plan.seed.find(dest, width) < 0) {
                    if (plan.seed.older.width || plan.seed.overlaps(dest, width)
                            || cast(size_t) dest.disp + width > frameSize)
                        return IntLoop.init;
                    const reg = plan.seed.newest.width ? RAX : R11;
                    plan.seed.rememberCopy(dest, width, reg);
                }
                if (pass == 1 && plan.seed.overlaps(dest, width)
                        && plan.seed.find(dest, width) < 0)
                    return IntLoop.init;
            }
            if (plan.seed.empty)
                return IntLoop.init;
        }
        plan.path |= 1UL << (backedge - head);
        return plan;
    }

    bool intLoopOp(size_t i, in JitOp op) {
        // The path keeps all stores and indirect reads in their original
        // order. No handler on it can write through an alias or synchronize.
        const ins = snapshot[i];
        Mem operand, address;
        switch (op.kind) with (JitOp.Kind) {
            case copy:
                return goodWidth(opWidth(ins, op))
                    && !op.copy.staticSource
                    && frameOperand(ins.destination, operand)
                    && storageOperand(ins.source, R10, operand, address);
            case fused:
                int immediate;
                return op.fused.kind != CompareKind.floating
                    && op.fused.constantRight
                    && goodWidth(ins.width)
                    && (op.fused.leftInR0 || frameOperand(ins.destination, operand))
                    && immOf(cast(int) ins.width,
                        constantAt(ins.source, cast(int) ins.width), immediate);
            case branch:
                return goodWidth(opWidth(ins, op))
                    && frameOperand(ins.destination, operand);
            case jump:
                return true;
            default:
                return false;
        }
    }

    bool emitIntLoopInstruction(size_t i, const(JitOp)[] ops,
        Instruction.Handler original)
    {
        // A dispatch or a cold edge reloads the canonical frame. A hot
        // fallthrough or a local branch already has the same register map.
        const preceding = i > intLoop.head && intLoop.contains(i - 1);
        if (!preceding)
            intLoop.seed.reload(a);
        else
            addReloadEntry(i, FpSlots.init, intLoop.seed);
        if (i == intLoop.head)
            intLoop.headBody = a.n;
        if (i == intLoop.head + 1)
            intLoop.afterHeader = a.n;
        if (intLoop.forwardFixup) {
            patchHere(intLoop.forwardFixup);
            intLoop.forwardFixup = 0;
        }
        intSlots = intLoop.seed;
        intLoopInstruction = i;
        fpSlots = FpSlots.init;
        known = KnownConstant.init;
        const emitted = emitTemplate(i, ops, ops[i], original,
            /*copyRun*/ true, /*carryCopy*/ true);
        intLoopInstruction = size_t.max;
        intSlots = IntSlots.init;
        return emitted && !outOfMemory;
    }

    void jccIntLoop(int cc, size_t target, size_t local = 0) {
        if (!local && intLoop.contains(intLoopInstruction)
                && intLoop.contains(target)) {
            if (intLoopInstruction == intLoop.backedge && target == intLoop.head)
                local = intLoop.headBody;
            else if (target > intLoopInstruction) {
                const first = intLoopInstruction + 1;
                const intervening = (1UL << (target - first)) - 1;
                if (!(intLoop.path >> (first - intLoop.head) & intervening)) {
                    intLoop.forwardFixup = jccLocal(cc);
                    return;
                }
            }
        }
        jccTo(cc, target, local);
    }

    FpLoop planFpLoop(size_t head, const(JitOp)[] ops,
        const(Instruction.Handler)[] originals)
    {
        // One backedge and one join suffice for a local register-map check.
        with (JitOp.Kind) {
            enum minLoopInstructions = 6;
            enum maxLoopInstructions = 24;
            size_t exit, target;
            if (!targetIndex(snapshot[head].source, exit) || exit <= head
                    || exit - head < minLoopInstructions
                    || exit - head > maxLoopInstructions
                    || ops[exit - 1].kind != jump
                    || !targetIndex(snapshot[exit - 1].destination, target)
                    || target != head)
                return FpLoop.init;

            const limit = head + 1;
            if (ops[limit].kind != fused
                    || ops[limit].fused.kind == CompareKind.floating
                    || !ops[limit].fused.constantRight
                    || !targetIndex(snapshot[limit].sourceWidth, target)
                    || target != exit)
                return FpLoop.init;

            foreach (original; originals[head .. exit])
                if (original is null)
                    return FpLoop.init;
            Mem memory;
            const header = snapshot[head];
            const test = snapshot[limit];
            if (!goodWidth(ops[head].width ? ops[head].width : header.width)
                    || !frameOperand(header.destination, memory)
                    || !goodWidth(test.width)
                    || (!ops[limit].fused.leftInR0
                        && !frameOperand(test.destination, memory)))
                return FpLoop.init;

            const join = exit - 2;
            const firstFp = limit + 1;
            size_t compare = firstFp;
            FpSlots endSlots;
            for (; compare < join && ops[compare].kind == fp3; ++compare)
                if (!advanceDirectFpSlots(compare, ops[compare].fp3, endSlots))
                    return FpLoop.init;
            const cmp = snapshot[compare];
            if (compare == firstFp || compare == join || ops[compare].kind != fused
                    || ops[compare].fused.kind != CompareKind.floating
                    || !targetIndex(cmp.sourceWidth, target) || target != join
                    || (cmp.width != 4 && cmp.width != 8)
                    || (!ops[compare].fused.leftInR0
                        && !frameOperand(cmp.destination, memory))
                    || (!ops[compare].fused.constantRight
                        && !frameOperand(cmp.source, memory)))
                return FpLoop.init;

            FpSlots seed;
            foreach (index, slot; endSlots.slots)
                if (slot.offset >= 0 && readsBeforeWrite(slot, firstFp,
                        ops[firstFp .. compare]))
                    seed.slots[index] = slot;
            if (seed.empty)
                return FpLoop.init;
            // A carried right operand can change the register assignment.
            endSlots = seed;
            foreach (i; firstFp .. compare)
                if (!advanceDirectFpSlots(i, ops[i].fp3, endSlots))
                    return FpLoop.init;
            foreach (index, slot; seed.slots)
                if (slot.offset >= 0 && endSlots.slots[index] != slot)
                    return FpLoop.init;

            foreach (i; compare + 1 .. join) {
                const ins = snapshot[i];
                const op = ops[i];
                const width = op.kind == copy && op.width ? op.width : ins.width;
                if (!(op.kind == zero || (op.kind == constant
                            && ins.source < constants.length)
                        || (op.kind == copy && isLiteralCopy(ins, op, width)))
                        || !preservesFpSlots(ins.destination, width, endSlots))
                    return FpLoop.init;
            }

            const update = snapshot[join];
            const op = ops[join];
            const width = op.width ? op.width : update.width;
            if (op.kind != int3 || !op.int3.constantRight || op.int3.resultInR0
                    || (!op.int3.twoAddress && !op.int3.leftInR0
                        && !frameOperand(update.source, memory))
                    || !preservesFpSlots(update.destination, width, endSlots))
                return FpLoop.init;

            return FpLoop(head, compare, join, exit - 1, seed);
        }
    }

    bool advanceDirectFpSlots(size_t i, in JitOp.Fp3 op, ref FpSlots slots) {
        const ins = snapshot[i];
        const width = cast(int) ins.width;
        Mem dest, left, right;
        if ((width != 4 && width != 8) || (op.leftInFp0 && width != 8)
                || (!op.resultInFp0 && !frameOperand(ins.destination, dest))
                || (!op.leftInFp0 && !frameOperand(ins.source, left))
                || (!op.constantRight && !frameOperand(ins.sourceWidth, right)))
            return false;
        if (!op.resultInFp0)
            slots.assign(dest, width,
                op.leftInFp0 ? fp0Register : slots.find(left, width),
                op.constantRight ? -1 : slots.find(right, width));
        return true;
    }

    bool readsBeforeWrite(in FpSlots.Slot slot, size_t first,
        const(JitOp)[] ops)
    {
        foreach (offset, ref const op; ops) {
            const ins = snapshot[first + offset];
            if (slot.width == ins.width
                    && ((!op.fp3.leftInFp0 && slot.offset == ins.source)
                        || (!op.fp3.constantRight && slot.offset == ins.sourceWidth)))
                return true;
            if (!op.fp3.resultInFp0
                    && ins.destination < slot.offset + slot.width
                    && cast(size_t) slot.offset < ins.destination + ins.width)
                return false;
        }
        return false;
    }

    static bool preservesFpSlots(size_t raw, size_t width, in FpSlots slots) {
        Mem dest;
        if (!goodWidth(width) || !frameOperand(raw, dest))
            return false;
        foreach (slot; slots.slots)
            if (slot.offset >= 0 && slot.offset < dest.disp + width
                    && dest.disp < slot.offset + slot.width)
                return false;
        return true;
    }

    static struct BranchOnly {
        enum limit = 16;

        static struct Copy {
            size_t pc;
            size_t whenZero;
            size_t whenNonzero;
        }

        size_t end;
        size_t count;
        Copy[limit] copies;
    }

    BranchOnly planBranchOnly(size_t first, const(JitOp)[] ops) {
        const initial = snapshot[first];
        const slot = initial.destination;
        if (!branchOnlyCopy(initial, ops[first]) || slot >= frameSize)
            return BranchOnly.init;

        BranchOnly plan;
        size_t branches;
        for (auto pc = first; pc < ops.length && pc - first < BranchOnly.limit;
                ++pc) {
            const ins = snapshot[pc];
            const op = ops[pc];
            if (ins.destination != slot)
                break;
            if (branchOnlyCopy(ins, op)) {
                plan.copies[plan.count++].pc = pc;
            } else if (op.kind == JitOp.Kind.branch && opWidth(ins, op) == 1) {
                size_t target;
                if (!targetIndex(ins.source, target) || target <= pc)
                    return BranchOnly.init;
                ++branches;
            } else if (op.kind != JitOp.Kind.boolOp || ins.width != 1)
                break;
            plan.end = pc + 1;
        }
        if (plan.count < 2 || branches < 2
                || ops[plan.end - 1].kind != JitOp.Kind.branch)
            return BranchOnly.init;

        foreach (ref copy; plan.copies[0 .. plan.count]) {
            copy.whenZero = branchOnlyTarget(copy.pc + 1, false, plan.end, ops);
            copy.whenNonzero = branchOnlyTarget(copy.pc + 1, true, plan.end, ops);
        }
        return plan;
    }

    static size_t opWidth(in Instruction ins, in JitOp op) {
        return op.width ? op.width : ins.width;
    }

    static bool branchOnlyCopy(in Instruction ins, in JitOp op) {
        import snakebite.backends.bytecode.vm: addressSlotOf;

        if (op.kind != JitOp.Kind.copy || op.copy.staticSource
                || opWidth(ins, op) != 1)
            return false;
        Mem value, address;
        if (!storageOperand(ins.source, R9, value, address))
            return false;
        if (!(ins.source & indirectBit))
            return ins.source != ins.destination;
        const slot = addressSlotOf(ins.source);
        return ins.destination < slot || ins.destination - slot >= size_t.sizeof;
    }

    size_t branchOnlyTarget(size_t pc, bool nonzero, size_t end,
        const(JitOp)[] ops)
    {
        while (pc < end) {
            const op = ops[pc];
            if (op.kind == JitOp.Kind.copy)
                break;
            if (op.kind == JitOp.Kind.boolOp) {
                nonzero = nonzero == op.boolOp.nonzero;
                ++pc;
            } else
                pc = branchSuccessor(pc, op.branch, nonzero);
        }
        return pc;
    }

    size_t branchSuccessor(size_t pc, in JitOp.Branch branch, bool nonzero) {
        if (nonzero != branch.jumpIfNonzero)
            return pc + 1;
        size_t target;
        return targetIndex(snapshot[pc].source, target) ? target : size_t.max;
    }

    static struct BranchOnlyCandidate {
        size_t slot;
        size_t first;
        size_t end;
        ptrdiff_t changes;
    }

    static struct BranchOnlyEntry {
        size_t earliest = size_t.max;
        size_t latest;
        bool approved;
    }

    const(BranchOnlyEntry)[] proveBranchOnly(const(JitOp)[] ops,
        ref Scratch!BranchOnlyCandidate candidates,
        ref Scratch!BranchOnlyEntry entries)
    {
        import snakebite.backends.bytecode.emitted: EmittedCode;
        import snakebite.backends.bytecode.vm:
            addressSlotOf, branchTargetField, discardResult, opReturn, opReturnVoid;
        import std.algorithm.sorting: sort;

        if (function_.exceptionHandlers.length || function_.closureSize
                || function_.cursorOffset != size_t.max)
            return null;

        size_t count;
        foreach (pc; 0 .. ops.length) {
            const plan = planBranchOnly(pc, ops);
            if (!plan.end)
                continue;
            auto storage = candidates.grow(count + 1);
            if (storage is null)
                return null;
            storage[count++] = BranchOnlyCandidate(snapshot[pc].destination,
                pc, plan.end);
        }
        if (!count)
            return null;
        auto ranges = candidates.ptr[0 .. count];
        ranges.sort!((a, b) => a.slot < b.slot);
        auto storage = entries.reserve(ops.length);
        if (storage is null)
            return null;
        auto targets = storage[0 .. ops.length];
        targets[] = BranchOnlyEntry.init;

        size_t firstSlotAtOrAfter(size_t offset) {
            size_t low;
            size_t high = ranges.length;
            while (low < high) {
                const mid = low + (high - low) / 2;
                if (ranges[mid].slot < offset)
                    low = mid + 1;
                else
                    high = mid;
            }
            return low;
        }

        // Each access adds one to the count of each candidate byte it
        // overlaps. A prefix sum applies the changes without visiting each
        // candidate for a wide access.
        void countAccess(size_t operand, size_t width) {
            if (operand & indirectBit) {
                operand = addressSlotOf(operand);
                width = size_t.sizeof;
            }
            if (!width || operand >= frameSize)
                return;
            const first = firstSlotAtOrAfter(operand);
            if (first < ranges.length)
                ++ranges[first].changes;
            const end = operand + (width < frameSize - operand
                ? width : frameSize - operand);
            const past = firstSlotAtOrAfter(end);
            if (past < ranges.length)
                --ranges[past].changes;
        }

        if (function_.windowSlot != size_t.max)
            countAccess(function_.windowSlot, size_t.sizeof);
        if (function_.returnPlace.offset != size_t.max)
            countAccess(function_.returnPlace.offset, size_t.sizeof);

        foreach (pc, ref const ins; snapshot) {
            Instruction instruction = ins;
            if (const field = branchTargetField(instruction)) {
                size_t target;
                if (!targetIndex(*field, target))
                    return null;
                auto entry = &targets[target];
                if (entry.earliest == size_t.max)
                    entry.earliest = pc;
                entry.latest = pc;
            }

            const op = ops[pc];
            switch (op.kind) with (JitOp.Kind) {
                case callWindow:
                    const site = &callSites[ins.source];
                    if (site.cleanupStartIndex != size_t.max)
                        return null;
                    if (op.callWindow.indirect)
                        countAccess(site.calleeSlotOffset, size_t.sizeof);
                    if (ins.destination != discardResult)
                        countAccess(ins.destination, site.returnWidth);
                    EmittedCode.eachCallArgument(*site, &countAccess);
                    continue;
                case copy:
                    if (op.copy.staticSource) {
                        countAccess(ins.destination, opWidth(ins, op));
                        continue;
                    }
                    break;
                case zero, jump, branch, fused, boolOp, returnVoid, returnValue:
                    break;
                case none:
                    // A non-chained return uses the original handler. It has
                    // the same frame accesses as a return with a template.
                    if (ins.handler is &opReturn || ins.handler is &opReturnVoid)
                        break;
                    return null;
                default:
                    // An unclassified operation can expose the frame.
                    return null;
            }
            const access = EmittedCode.accessOf(ins.handler);
            if (!access.known || access.takesAddress || access.widthIsSlot)
                return null;
            foreach (field; EmittedCode.allFields)
                if (access.namesStorage(field))
                    countAccess(EmittedCode.operandOf(ins, field),
                        EmittedCode.extentOf(ins, access, field));
        }

        ptrdiff_t mentions;
        foreach (ref const range; ranges) {
            mentions += range.changes;
            // Each chain instruction names the byte once. An outside edge
            // into its interior could reach a handler with a stale value.
            if (mentions != range.end - range.first)
                continue;
            bool outsideEntry;
            foreach (ref const target; targets[range.first + 1 .. range.end])
                outsideEntry |= target.earliest < range.first
                    || target.latest >= range.end;
            targets[range.first].approved = !outsideEntry;
        }
        return targets;
    }

    void emitBranchOnly(size_t first, in BranchOnly plan) {
        fpSlots = FpSlots.init;
        intSlots = IntSlots.init;
        known = KnownConstant.init;
        const copies = plan.copies[0 .. plan.count];
        foreach (index, copy; copies) {
            if (copy.pc != first)
                labels[copy.pc] = a.n;
            Mem source;
            const valid = opnd(snapshot[copy.pc].source, R9, source);
            assert(valid);
            a.aluMI(Alu.cmp, 1, source, 0);
            const next = index + 1 == copies.length ? plan.end : copies[index + 1].pc;
            if (copy.whenZero == copy.whenNonzero) {
                if (copy.whenZero != next)
                    jmpTo(copy.whenZero);
            } else if (copy.whenNonzero == next)
                jccTo(CC_E, copy.whenZero);
            else {
                jccTo(CC_NE, copy.whenNonzero);
                if (copy.whenZero != next)
                    jmpTo(copy.whenZero);
            }
        }
    }

    bool emitOp(size_t i, const(JitOp)[] ops,
        Instruction.Handler original)
    {
        const op = ops[i];
        const fpArithmetic = op.kind == JitOp.Kind.fp3;
        const fpCompare = op.kind == JitOp.Kind.fused
            && op.fused.kind == CompareKind.floating;
        const usesInt = op.kind == JitOp.Kind.int3 || op.kind == JitOp.Kind.cmp3
            || op.kind == JitOp.Kind.castFixed || op.kind == JitOp.Kind.widen
            || op.kind == JitOp.Kind.jump || op.kind == JitOp.Kind.copy
            || op.kind == JitOp.Kind.index || op.kind == JitOp.Kind.zero
            || op.kind == JitOp.Kind.constant
            || (op.kind == JitOp.Kind.fused && !fpCompare);
        const inFpLoop = fpLoop.backedge != 0;
        if (!fpArithmetic && !fpCompare && !inFpLoop)
            fpSlots = FpSlots.init;
        if (!usesInt)
            intSlots = IntSlots.init;
        if (!fpArithmetic && !fpCompare && !usesInt && !inFpLoop)
            return emitTemplate(i, ops, op, original);

        const scalarCopy = !inFpLoop && isScalarCopy(i, op);
        const carryCopy = scalarCopy && i + 1 < ops.length
            && isScalarCopy(i + 1, ops[i + 1]);
        const copyRun = carryCopy
            || (scalarCopy && i != 0 && isScalarCopy(i - 1, ops[i - 1]));
        // RAX is the value scratch for an indirect store. R11 is the
        // address scratch for the right operand of an integer operation.
        if ((copyRun && intSlots.newest.reg == RAX)
                || (!copyRun && intSlots.newest.reg == R11))
            intSlots = IntSlots.init;

        const incomingFp = fpSlots;
        const incomingInt = intSlots;
        readIntSlot = false;
        const done = emitTemplate(i, ops, op, original, copyRun, carryCopy);
        if (!done || (fpCompare && !inFpLoop))
            fpSlots = FpSlots.init;
        if (!done || op.kind == JitOp.Kind.jump)
            intSlots = IntSlots.init;
        const reloadInt = readIntSlot || (carryCopy && !incomingInt.empty);
        if (done && (!incomingFp.empty || reloadInt)
                && !(inFpLoop && i == fpLoop.head)) {
            // Only the preceding template's fallthrough can assume these
            // registers are live. All other entries reload the frame.
            addReloadEntry(i, incomingFp, reloadInt ? incomingInt : IntSlots.init);
        }
        return done;
    }

    void addReloadEntry(size_t i, in FpSlots fp, in IntSlots ints) {
        auto entries = reloadEntryScratch.grow(reloadEntryCount + 1);
        if (entries is null)
            outOfMemory = true;
        else
            entries[reloadEntryCount++] = ReloadEntry(i, fp, ints);
    }

    bool isScalarCopy(size_t i, in JitOp op) const {
        return op.kind == JitOp.Kind.copy
            && goodWidth(op.width ? op.width : snapshot[i].width);
    }

    bool emitTemplate(size_t i, const(JitOp)[] ops, in JitOp op,
        Instruction.Handler original, bool copyRun = false, bool carryCopy = false)
    {
        const ins = snapshot[i];
        final switch (op.kind) with (JitOp.Kind) {
        case none, intToFloat:
            return false;

        case callWindow:
            return emitCallWindow(i, op.callWindow, original);

        case returnValue:
        case returnVoid:
            return emitReturn(i, op.kind == returnValue, original);

        case temporaryTransition:
            // Only a direct frame slot can skip receiver resolution.
            if (ins.source & indirectBit)
                return false;
            a.ld(8, R9, Mem(STATE, DispatchState.frames.offsetof));
            a.ld(8, RAX, Mem(R9, FrameStack.cleanupMarkOffset));
            a.alu(Alu.cmp, 8, RAX, Mem(ACTIVE, Activation.cleanupMark.offsetof));
            jccTo(CC_BE, i + 1);
            jumpToHandler(i, original);
            return true;

        case copy: {
            const size = op.width ? op.width : ins.width;
            if (size > 64)
                return false;
            Mem d, s;
            const validDest = copyRun
                ? opnd!(/*reusePointer*/ true)(ins.destination, R9, d)
                : opnd(ins.destination, R9, d);
            if (!validDest)
                return false;
            const scalar = goodWidth(size) && (d.base == FRAME || copyRun);
            if (isLiteralCopy(ins, op, size)) {
                const width = cast(int) size;
                const immediate = storeConstant(width, d, constantAt(ins.source, width));
                if (!immediate || !carryIndexToRegion(i, ops, d, width))
                    finishCopy(d, width, carryCopy);
                return true;
            }
            if (op.copy.staticSource) {
                a.movI(R10, ins.source);
                s = Mem(R10, 0);
            } else {
                if (goodWidth(size) && known.covers(ins.source, size)) {
                    usedKnown = true;
                    storeConstant(cast(int) size, d, known.bits);
                    finishCopy(d, cast(int) size, carryCopy);
                    return true;
                }
                const valid = scalar
                    ? opnd!(/*reusePointer*/ true)(ins.source, R10, s)
                    : opnd(ins.source, R10, s);
                if (!valid)
                    return false;
            }
            if (scalar) {
                const width = cast(int) size;
                const cached = cachedInt(s, width);
                if (intLoop.contains(intLoopInstruction)) {
                    const assigned = intSlots.find(d, width);
                    const reg = assigned >= 0 ? assigned : R9;
                    if (cached < 0)
                        a.ld(width, reg, s);
                    else if (cached != reg)
                        a.movRR64(reg, cached);
                    a.st(width, d, reg);
                    return true;
                }
                const remember = carryCopy && d.base == FRAME;
                const reg = cached >= 0 ? cached
                    : remember ? intSlots.copyRegister : RAX;
                if (cached < 0)
                    a.ld(width, reg, s);
                storeInt(d, width, reg, remember);
            } else {
                copyChunks(s, d, size);
                intSlots = IntSlots.init;
            }
            return true;
        }

        case constant: {
            const w = ins.width;
            if (!goodWidth(w) || ins.source >= constants.length)
                return false;
            Mem d;
            if (!opnd(ins.destination, R9, d))
                return false;
            const immediate = storeConstant(cast(int) w, d, cast(ulong) constants[ins.source]);
            if (!immediate || !carryIndexToRegion(i, ops, d, cast(int) w))
                intSlots = IntSlots.init;
            return true;
        }

        case zero: {
            const size = ins.width;
            if (size > 64)
                return false;
            Mem d;
            if (!opnd(ins.destination, R9, d))
                return false;
            size_t off = 0;
            foreach (c; _chunkSizes) {
                while (size - off >= c) {
                    auto dd = d;
                    dd.disp += cast(int) off;
                    a.stI(c, dd, 0);
                    off += c;
                }
            }
            if (!carryIndexToRegion(i, ops, d, cast(int) size))
                intSlots = IntSlots.init;
            return true;
        }

        case jump: {
            if (intLoop.contains(intLoopInstruction)) {
                const head = intLoop.head;
                size_t exit;
                if (i == intLoop.backedge && intLoop.afterHeader
                        && ops[head].kind == fused
                        && targetIndex(snapshot[head].sourceWidth, exit)
                        && exit == i + 1) {
                    JitOp.Fused test = ops[head].fused;
                    test.jumpWhen = !test.jumpWhen;
                    return emitFused(snapshot[head], test, head + 1,
                        intLoop.afterHeader);
                }
                if (i == intLoop.backedge)
                    jmpLocalTo(intLoop.headBody);
                else {
                    a.b(0xE9);
                    intLoop.forwardFixup = a.n;
                    a.d32(0);
                }
                return true;
            }
            if (fpLoop.backedge && i == fpLoop.backedge) {
                jmpLocalTo(fpLoop.headBody);
                return true;
            }
            size_t t;
            if (!targetIndex(ins.destination, t))
                return false;
            if (t < i && ops[t].kind == fused
                    && ops[t].fused.kind != CompareKind.floating) {
                const header = snapshot[t];
                size_t exit;
                // Keep the header for initial entry. At the back edge, jump
                // to its fallthrough only when the test would stay in the loop.
                if (targetIndex(header.sourceWidth, exit) && exit == i + 1) {
                    // `auto` would keep the copy const.
                    JitOp.Fused test = ops[t].fused;
                    test.jumpWhen = !test.jumpWhen;
                    const carriesIndex = checkedEntry.index == t + 1
                        && !test.leftInR0 && header.width == int.sizeof
                        && header.destination == cast(uint) snapshot[t + 1].width
                        && intSlots.newest == IntSlot(cast(int) header.destination,
                            int.sizeof, RAX);
                    const saved = a.n;
                    if (emitFused(header, test, t + 1,
                            carriesIndex ? checkedEntry.afterLoad : 0,
                            indexOps: ops, predecessor: i))
                        return true;
                    a.n = saved;
                    readIntSlot = false;
                }
            }
            jmpTo(t);
            return true;
        }

        case branch: {
            const w = op.width ? op.width : ins.width;
            size_t t;
            if (!goodWidth(w) || !targetIndex(ins.source, t))
                return false;
            Mem d;
            if (!opnd(ins.destination, R9, d))
                return false;
            const cached = intLoop.contains(intLoopInstruction)
                ? intSlots.find(d, cast(int) w) : -1;
            if (cached >= 0)
                a.aluRI(Alu.cmp, cast(int) w, cached, 0);
            else
                a.aluMI(Alu.cmp, cast(int) w, d, 0);
            jccIntLoop(op.branch.jumpIfNonzero ? CC_NE : CC_E, t);
            return true;
        }

        case int3:
            return emitInt3(ins, op);
        case signedDivide:
            return emitSignedDivide(ins, op);
        case cmp3:
            return emitCmp3(ins, op);
        case fused: {
            size_t t;
            return targetIndex(ins.sourceWidth, t)
                && emitFused(ins, op.fused, t, indexOps: ops, predecessor: i);
        }
        case fp3:
            return emitFp3(ins, op);
        case fpcmp3:
            return emitFpCmp3(ins, op);

        case index: {
            Mem d, s, r;
            if (!opnd(ins.destination, R9, d) || !opnd(ins.source, R10, s)
                    || !opnd(ins.sourceWidth, R11, r))
                return false;
            const es = ins.width;
            if (es > int.max)
                return false;
            int cached = -1;
            if (d.base == FRAME && s.base == FRAME && r.base == FRAME)
                cached = cachedInt(r, size_t.sizeof);
            // The base load can overwrite the register holding the index.
            if (cached >= 0 && cached != SC2)
                a.movRR64(SC2, cached);
            final switch (op.index.base) {
                case IndexBase.slice:
                    a.ld(8, RAX, Mem(s.base, s.disp + cast(int) arrayPointerOffset));
                    break;
                case IndexBase.staticArray:
                    a.lea(RAX, s);
                    break;
                case IndexBase.pointer:
                    a.ld(8, RAX, s);
            }
            if (cached < 0)
                a.ld(8, SC2, r);
            if (es == 1 || es == 2 || es == 4 || es == 8)
                a.lea(RAX, Mem(RAX, 0, SC2, cast(ubyte) es));
            else {
                a.imulRI(SC2, SC2, cast(int) es);
                a.aluRR(Alu.add, 8, RAX, SC2);
            }
            storeInt(d, size_t.sizeof, RAX);
            return true;
        }

        case checked:
            if (inlineCaller is null && !checkedLoop.update && !fpLoop.backedge
                    && !intLoop.backedge) {
                checkedLoop = planCheckedLoop(i, ops);
                if (checkedLoop.update)
                    return emitCheckedLoop(i, ins, op, original);
            }
            return emitChecked(i, ins, op, size_t.max, null, ops);

        case castFixed: {
            Mem d, s;
            if (!opnd(ins.destination, R9, d) || !opnd(ins.source, R10, s))
                return false;
            emitIntCast(d, op.width, s, op.castFixed.sourceSize,
                op.castFixed.zeroExtend);
            return true;
        }

        case sliceToPointer: {
            if (ins.width != size_t.sizeof)
                return false;
            Mem d, s;
            if (!opnd(ins.destination, R9, d) || !opnd(ins.source, R10, s))
                return false;
            s.disp += cast(int) arrayPointerOffset;
            a.ld(size_t.sizeof, RAX, s);
            a.st(size_t.sizeof, d, RAX);
            return true;
        }

        case widen: {
            // In place: the source width is in `source`, the width in `width`.
            if (!goodWidth(ins.source) || !goodWidth(ins.width))
                return false;
            Mem d;
            if (!opnd(ins.destination, R9, d))
                return false;
            emitIntCast(d, cast(int) ins.width, d, cast(int) ins.source,
                op.widen.zeroExtend);
            return true;
        }

        case loadInd: {
            const size = op.width ? op.width : ins.width;
            if (size > 64)
                return false;
            Mem d, s;
            if (!opnd(ins.destination, R9, d) || !opnd(ins.source, R10, s))
                return false;
            a.ld(8, SC2, s);
            copyChunks(Mem(SC2, 0), d, size);
            return true;
        }

        case storeInd: {
            const size = op.width ? op.width : ins.width;
            if (size > 64)
                return false;
            Mem d, s;
            if (!opnd(ins.destination, R9, d) || !opnd(ins.source, R10, s))
                return false;
            a.ld(8, SC2, d);
            copyChunks(s, Mem(SC2, 0), size);
            return true;
        }

        case frameAddr: {
            Mem d, s;
            if (!opnd(ins.destination, R9, d) || !opnd(ins.source, R10, s))
                return false;
            a.lea(RAX, s);
            a.st(8, d, RAX);
            return true;
        }

        case staticLoad: {
            const size = ins.width;
            if (size > 64)
                return false;
            Mem d;
            if (!opnd(ins.destination, R9, d))
                return false;
            a.movI(R10, ins.source);
            copyChunks(Mem(R10, 0), d, size);
            return true;
        }

        case staticStore: {
            const size = ins.width;
            if (size > 64)
                return false;
            Mem s;
            if (!opnd(ins.source, R10, s))
                return false;
            a.movI(R9, ins.destination);
            copyChunks(s, Mem(R9, 0), size);
            return true;
        }

        case staticAddr: {
            Mem d;
            if (!opnd(ins.destination, R9, d))
                return false;
            int imm;
            if (immOf(8, ins.source, imm))
                a.stI(8, d, imm);
            else {
                a.movI(RAX, ins.source);
                a.st(8, d, RAX);
            }
            return true;
        }

        case boolOp: {
            const w = ins.width;
            if (!goodWidth(w))
                return false;
            Mem d;
            if (!opnd(ins.destination, R9, d))
                return false;
            a.aluMI(Alu.cmp, cast(int) w, d, 0);
            a.setcc(op.boolOp.nonzero ? CC_NE : CC_E, d);
            return true;
        }

        case unary: {
            const w = ins.width;
            if (!goodWidth(w))
                return false;
            Mem d;
            if (!opnd(ins.destination, R9, d))
                return false;
            a.negNot(!op.unary.complement, cast(int) w, d);
            return true;
        }

        case shift:
            return emitShift(ins, op);

        case arrayEqual:
            return emitArrayEqual(i, ins, original);

        case sliceFill:
            return emitSliceFill(ins);
        }
    }

    static struct IntegerRight {
        Mem memory;
        ulong bits;
        bool constant;
    }

    bool integerRight(size_t raw, bool literal, int width, ubyte scratch,
        out IntegerRight right)
    {
        if (literal) {
            right.constant = true;
            right.bits = constantAt(raw, width);
        } else if (known.covers(raw, width)) {
            usedKnown = true;
            right.constant = true;
            right.bits = known.bits;
        } else
            return opnd(raw, scratch, right.memory);
        return true;
    }

    // Resolve the address slots in the order destination, left, right.
    bool binary(in Instruction ins, bool twoAddress, bool literalRight,
        bool leftInReg, bool destInReg, int width, out Mem d, out Mem l,
        out IntegerRight right)
    {
        if (!destInReg && !opnd(ins.destination, R9, d))
            return false;
        if (twoAddress)
            l = d;
        else if (!leftInReg && !opnd(ins.source, R10, l))
            return false;
        return integerRight(integerRightOperand(ins, twoAddress),
            literalRight, width, R11, right);
    }

    static size_t integerRightOperand(in Instruction ins, bool twoAddress) {
        return twoAddress ? ins.source : ins.sourceWidth;
    }

    bool emitArrayEqual(size_t i, in Instruction ins,
        Instruction.Handler original)
    {
        if (!goodWidth(ins.width))
            return false;
        Mem d, s;
        if (!opnd(ins.destination, R9, d) || !opnd(ins.source, R10, s))
            return false;

        a.ld(8, RAX, Mem(d.base, d.disp + cast(int) arrayLengthOffset));
        a.alu(Alu.cmp, 8, RAX,
            Mem(s.base, s.disp + cast(int) arrayLengthOffset));
        const differentLengths = jccLocal(CC_NE);
        a.aluRI(Alu.cmp, 8, RAX, 0);
        const empty = jccLocal(CC_E);
        a.aluRI(Alu.cmp, 8, RAX, 1);
        const multipleElements = jccLocal(CC_NE);

        // A one-element comparison can read exactly the bytes in each slice.
        // The handler keeps the memcmp path for longer slices.
        a.ld(8, R11, Mem(s.base, s.disp + cast(int) arrayPointerOffset));
        a.ld(8, R10, Mem(d.base, d.disp + cast(int) arrayPointerOffset));
        const width = cast(int) ins.width;
        a.ld(width, RAX, Mem(R10, 0));
        a.alu(Alu.cmp, width, RAX, Mem(R11, 0));
        patchHere(differentLengths);
        patchHere(empty);
        a.setcc(CC_E, d);
        jmpTo(i + 1);

        patchHere(multipleElements);
        jumpToHandler(i, original);
        return true;
    }

    bool emitSliceFill(in Instruction ins) {
        if (ins.width != 1)
            return false;
        Mem dest, value;
        if (!opnd(ins.destination, R9, dest) || !opnd(ins.source, R10, value))
            return false;

        a.ld(8, R11, Mem(dest.base, dest.disp + cast(int) arrayLengthOffset));
        a.ld(8, R9, Mem(dest.base, dest.disp + cast(int) arrayPointerOffset));
        a.aluRI(Alu.cmp, 8, R11, 0);
        const empty = jccLocal(CC_E);
        a.ld(1, RAX, value);

        // REP STOSB uses RCX and RDI, which can hold live handler arguments.
        a.movRR64(R10, RCX);
        static if (REG0 == RDI)
            a.movRR64(SC2, RDI);
        a.movRR64(RCX, R11);
        a.movRR64(RDI, R9);
        a.repStosb;
        static if (REG0 == RDI)
            a.movRR64(RDI, SC2);
        a.movRR64(RCX, R10);
        patchHere(empty);
        return true;
    }

    int cachedInt(in Mem m, int w) {
        const reg = intSlots.find(m, w);
        readIntSlot |= reg >= 0;
        return reg;
    }

    void finishCopy(in Mem dest, int width, bool carryCopy) {
        if (carryCopy)
            intSlots.forget(dest, width);
        else
            intSlots = IntSlots.init;
    }

    void storeInt(in Mem dest, int w, int reg, bool rememberCopy = false) {
        a.st(w, dest, reg);
        if (rememberCopy)
            intSlots.rememberCopy(dest, w, reg);
        else
            intSlots = dest.base == FRAME
                ? IntSlots(IntSlot(dest.disp, w, reg)) : IntSlots.init;
    }

    void emitIntCast(in Mem dest, int width, in Mem src, int sourceWidth,
        bool zeroExtend)
    {
        const cached = cachedInt(src, sourceWidth);
        const reg = cached >= 0 ? cached : RAX;
        if (cached < 0) {
            if (zeroExtend)
                a.ldzx(sourceWidth, reg, src);
            else
                a.ldsx(sourceWidth, reg, src);
        } else if (zeroExtend) {
            if (sourceWidth < 8)
                a.movzxRR(sourceWidth, reg, reg);
        } else
            a.movsxRR(sourceWidth, reg);
        storeInt(dest, width, reg);
    }

    static int intScratch(int avoid) pure @safe {
        return avoid == RAX ? SC2 : RAX;
    }

    static Alu aluOf(JitOp.IntOperation operation) {
        import snakebite.failure.report: internalFailure;

        final switch (operation) with (JitOp.IntOperation) {
            case add: return Alu.add;
            case or: return Alu.or;
            case and: return Alu.and;
            case subtract: return Alu.sub;
            case xor: return Alu.xor;
            case multiply:
                internalFailure("a multiplication is not an ALU op");
        }
    }

    bool emitInt3(in Instruction ins, in JitOp op) {
        const p = op.int3;
        const w = cast(int) (op.width ? op.width : ins.width);
        if (!goodWidth(w))
            return false;
        Mem d, l;
        IntegerRight rhs;
        if (!binary(ins, p.twoAddress, p.constantRight, p.leftInR0,
                p.resultInR0, w, d, l, rhs))
            return false;
        const sameCell = !p.leftInR0 && !p.resultInR0 && p.constantRight
            && (ins.destination & indirectBit)
            && (p.twoAddress || ins.source == ins.destination);
        auto left = p.leftInR0 ? REG0 : cachedInt(l, w);
        if (emittingPath) {
            if (sameCell)
                left = pathScalarLeft(l, w);
            else if (ins.destination & indirectBit)
                forgetPathValue;
        }
        const rightReg = rhs.constant ? -1 : cachedInt(rhs.memory, w);
        const acc = p.resultInR0 ? REG0
            : left >= 0 && left != REG0 ? left : intScratch(rightReg);
        const scratch = acc == SC2 ? RAX : SC2;
        emitIntegerArithmetic(w, p.operation, l, left, rhs, rightReg, acc, scratch);
        if (p.resultInR0)
            intSlots = IntSlots.init;
        else
            storeInt(d, w, acc);
        if (emittingPath && sameCell)
            a.movRR64(REG0, acc);
        return true;
    }

    void emitIntegerArithmetic(int w, JitOp.IntOperation operation,
        in Mem l, int left, in IntegerRight rhs, int rightReg, int acc, int scratch)
    {
        int imm = 0;
        bool haveImm;
        if (rhs.constant)
            haveImm = immOf(w, rhs.bits, imm);
        const mul = operation == JitOp.IntOperation.multiply;
        const narrowMul = mul && w < 4;
        if (left >= 0) {
            if (narrowMul)
                a.movzxRR(w, acc, left);
            else if (acc != left)
                a.movRR64(acc, left);
        } else if (narrowMul)
            a.ldzx(w, acc, l);
        else
            a.ld(w, acc, l);
        if (mul) {
            const mw = w == 8 ? 8 : 4;
            if (rhs.constant) {
                if (narrowMul || !haveImm) {
                    a.movI(scratch, rhs.bits);
                    a.imulRR(mw, acc, scratch);
                } else {
                    // `imulRI` is 64-bit; for 4 bytes that is still right in
                    // the low 32 bits.
                    a.imulRI(acc, acc, imm);
                }
            } else if (rightReg >= 0) {
                if (narrowMul && rightReg != acc)
                    a.movzxRR(w, rightReg, rightReg);
                a.imulRR(mw, acc, rightReg);
            } else if (narrowMul) {
                a.ldzx(w, scratch, rhs.memory);
                a.imulRR(4, acc, scratch);
            } else
                a.imulM(mw, acc, rhs.memory);
        } else if (rhs.constant) {
            if (haveImm)
                a.aluRI(aluOf(operation), w, acc, imm);
            else {
                a.movI(scratch, rhs.bits);
                a.aluRR(aluOf(operation), w, acc, scratch);
            }
        } else if (rightReg >= 0)
            a.aluRR(aluOf(operation), w, acc, rightReg);
        else
            a.alu(aluOf(operation), w, acc, rhs.memory);
    }

    int pathScalarLeft(in Mem left, int width) {
        // All runtime values still have their ordinary memory representation.
        // Retain a non-frame cell so that frame and window stores cannot alias
        // it. A different cell exits before reading or writing either one.
        a.lea(RAX, left);
        if (retainedWidth == width) {
            a.xmmToInteger(SC2, pathAddress);
            a.aluRR(Alu.cmp, 8, RAX, SC2);
            pathMemoryGuard = jccLocal(CC_NE);
            reusedAcrossCall |= retainedAcrossCall;
            return REG0;
        }

        a.integerToXmm(pathAddress, RAX);
        a.ld(8, R11, Mem(STATE, DispatchState.frames.offsetof));
        a.ld(8, SC2, Mem(R11, FrameStack.baseOffset));
        a.aluRI(Alu.sub, 8, SC2, width - 1);
        a.aluRR(Alu.sub, 8, RAX, SC2);
        a.ld(8, R11, Mem(R11, FrameStack.fastEndOffset));
        a.aluRR(Alu.sub, 8, R11, SC2);
        a.aluRR(Alu.cmp, 8, RAX, R11);
        pathMemoryGuard = jccLocal(CC_B);
        retainedWidth = width;
        retainedAcrossCall = false;
        return -1;
    }

    bool emitSignedDivide(in Instruction ins, in JitOp op) {
        const p = op.signedDivide;
        if (!goodWidth(ins.width))
            return false;
        const w = cast(int) ins.width;
        const divideWidth = w == 8 || (w == 4 && p.widenInt) ? 8 : 4;
        Mem d, l;
        IntegerRight right;
        if (!binary(ins, p.twoAddress, p.constantRight,
                leftInReg: false, destInReg: false, w, d, l, right))
            return false;
        if (right.constant && w == 4 && divideWidth == 4
                && emitSigned32Constant(d, l, cast(int) right.bits, p.remainder))
            return true;
        if (w == divideWidth)
            a.ld(w, RAX, l);
        else
            a.ldsx(w, RAX, l);
        if (right.constant) {
            int imm;
            const divisor = w != divideWidth && immOf(w, right.bits, imm)
                ? cast(ulong) imm : right.bits;
            a.movI(R11, divisor);
        } else if (w != divideWidth)
            a.ldsx(w, R11, right.memory);

        // idiv uses rdx for the dividend and remainder. Save the VM state
        // until the result is stored. The hardware reports the same faults
        // as the handler.
        a.movRR64(SC2, STATE);
        a.extendDividend(divideWidth);
        if (right.constant || w != divideWidth)
            a.idivR(divideWidth, R11);
        else
            a.idivM(divideWidth, right.memory);
        a.st(w, d, p.remainder ? RDX : RAX);
        a.movRR64(STATE, SC2);
        return true;
    }

    bool emitSigned32Constant(in Mem d, in Mem l, int divisor,
        bool remainder)
    {
        import core.bitop: bsr;

        // Leave divide by zero and int.min / -1 to the hardware.
        if (divisor == 0 || divisor == -1)
            return false;
        const magnitude = divisor < 0 ? -cast(uint) divisor : cast(uint) divisor;
        if (magnitude == 1) {
            a.ld(4, RAX, l);
            if (remainder)
                a.stI(4, d, 0);
            else
                a.st(4, d, RAX);
            return true;
        }

        const log = cast(ubyte) bsr(magnitude);
        if ((magnitude & (magnitude - 1)) == 0) {
            // Bias a negative dividend before rounding down with sar.
            const mask = cast(int) (magnitude - 1);
            a.ld(4, RAX, l);
            a.movRR64(R10, RAX);
            if (log == 1)
                a.shiftRightI(4, false, R10, 31);
            else {
                a.shiftRightI(4, true, R10, 31);
                a.aluRI(Alu.and, 4, R10, mask);
            }
            a.aluRR(Alu.add, 4, RAX, R10);
            if (remainder) {
                a.aluRI(Alu.and, 4, RAX, mask);
                a.aluRR(Alu.sub, 4, RAX, R10);
            } else {
                a.shiftRightI(4, true, RAX, log);
                if (divisor < 0)
                    a.rrOp(4, byteReg: false, 3, RAX, 0xF7); // neg
            }
            a.st(4, d, RAX);
            return true;
        }

        // For M = ceil(S / magnitude), require M*magnitude - S < S/2^31.
        // Then multiplying a nonzero |dividend| by M/S rounds up by less
        // than 1/magnitude, so the product lies strictly between the
        // absolute quotient and its successor. A negative product needs
        // one added after sar to round toward zero.
        auto shift = cast(ubyte) (31 + log);
        auto scale = 1UL << shift;
        auto multiplier = scale / magnitude + 1;
        if (multiplier * magnitude - scale >= (scale >> 31)) {
            ++shift;
            scale <<= 1;
            multiplier = scale / magnitude + 1;
        }
        a.ldsx(4, RAX, l);
        if (multiplier <= int.max)
            a.imulRI(R10, RAX, cast(int) multiplier);
        else {
            a.movI(R10, multiplier);
            a.imulRR(8, R10, RAX);
        }
        a.shiftRightI(8, true, R10, shift);
        const sign = remainder ? R11 : RAX;
        if (remainder)
            a.movRR64(sign, RAX);
        a.shiftRightI(4, false, sign, 31);
        a.aluRR(Alu.add, 4, R10, sign);
        if (remainder) {
            a.imulRI(R10, R10, cast(int) magnitude);
            a.aluRR(Alu.sub, 4, RAX, R10);
            a.st(4, d, RAX);
        } else {
            if (divisor < 0)
                a.rrOp(4, byteReg: false, 3, R10, 0xF7); // neg
            a.st(4, d, R10);
        }
        return true;
    }

    bool emitCmp3(in Instruction ins, in JitOp op) {
        const p = op.cmp3;
        const w = cast(int) (op.width ? op.width : ins.width);
        if (!goodWidth(w))
            return false;
        Mem d, l;
        IntegerRight right;
        if (!binary(ins, p.twoAddress, p.constantRight,
                leftInReg: false, destInReg: false, w, d, l, right))
            return false;
        emitIntCompare(w, l, right, leftInR0: false);
        a.setcc(p.signed ? signedCc(p.comparison) : unsignedCc(p.comparison),
            d);
        return true;
    }

    int emitIntCompare(int w, in Mem l, in IntegerRight right, bool leftInR0) {
        int left = leftInR0 ? REG0 : cachedInt(l, w);
        const rightReg = right.constant ? -1 : cachedInt(right.memory, w);
        if (left < 0) {
            left = intLoop.contains(intLoopInstruction)
                ? R9 : intScratch(rightReg);
            a.ld(w, left, l);
        }
        emitIntegerCompare(w, left, right, rightReg, intScratch(left));
        if (!intLoop.contains(intLoopInstruction))
            intSlots = IntSlots.init;
        return left;
    }

    void emitIntegerCompare(int w, int left, in IntegerRight right, int rightReg,
        int scratch)
    {
        if (right.constant) {
            const value = right.bits;
            int imm;
            if (immOf(w, value, imm))
                a.aluRI(Alu.cmp, w, left, imm);
            else {
                a.movI(scratch, value);
                a.aluRR(Alu.cmp, w, left, scratch);
            }
        } else if (rightReg >= 0)
            a.aluRR(Alu.cmp, w, left, rightReg);
        else
            a.alu(Alu.cmp, w, left, right.memory);
    }

    static int integerBranchCc(in JitOp.Fused op) {
        const cc = op.kind == CompareKind.signed
            ? signedCc(op.comparison) : unsignedCc(op.comparison);
        return op.jumpWhen ? cc : cc ^ 1;
    }

    bool emitFused(in Instruction ins, in JitOp.Fused p, size_t t,
        size_t localTarget = 0, size_t fallthrough = size_t.max,
        size_t pathNext = size_t.max, size_t* pathExit = null,
        size_t* pathJump = null, const(JitOp)[] indexOps = null,
        size_t predecessor = size_t.max)
    {
        const w = cast(int) ins.width;
        Mem l;
        if (p.kind != CompareKind.floating) {
            if (!goodWidth(w))
                return false;
            // R10 resolves the right address, so the cached left base stays
            // live until the compare loads it.
            if (!p.leftInR0
                    && !opnd!(/*reusePointer*/ true)(ins.destination, R9, l))
                return false;
            IntegerRight right;
            if (!integerRight(ins.source, p.constantRight, w, R10, right))
                return false;
            const left = emitIntCompare(w, l, right, p.leftInR0);
            const cc = integerBranchCc(p);
            if (pathNext == size_t.max) {
                if (indexOps.length && inlineCaller is null && !checkedLoop.update
                        && !fpLoop.backedge && !intLoop.backedge && !p.leftInR0
                        && w == size_t.sizeof && l.base == FRAME
                        && (right.constant || right.memory.base == FRAME)) {
                    const supplied = IntSlots(IntSlot(l.disp, w, left));
                    if (!localTarget && t < predecessor && indexReads(t, indexOps, l))
                        localTarget = indexBody(t, supplied);
                    if (indexOps[predecessor].kind == JitOp.Kind.fused
                            && indexReads(predecessor + 1, indexOps, l))
                        intSlots = supplied;
                }
                jccIntLoop(cc, t, localTarget);
            } else {
                if (pathNext == t) {
                    *pathExit = fallthrough;
                    *pathJump = jccLocal(cc ^ 1);
                } else if (pathNext == fallthrough) {
                    *pathExit = t;
                    *pathJump = jccLocal(cc);
                } else
                    return false;
            }
            return true;
        }
        if (w != 8 && w != 4)
            return false;
        const prefix = w == 8 ? doublePrefix : singlePrefix;
        const comparePrefix = w == 8 ? operandSizePrefix : noPrefix;
        if (!p.leftInR0 && !opnd(ins.destination, R9, l))
            return false;
        FloatRight right;
        if (!floatRight(R10, ins.source, p.constantRight, right))
            return false;
        int leftX = p.leftInR0 ? fp0Register : fpSlots.find(l, w);
        if (leftX < 0) {
            a.sse(prefix, loadOpcode, XMM1, l);
            leftX = XMM1;
        }
        int rightX = right.literalAddress ? -1 : fpSlots.find(right.memory, w);
        // Reverse less-than comparisons so unordered sets the carry flag.
        if (p.comparison == Comparison.lessThan
                || p.comparison == Comparison.lessOrEqual) {
            if (rightX < 0) {
                sseRight(w, prefix, loadOpcode, XMM2, right);
                rightX = XMM2;
            }
            a.sseRR(comparePrefix, compareOpcode, rightX, leftX);
        } else if (rightX >= 0)
            a.sseRR(comparePrefix, compareOpcode, leftX, rightX);
        else
            sseRight(w, comparePrefix, compareOpcode, leftX, right);
        final switch (p.comparison) with (Comparison) {
            case greaterThan:
            case greaterOrEqual:
            case lessThan:
            case lessOrEqual: {
                const strict = p.comparison == greaterThan
                    || p.comparison == lessThan;
                int cc = strict ? CC_A : CC_AE;
                if (!p.jumpWhen)
                    cc ^= 1;
                jccTo(cc, t);
                break;
            }
            case equal:
            case notEqual: {
                const eq = p.comparison == equal;
                if (eq == p.jumpWhen) {
                    // Jump when ZF=1 and PF=0.
                    const skip = jccLocal(CC_P);
                    jccTo(CC_E, t);
                    patchHere(skip);
                } else {
                    jccTo(CC_P, t);
                    jccTo(CC_NE, t);
                }
            }
        }
        return true;
    }

    bool indexReads(size_t i, const(JitOp)[] ops, in Mem slot) const {
        if (i >= ops.length || ops[i].kind != JitOp.Kind.index)
            return false;
        ref const ins = snapshot[i];
        Mem frame;
        return ins.sourceWidth == slot.disp && frameOperand(ins.source, frame)
            && frameOperand(ins.destination, frame);
    }

    size_t indexBody(size_t target, in IntSlots supplied) const {
        // Reload entries are recorded in bytecode order. The public label
        // still holds the body address until the stubs are emitted.
        size_t first, end = reloadEntryCount;
        while (first < end) {
            const middle = first + (end - first) / 2;
            ref const entry = reloadEntryScratch.ptr[middle];
            if (entry.index < target)
                first = middle + 1;
            else if (entry.index > target)
                end = middle;
            else
                return entry.fpSlots.empty && entry.intSlots == supplied
                    ? labels[target] : 0;
        }
        return 0;
    }

    bool carryIndexToRegion(size_t i, const(JitOp)[] ops, in Mem dest, int width) {
        if (intSlots.empty || i == 0 || ops[i - 1].kind != JitOp.Kind.index
                || dest.base != FRAME || intSlots.overlaps(dest, width))
            return false;
        Mem receiver;
        if (!intRegionReceiver(i + 1, ops, receiver)
                || intSlots.find(receiver, size_t.sizeof) < 0)
            return false;
        // Dispatch skips the index template that supplied the receiver.
        readIntSlot = true;
        return true;
    }

    bool intRegionReceiver(size_t first, const(JitOp)[] ops, out Mem pointerSlot) const {
        if (first >= ops.length
                || (ops[first].kind != JitOp.Kind.int3 && ops[first].kind != JitOp.Kind.copy)
                || !(snapshot[first].destination & indirectBit))
            return false;
        Mem firstDest;
        return storageOperand(snapshot[first].destination, IntRegion.pointer,
            firstDest, pointerSlot) && pointerSlot.disp + size_t.sizeof <= frameSize;
    }

    size_t emitIntRegion(size_t first, const(JitOp)[] ops,
        const(Instruction.Handler)[] originals)
    {
        IntRegion region;
        if (!intRegionReceiver(first, ops, region.writes.slot)
                || !planIntRegion(first, ops, originals, region)
                || codeLimit - a.n - literalBytes
                    < 64 * (region.length + 1) + maximumBytesPerInstruction)
            return first;

        // Both paths start with canonical frame state. The fallback can
        // enter after the guard has changed scratch registers.
        fpSlots = FpSlots.init;
        known = KnownConstant.init;
        const width = IntRegion.width;
        const pointer = IntRegion.pointer;
        const writes = region.writes;
        const cached = intSlots.find(writes.slot, size_t.sizeof);
        if (cached < 0)
            a.ld(size_t.sizeof, pointer, writes.slot);
        else {
            addReloadEntry(first, fpSlots, intSlots);
            if (cached != pointer)
                a.movRR64(pointer, cached);
        }
        intSlots = IntSlots.init;
        const overlap = receiverOverlap(pointer, writes,
            writes.slot.disp, size_t.sizeof);
        foreach (ref const step; region.steps[0 .. region.length]) {
            ref const op = ops[step.pc];
            ref const ins = snapshot[step.pc];
            IntegerRight right;
            right.memory = step.right;
            right.constant = step.literal;
            if (step.literal) {
                const raw = step.target == size_t.max
                    ? integerRightOperand(ins, op.int3.twoAddress) : ins.source;
                right.bits = constantAt(raw, width);
            }

            switch (op.kind) with (JitOp.Kind) {
                case int3:
                    emitIntegerArithmetic(width, op.int3.operation, step.left,
                        step.leftReg, right, step.rightReg, step.result, RAX);
                    a.st(width, step.dest, step.result);
                    break;
                case copy:
                    if (step.leftReg < 0)
                        a.ld(width, step.result, step.left);
                    a.st(width, step.dest, step.result);
                    break;
                case fused:
                    const left = step.leftReg >= 0 ? step.leftReg : RAX;
                    if (step.leftReg < 0)
                        a.ld(width, left, step.left);
                    emitIntegerCompare(width, left, right, step.rightReg, RAX);
                    if (step.target != step.pc + 1) {
                        const cc = integerBranchCc(op.fused);
                        const taken = step.next == step.target;
                        jccTo(taken ? cc ^ 1 : cc,
                            taken ? step.pc + 1 : step.target);
                    }
                    break;
                default:
                    assert(0);
            }
        }
        const last = region.steps[region.length - 1];
        jmpTo(last.next);
        patchHere(overlap);
        return last.pc + 1;
    }

    bool planIntRegion(size_t first, const(JitOp)[] ops,
        const(Instruction.Handler)[] originals, ref IntRegion region)
    {
        const width = IntRegion.width;
        const pointerSlot = region.writes.slot;
        IntSlots slots;
        slots.base = IntRegion.pointer;
        int pointerLoads, fieldLoads, moves;
        size_t pc = first;
        while (region.length < region.steps.length) {
            IntRegion.Step step;
            if (!intRegionStep(pc, ops, originals, pointerSlot, slots, step))
                break;
            pointerLoads += step.pointerLoads;
            fieldLoads += (step.leftReg >= 0) + (step.rightReg >= 0);
            if (step.target == size_t.max) {
                region.writes.include(step.dest.disp, width);
                step.result = step.leftReg >= 0
                        && (ops[pc].kind == JitOp.Kind.copy || step.left == step.dest)
                    ? step.leftReg : slots.copyRegister;
                if (step.result == step.rightReg && step.result != step.leftReg)
                    step.result = step.result == R11 ? SC2 : R11;
                moves += step.leftReg >= 0 && step.leftReg != step.result;
                slots.rememberCopy(step.dest, width, step.result);
            } else if (step.target != step.next) {
                // Prefer a successor that can use a retained value now.
                // A tie leaves both successors to their ordinary entries.
                const taken = intRegionUse(step.target, ops, originals, pointerSlot, slots);
                const fall = intRegionUse(step.next, ops, originals, pointerSlot, slots);
                if (taken >= fall)
                    step.next = step.target;
                if (taken == fall) {
                    region.steps[region.length++] = step;
                    break;
                }
            }
            region.steps[region.length++] = step;
            pc = step.next;
        }
        // The receiver load, overlap test and final transfer have a fixed cost.
        enum overhead = 6;
        return fieldLoads > 0 && pointerLoads + fieldLoads > overhead + moves;
    }

    int intRegionUse(size_t pc, const(JitOp)[] ops,
        const(Instruction.Handler)[] originals, in Mem pointerSlot, in IntSlots slots)
    {
        IntRegion.Step step;
        return intRegionStep(pc, ops, originals, pointerSlot, slots, step)
            ? (step.leftReg >= 0) + (step.rightReg >= 0) : 0;
    }

    bool intRegionStep(size_t pc, const(JitOp)[] ops,
        const(Instruction.Handler)[] originals, in Mem pointerSlot,
        in IntSlots slots, out IntRegion.Step step)
    {
        if (pc >= ops.length || originals[pc] is null)
            return false;
        ref const op = ops[pc];
        ref const ins = snapshot[pc];
        const width = IntRegion.width;
        if ((op.width ? op.width : ins.width) != width)
            return false;
        step.pc = pc;
        step.next = pc + 1;
        size_t left, right;
        bool sameAddress;
        // These storage operations have no atomic or volatile effects.
        // Any handler or template that can synchronize ends the region.
        switch (op.kind) with (JitOp.Kind) {
            case int3:
                if (op.int3.leftInR0 || op.int3.resultInR0)
                    return false;
                sameAddress = op.int3.twoAddress;
                left = sameAddress ? ins.destination : ins.source;
                right = integerRightOperand(ins, sameAddress);
                step.literal = op.int3.constantRight;
                break;
            case copy:
                if (op.copy.staticSource)
                    return false;
                left = ins.source;
                break;
            case fused:
                if (op.fused.leftInR0 || op.fused.kind == CompareKind.floating
                        || !targetIndex(ins.sourceWidth, step.target)
                        || step.target <= pc)
                    return false;
                left = ins.destination;
                right = ins.source;
                step.literal = op.fused.constantRight;
                break;
            default:
                return false;
        }

        if (step.target == size_t.max && !intRegionOperand(ins.destination,
                pointerSlot, step.dest))
            return false;
        if (!intRegionOperand(left, pointerSlot, step.left))
            return false;
        step.leftReg = slots.find(step.left, width);
        step.pointerLoads = (step.target == size_t.max) + !sameAddress;
        if (op.kind != JitOp.Kind.copy && !step.literal) {
            if (!intRegionOperand(right, pointerSlot, step.right))
                return false;
            step.rightReg = slots.find(step.right, width);
            ++step.pointerLoads;
        }
        return true;
    }

    static bool intRegionOperand(size_t raw, in Mem pointerSlot, out Mem value) {
        Mem address;
        return (raw & indirectBit)
            && storageOperand(raw, IntRegion.pointer, value, address)
            && address == pointerSlot;
    }

    size_t receiverOverlap(int pointer, in ReceiverRange range,
        int protectedFirst, size_t protectedWidth)
    {
        // Compare the last written byte with the start of the protected slot.
        // Unsigned subtraction detects overlap at either end of the slot.
        a.lea(RAX, Mem(cast(ubyte) pointer, range.end - 1 - protectedFirst));
        a.aluRR(Alu.sub, size_t.sizeof, RAX, FRAME);
        const span = protectedWidth + range.end - range.first - 1;
        a.aluRI(Alu.cmp, size_t.sizeof, RAX, cast(int) span);
        return jccLocal(CC_B);
    }

    size_t emitFpRegion(size_t first, const(JitOp)[] ops,
        const(Instruction.Handler)[] originals)
    {
        import snakebite.backends.bytecode.emitted: EmittedCode;

        FpRegion region;
        const end = planFpRegion(first, ops, originals, region);
        if (region.length < 4 || codeLimit - a.n - literalBytes
                < 128 + 64 * region.length + maximumBytesPerInstruction)
            return end;

        const ranges = region.ranges.entries[0 .. region.ranges.count];
        foreach (ref const step; region.steps[0 .. region.length]) {
            if (step.fp.resultInFp0 || step.destination.base != FRAME)
                continue;
            foreach (ref const range; ranges)
                if (EmittedCode.overlaps(step.destination.disp, FpRegion.width,
                        range.slot.disp, size_t.sizeof))
                    return end;
        }

        size_t[FpRegion.pointerRegisters.length] misses;
        foreach (i, ref const range; ranges) {
            const pointer = FpRegion.pointerRegisters[i];
            a.ld(size_t.sizeof, pointer, range.slot);
            misses[i] = receiverOverlap(pointer, range, 0, frameSize);
        }

        ScalarFpSlots!(2, 14) slots;
        foreach (ref const step; region.steps[0 .. region.length]) {
            const left = step.fp.leftInFp0 ? fp0Register
                : slots.find(step.left, FpRegion.width);
            const right = step.kind == FpRegion.Kind.arithmetic
                && !step.literalAddress ? slots.find(step.right, FpRegion.width) : -1;
            const acc = step.fp.resultInFp0 ? fp0Register
                : step.destination.base == FRAME
                    ? slots.assign(step.destination, FpRegion.width, left, right)
                    : XMM1;
            final switch (step.kind) with (FpRegion.Kind) {
                case arithmetic:
                    emitFpArithmetic(FpRegion.width, step.fp.operation, acc,
                        step.left, left, FloatRight(step.right, step.literalAddress), right);
                    break;
                case copy:
                    emitFpMove(doublePrefix, acc, step.left, left);
                    break;
                case squareRoot:
                    enum ubyte sqrtOpcode = 0x51;
                    if (left >= 0)
                        a.sseRR(doublePrefix, sqrtOpcode, acc, left);
                    else
                        a.sse(doublePrefix, sqrtOpcode, acc, step.left);
                    break;
            }
            // Keep frame and indirect stores in order even if an FP trap
            // can observe the frame before the next instruction.
            if (!step.fp.resultInFp0)
                a.sse(doublePrefix, storeOpcode, acc, step.destination);
        }
        jmpTo(end);
        foreach (miss; misses[0 .. ranges.length])
            patchHere(miss);
        return end;
    }

    size_t planFpRegion(size_t first, const(JitOp)[] ops,
        const(Instruction.Handler)[] originals, ref FpRegion region)
    {
        import snakebite.backends.bytecode.vm: opFloatSqrt;

        if (frameSize > int.max / 2)
            return first;
        foreach (pc; first .. ops.length) {
            if (region.length == FpRegion.instructionLimit || originals[pc] is null)
                break;
            ref const op = ops[pc];
            ref const ins = snapshot[pc];
            FpRegion.Step step;
            // Only a complete instruction can add to the entry guards.
            auto ranges = region.ranges;
            if (op.kind == JitOp.Kind.fp3 && ins.width == FpRegion.width) {
                step.fp = op.fp3;
                if (step.fp.constantRight)
                    step.literalAddress = ins.sourceWidth;
                else if (!fpRegionOperand(ins.sourceWidth, ranges, step.right))
                    break;
            } else if (op.kind == JitOp.Kind.copy && !op.copy.staticSource
                    && (op.width ? op.width : ins.width) == FpRegion.width
                    && !isLiteralCopy(ins, op, FpRegion.width)) {
                step.kind = FpRegion.Kind.copy;
            } else {
                // The DMD host's double sqrt uses x87, including its
                // control word, intermediate precision and exception flags.
                version (LDC) {
                    if (originals[pc] !is &opFloatSqrt || ins.width != FpRegion.width)
                        break;
                    step.kind = FpRegion.Kind.squareRoot;
                } else
                    break;
            }
            const source = step.kind == FpRegion.Kind.squareRoot
                ? ins.destination : ins.source;
            if ((!step.fp.leftInFp0 && !fpRegionOperand(source, ranges, step.left))
                    || (!step.fp.resultInFp0
                        && !fpRegionOperand(ins.destination, ranges, step.destination)))
                break;

            region.ranges = ranges;
            region.steps[region.length++] = step;
        }
        return first + region.length;
    }

    bool fpRegionOperand(size_t raw, ref FpRegion.Ranges ranges,
        out Mem memory) const {
        Mem slot;
        if (!storageOperand(raw, FpRegion.pointerRegisters[0], memory, slot))
            return false;
        if (!(raw & indirectBit))
            return memory.disp + FpRegion.width <= frameSize;
        if (slot.disp + size_t.sizeof > frameSize)
            return false;
        size_t i;
        for (; i < ranges.count; ++i)
            if (ranges.entries[i].slot.disp == slot.disp)
                break;
        if (i == ranges.count) {
            if (i == ranges.entries.length)
                return false;
            ++ranges.count;
            ranges.entries[i] = ReceiverRange(slot);
        }
        ranges.entries[i].include(memory.disp, FpRegion.width);
        memory.base = FpRegion.pointerRegisters[i];
        return true;
    }

    bool emitFp3(in Instruction ins, in JitOp op) {
        const p = op.fp3;
        const w = cast(int) ins.width;
        if (w != 8 && w != 4)
            return false;
        if (p.leftInFp0 && w != 8)
            return false;
        Mem d, l;
        if (!p.resultInFp0 && !opnd(ins.destination, R9, d))
            return false;
        if (!p.leftInFp0 && !opnd(ins.source, R10, l))
            return false;
        FloatRight right;
        if (!floatRight(R11, ins.sourceWidth, p.constantRight, right))
            return false;
        const left = p.leftInFp0 ? fp0Register : fpSlots.find(l, w);
        const rightReg = right.literalAddress ? -1
            : fpSlots.find(right.memory, w);
        int acc = fp0Register;
        if (!p.resultInFp0)
            acc = d.base == FRAME ? fpSlots.assign(d, w, left, rightReg) : XMM1;
        emitFpArithmetic(w, p.operation, acc, l, left, right, rightReg);
        if (!p.resultInFp0) {
            a.sse(w == 8 ? doublePrefix : singlePrefix, storeOpcode, acc, d);
            if (d.base != FRAME)
                refreshFpAfterStore(d, w);
        }
        return true;
    }

    void emitFpArithmetic(int width, JitOp.FloatOperation operation,
        int acc, in Mem left, int leftReg, in FloatRight right, int rightReg)
    {
        const prefix = width == 8 ? doublePrefix : singlePrefix;
        emitFpMove(prefix, acc, left, leftReg);
        if (rightReg >= 0)
            a.sseRR(prefix, _floatOpcodes[operation], acc, rightReg);
        else
            sseRight(width, prefix, _floatOpcodes[operation], acc, right);
    }

    void emitFpMove(ubyte prefix, int acc, in Mem source, int reg) {
        if (reg < 0)
            a.sse(prefix, loadOpcode, acc, source);
        else if (acc != reg)
            a.sseRR(noPrefix, moveAlignedOpcode, acc, reg);
    }

    private void refreshFpAfterStore(in Mem destination, int width) {
        long first, end;
        if (!fpSlots.bounds(first, end))
            return;

        // A store starting before the first slot can still reach its first byte.
        const bias = width - 1;
        const displacement = destination.disp - first + bias;
        const span = end - first + bias;
        if (displacement < int.min || displacement > int.max || span > int.max) {
            fpSlots = FpSlots.init;
            return;
        }

        // The store can overwrite the frame word that supplied its address.
        a.lea(R10, Mem(destination.base, cast(int) displacement,
            destination.index, destination.scale));
        a.aluRR(Alu.sub, long.sizeof, R10, FRAME);
        a.aluRI(Alu.cmp, long.sizeof, R10, cast(int) span);
        const miss = jccLocal(CC_AE);
        fpSlots.reload(a);
        patchHere(miss);
    }

    bool emitFpCmp3(in Instruction ins, in JitOp op) {
        const p = op.fpcmp3;
        const w = cast(int) ins.width;
        if (w != 8 && w != 4)
            return false;
        const prefix = w == 8 ? doublePrefix : singlePrefix;
        const comparePrefix = w == 8 ? operandSizePrefix : noPrefix;
        Mem d, l;
        if (!opnd(ins.destination, R9, d) || !opnd(ins.source, R10, l))
            return false;
        FloatRight right;
        if (!floatRight(R11, ins.sourceWidth, p.constantRight, right))
            return false;
        a.sse(prefix, loadOpcode, XMM1, l);
        final switch (p.comparison) with (Comparison) {
            case greaterThan:
            case greaterOrEqual:
                sseRight(w, comparePrefix, compareOpcode, XMM1, right);
                a.setcc(p.comparison == greaterThan ? CC_A : CC_AE, d);
                break;
            case lessThan:
            case lessOrEqual:
                sseRight(w, prefix, loadOpcode, XMM2, right);
                a.sseRR(comparePrefix, compareOpcode, XMM2, XMM1);
                a.setcc(p.comparison == lessThan ? CC_A : CC_AE, d);
                break;
            case equal:
                sseRight(w, comparePrefix, compareOpcode, XMM1, right);
                a.setccR(CC_E, RAX);
                a.setccR(CC_NP, SC2);
                a.aluRR(Alu.and, 1, RAX, SC2);
                a.st(1, d, RAX);
                break;
            case notEqual:
                sseRight(w, comparePrefix, compareOpcode, XMM1, right);
                a.setccR(CC_NE, RAX);
                a.setccR(CC_P, SC2);
                a.aluRR(Alu.or, 1, RAX, SC2);
                a.st(1, d, RAX);
        }
        return true;
    }

    enum checkedLength = R9;
    enum checkedLimit = R10;
    enum checkedStep = R11;

    bool emitCheckedLoop(size_t i, in Instruction ins, in JitOp op,
        Instruction.Handler original)
    {
        const slice = cast(int) ins.source;
        a.ld(8, SC2, Mem(FRAME, slice + cast(int) arrayPointerOffset));
        a.ld(8, checkedLength, Mem(FRAME, slice + cast(int) arrayLengthOffset));
        a.movRR64(RAX, SC2);
        a.aluRR(Alu.add, 8, RAX, checkedLength);
        const wrap = jccLocal(CC_B);

        a.lea(checkedLimit, Mem(FRAME, checkedLoop.protectedStart));
        a.aluRR(Alu.cmp, 8, RAX, checkedLimit);
        const before = jccLocal(CC_BE);
        a.lea(checkedLimit, Mem(FRAME, checkedLoop.protectedEnd));
        a.aluRR(Alu.cmp, 8, SC2, checkedLimit);
        const after = jccLocal(CC_AE);

        patchHere(wrap);
        jumpToHandler(i, original);
        patchHere(before);
        patchHere(after);

        a.ldsx(4, checkedLimit, Mem(FRAME, checkedLoop.limitSlot));
        a.ldsx(4, checkedStep, Mem(FRAME, checkedLoop.stepSlot));
        const offset = cast(int) (ins.width >> 32);
        emitCountedByteLoop(ins, offset);

        a.ld(4, RAX, Mem(FRAME, checkedLoop.indexSlot));
        // The bounds check consumes k + offset. Bias the step so its
        // next 32-bit add produces k + step, including on wraparound.
        if (offset)
            a.aluRI(Alu.sub, 4, checkedStep, offset);
        checkedLoop.body = a.n;
        return emitChecked!true(i, ins, op);
    }

    void emitCountedByteLoop(in Instruction ins, int offset) {
        const index = Mem(FRAME, checkedLoop.indexSlot);
        a.aluRI(Alu.cmp, 8, checkedStep, 0);
        const nonpositive = jccLocal(CC_LE);
        a.ldsx(4, RAX, index);
        a.aluRI(Alu.cmp, 8, RAX, 0);
        const negative = jccLocal(CC_L);
        a.aluRR(Alu.cmp, 8, RAX, checkedLimit);
        const pastLimit = jccLocal(CC_G);

        // A positive step makes the endpoint checks sufficient for each store.
        a.lea(RAX, Mem(RAX, offset));
        a.aluRI(Alu.cmp, 8, RAX, 0);
        const below = jccLocal(CC_L);
        a.lea(RAX, Mem(checkedLimit, offset));
        a.aluRI(Alu.cmp, 8, RAX, int.max);
        const offsetWrap = jccLocal(CC_G);
        a.aluRR(Alu.cmp, 8, RAX, checkedLength);
        const above = jccLocal(CC_AE);
        a.lea(RAX, Mem(checkedLimit, 0, checkedStep));
        a.aluRI(Alu.cmp, 8, RAX, int.max);
        const stepWrap = jccLocal(CC_G);

        a.ld(4, RAX, index);
        const body = a.n;
        const element = Mem(SC2, offset, RAX);
        storeConstant(ubyte.sizeof, element, constantAt(ins.destination, ubyte.sizeof));
        a.aluRR(Alu.add, 4, RAX, checkedStep);
        a.aluRR(Alu.cmp, 4, RAX, checkedLimit);
        jccTo(CC_LE, 0, body);
        a.st(4, index, RAX);
        jmpTo(checkedLoop.update + 2);

        foreach (miss; [nonpositive, negative, pastLimit, below, offsetWrap, above, stepWrap])
            patchHere(miss);
    }

    void emitCheckedLoopUpdate() {
        patchHere(checkedLoop.updateFixup);
        a.aluRR(Alu.add, 4, RAX, checkedStep);
        a.st(4, Mem(FRAME, checkedLoop.indexSlot), RAX);
    }

    void emitCheckedLoopBackedge() {
        a.aluRR(Alu.cmp, 4, RAX, checkedLimit);
        jccTo(CC_LE, 0, checkedLoop.body);
        checkedLoop = CheckedLoop.init;
        known = KnownConstant.init;
        intSlots = IntSlots.init;
        fpSlots = FpSlots.init;
    }

    // A successful load can establish the bounds of later accesses on its
    // own edge. Their ordinary entry points still need their own checks.
    size_t forwardedLoad(size_t target, in Instruction first, in JitOp op,
        in Mem destination, const(JitOp)[] ops)
    {
        if (op.checked.access != CheckedAccess.load || destination.base != FRAME)
            return size_t.max;
        const indexWidth = op.checked.indexWidth;
        const firstIndex = cast(int) cast(uint) first.width;

        foreach (attempt; 0 .. 4) {
            const next = snapshot[target];
            const kind = ops[target];
            if (kind.kind != JitOp.Kind.checked || next.source != first.source
                    || next.width >> 32 != first.width >> 32
                    || kind.checked.fixedLength != op.checked.fixedLength
                    || kind.checked.indexWidth != indexWidth
                    || kind.checked.signed != op.checked.signed)
                break;
            const index = cast(uint) next.width;
            if (index > 0x7fff_0000
                    || frameWriteOverlaps(destination, op.width, cast(int) index,
                        indexWidth))
                break;
            if (kind.checked.access == CheckedAccess.load) {
                Mem result;
                if (kind.width == op.width && frameOperand(next.destination, result))
                    return target;
                break;
            }

            size_t success;
            if (kind.checked.access != CheckedAccess.check || index != firstIndex
                    || !targetIndex(next.sourceWidth, success) || success <= target)
                break;
            target = success;
        }
        return size_t.max;
    }

    static bool frameWriteOverlaps(in Mem destination, int width, int offset,
        int size) pure @safe
    {
        return destination.disp < offset + size && offset < destination.disp + width;
    }

    void emitForwardedLoad(size_t firstSuccess, size_t load, in Instruction first,
        in JitOp op, in Mem destination, in Mem source, in Mem element)
    {
        const next = snapshot[load];
        const secondIndex = cast(int) cast(uint) next.width;
        if (secondIndex != cast(uint) first.width) {
            const indexWidth = op.checked.indexWidth;
            const offset = op.checked.fixedLength ? 0 : cast(int) (first.width >> 32);
            int index = RAX;
            if (offset) {
                a.movRR64(R9, RAX);
                a.aluRI(Alu.sub, indexWidth, R9, offset);
                index = R9;
            }
            a.alu(Alu.cmp, indexWidth, cast(ubyte) index, Mem(FRAME, secondIndex));
            jccTo(CC_NE, firstSuccess);
        }
        if (!op.checked.fixedLength && source.base != FRAME)
            guardForwardedRead(destination, op.width, source,
                arrayPointerOffset + (ubyte*).sizeof, firstSuccess);
        // An overlapping frame write could change bytes in the element that
        // the next load would see, even though the two indices are equal.
        guardForwardedRead(destination, op.width, element, op.width, firstSuccess);
        a.st(op.width, Mem(FRAME, cast(int) next.destination), R11);
        size_t success;
        targetIndex(next.sourceWidth, success);
        jmpTo(success);
    }

    void guardForwardedRead(in Mem destination, int width, Mem read, int size,
        size_t fallback)
    {
        read.disp -= destination.disp - (size - 1);
        a.lea(R9, read);
        a.aluRR(Alu.sub, 8, R9, FRAME);
        a.aluRI(Alu.cmp, 8, R9, width + size - 1);
        jccTo(CC_B, fallback);
    }

    bool emitChecked(bool resident = false)(
        size_t i, in Instruction ins, in JitOp op,
        size_t pathNext = size_t.max, size_t* pathJump = null,
        const(JitOp)[] ops = null,
        const(PathChecked)* path = null,
    ) {
        const p = op.checked;
        const packed = ins.width;
        const idxOff = cast(uint) packed;
        const hi = packed >> 32;
        const es = op.width;
        const access = p.access;
        const specialized = path !is null;
        const skipBounds = specialized && path.skipBounds;
        const skipStore = specialized && path.skipStore;
        const forwarded = specialized && path.forwarded != size_t.max;
        const needElement = access != CheckedAccess.check && !skipStore;
        const needIndex = (needElement && !forwarded)
            || (access != CheckedAccess.storeUnchecked && !skipBounds);
        size_t target;
        Mem d, s;
        static if (!resident) {
            if (idxOff > 0x7fff_0000
                    || (access != CheckedAccess.storeUnchecked
                        && !targetIndex(ins.sourceWidth, target)))
                return false;
            if (needElement && !p.constantValue
                    && !opnd(ins.destination, R9, d))
                return false;
            if (!specialized && !opnd(ins.source, R10, s))
                return false;
        }
        const onPath = pathNext != size_t.max;
        if (onPath && pathNext != (access == CheckedAccess.storeUnchecked
                ? i + 1 : target))
            return false;
        const idx = Mem(FRAME, cast(int) idxOff);
        const offset = p.fixedLength ? 0 : cast(int) hi;
        if (needIndex && (resident || p.indexWidth == 4)) {
            static if (!resident) {
                a.ld(4, RAX, idx);
                // Sign extension follows, and the slice needs no address setup.
                if (access == CheckedAccess.store && p.constantValue && p.signed
                        && !p.fixedLength && s.base == FRAME)
                    checkedEntry = CheckedEntry(i, a.n);
            }
            if (offset != 0)
                a.aluRI(Alu.add, 4, RAX, offset);
            if (p.signed)
                a.rrOp(8, byteReg: false, RAX, RAX, signExtend32Opcode);
        } else if (needIndex) {
            a.ld(8, RAX, idx);
            if (offset != 0)
                a.aluRI(Alu.add, 8, RAX, offset);
        }
        size_t failJump = size_t.max;
        static if (resident) {
            a.aluRR(Alu.cmp, 8, RAX, checkedLength);
            jccTo(CC_AE, i + 1);
        } else if (access != CheckedAccess.storeUnchecked && !skipBounds) {
            if (specialized) {
                a.xmmToInteger(SC2, pathLength);
                a.aluRR(Alu.cmp, 8, RAX, SC2);
            } else if (p.fixedLength) {
                if (hi <= int.max)
                    a.aluRI(Alu.cmp, 8, RAX, cast(int) hi);
                else {
                    a.movI(SC2, hi);
                    a.aluRR(Alu.cmp, 8, RAX, SC2);
                }
            } else
                a.alu(Alu.cmp, 8, RAX, Mem(s.base, s.disp + cast(int) arrayLengthOffset));
            failJump = jccLocal(CC_AE);
        }
        bool threaded;
        if (needElement) {
            Mem element;
            static if (!resident) {
                if (forwarded) {
                    if (!opnd(path.forwarded, R10, element))
                        return false;
                } else if (specialized)
                    a.xmmToInteger(SC2, pathPointer);
                else if (p.fixedLength)
                    a.lea(SC2, s);
                else
                    a.ld(8, SC2, Mem(s.base,
                        s.disp + cast(int) arrayPointerOffset));
            }
            if (!forwarded)
                element = Mem(SC2, 0, RAX, cast(ubyte) es);
            if (onPath && retainedWidth != 0 && access != CheckedAccess.load) {
                a.lea(R11, element);
                a.xmmToInteger(R10, pathAddress);
                a.aluRR(Alu.sub, 8, R11, R10);
                a.aluRI(Alu.add, 8, R11, es - 1);
                a.aluRI(Alu.cmp, 8, R11, retainedWidth + es - 1);
                pathMemoryGuard = jccLocal(CC_B);
            }
            if (access == CheckedAccess.load) {
                a.ld(es, R11, element);
                a.st(es, d, R11);
                static if (!resident) {
                    if (!onPath && target > i && d.base == FRAME) {
                        const sourceSlot = cast(int) ((ins.source >> 32) & 0x7fff_ffff);
                        const sourceStable = s.base == FRAME
                            ? p.fixedLength || !frameWriteOverlaps(d, es, s.disp,
                                arrayPointerOffset + (ubyte*).sizeof)
                            : !frameWriteOverlaps(d, es, sourceSlot, (ubyte*).sizeof);
                        if (sourceStable) {
                            const load = forwardedLoad(target, ins, op, d, ops);
                            size_t success;
                            if (load != size_t.max
                                    && targetIndex(snapshot[load].sourceWidth, success)
                                    && success > load)
                                emitForwardedLoad(target, load, ins, op, d, s, element);
                        }
                        if (es == 1 && !checkedLoop.update && !fpLoop.backedge
                                && !intLoop.backedge)
                            threaded = emitByteOutcomes(target, ins.destination, ops);
                    }
                }
            } else if (p.constantValue) {
                int imm;
                const v = constantAt(ins.destination, es);
                if (immOf(es, v, imm))
                    a.stI(es, element, imm);
                else {
                    a.movI(R11, v);
                    a.st(8, element, R11);
                }
            } else {
                a.ld(es, R11, d);
                a.st(es, element, R11);
            }
        }
        static if (resident) {
            a.b(0xE9);
            checkedLoop.updateFixup = a.n;
            a.d32(0);
        } else {
            if (onPath)
                *pathJump = failJump == size_t.max ? 0 : failJump;
            else {
                if (access != CheckedAccess.storeUnchecked && !threaded)
                    jmpTo(target);
                if (failJump != size_t.max)
                    patchHere(failJump);
            }
        }
        return true;
    }

    bool emitByteOutcomes(size_t first, size_t source, const(JitOp)[] ops) {
        if (first >= ops.length || source >= frameSize)
            return false;
        const op = ops[first];
        const ins = snapshot[first];
        if (op.kind != JitOp.Kind.branch || opWidth(ins, op) != 1
                || ins.destination != source)
            return false;
        const zero = branchSuccessor(first, op.branch, false);
        const nonzero = branchSuccessor(first, op.branch, true);
        if (zero <= first || nonzero <= first
                || zero == size_t.max || nonzero == size_t.max)
            return false;

        size_t budget = inlineCaller is null ? BranchOnly.limit - 1 : 0;
        const whenZero = planByteOutcome(zero, source, false, ops, budget);
        const whenNonzero = planByteOutcome(nonzero, source, true, ops, budget);
        // Both edges carry the byte from the checked load. A test of the
        // byte establishes its truth value but does not normalize it.
        enum ubyte testByteOpcode = 0x84;
        a.rrOp(1, byteReg: true, R11, R11, testByteOpcode);
        if (whenZero.next == zero && whenNonzero.next == nonzero) {
            jccTo(op.branch.jumpIfNonzero ? CC_NE : CC_E,
                op.branch.jumpIfNonzero ? nonzero : zero);
            jmpTo(first + 1);
        } else if (whenNonzero.count == 0) {
            jccTo(CC_NE, whenNonzero.next);
            emitByteOutcome(whenZero);
        } else if (whenZero.count == 0) {
            jccTo(CC_E, whenZero.next);
            emitByteOutcome(whenNonzero);
        } else {
            const nonzeroJump = jccLocal(CC_NE);
            emitByteOutcome(whenZero);
            patchHere(nonzeroJump);
            emitByteOutcome(whenNonzero);
        }
        return true;
    }

    static struct ByteOutcome {
        size_t next;
        size_t count;
        size_t[BranchOnly.limit] stores;

        bool knows(size_t slot, size_t source, size_t pendingStores)
        const pure nothrow @nogc @safe
        {
            if (slot == source)
                return true;
            foreach (destination; stores[0 .. pendingStores])
                if (slot == destination)
                    return true;
            return false;
        }
    }

    ByteOutcome planByteOutcome(size_t first, size_t source, bool nonzero,
        const(JitOp)[] ops, ref size_t budget)
    {
        ByteOutcome plan;
        plan.next = first;
        size_t stores;
        for (auto pc = first; pc < ops.length && budget != 0;) {
            --budget;
            const ins = snapshot[pc];
            const op = ops[pc];
            if (opWidth(ins, op) != 1)
                break;
            if (op.kind == JitOp.Kind.branch
                    && plan.knows(ins.destination, source, stores)) {
                const next = branchSuccessor(pc, op.branch, nonzero);
                if (next <= pc || next == size_t.max)
                    break;
                // Keep copies after the last bypassed branch at their own entry.
                plan.next = next;
                plan.count = stores;
                pc = next;
                continue;
            }
            Mem destination;
            if (op.kind != JitOp.Kind.copy || op.copy.staticSource
                    || !plan.knows(ins.source, source, stores)
                    || ins.destination >= frameSize
                    || !frameOperand(ins.destination, destination))
                break;
            plan.stores[stores++] = ins.destination;
            ++pc;
        }
        return plan;
    }

    void emitByteOutcome(in ByteOutcome plan) {
        foreach (destination; plan.stores[0 .. plan.count])
            a.st(1, Mem(FRAME, cast(int) destination), R11);
        jmpTo(plan.next);
    }

    bool emitShift(in Instruction ins, in JitOp op) {
        const p = op.shift;
        const w = cast(int) (op.width ? op.width : ins.width);
        if (!goodWidth(w))
            return false;
        Mem d, l;
        IntegerRight right;
        if (!binary(ins, p.twoAddress, p.constantRight,
                leftInReg: false, destInReg: false, w, d, l, right))
            return false;
        if (!right.constant && !bmi2)
            return false;
        if (p.kind == JitOp.ShiftKind.arithmeticRight)
            a.ldsx(w, RAX, l);
        else
            a.ldzx(w, RAX, l);
        if (right.constant) {
            a.shiftImmediate(p.kind, 8, RAX, cast(ubyte) shiftCount(right.bits, w));
            a.st(w, d, RAX);
            return true;
        }
        a.ldzx(w, SC2, right.memory);
        a.aluRI(Alu.and, 4, SC2, cast(int) shiftCount(ulong.max, w));
        a.shiftVariable(p.kind, 8, RAX, RAX, SC2);
        a.st(w, d, RAX);
        return true;
    }
}


private enum Emitted { done, failed, full }
