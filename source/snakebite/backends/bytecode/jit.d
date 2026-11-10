module snakebite.backends.bytecode.jit;

// The template JIT of the bytecode VM (docs/adr/0016-template-jit.md).
//
// A hot function gets x86-64 code for each instruction that has a template,
// with the operands as immediates. The address of the code of instruction i
// replaces `instructions[i].handler`. The code obeys the `Instruction.Handler`
// calling convention (see the register map below). It has no stack frame,
// makes no call and uses only the scratch registers, so r0 and fp0 survive,
// and a throw needs no unwind information: it happens only in real handlers,
// which the JIT code reaches by a tail jump. An instruction without a
// template gets a stub that sets `pc` and jumps to its handler.
//
// The emitter allocates nothing per instruction (it works in reused buffers),
// because the cost of a compile is paid at run time.

private:


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
        fpcmp3, index, checked, castFixed, widen, loadInd, storeInd,
        frameAddr, staticLoad, staticStore, staticAddr, boolOp, unary, shift,
        callWindow, returnValue, returnVoid,
    }

    enum IntOperation : ubyte { add, or, and, subtract, xor, multiply }
    enum FloatOperation : ubyte { add, subtract, multiply, divide }
    enum ShiftKind : ubyte { left, logicalRight, arithmeticRight }

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


// What the JIT keeps from one compile to the next. It belongs to the JIT lock:
// only `JitLock.owned` gives access to it.
private struct JitState {
    import snakebite.backends.bytecode.vm: Function, Instruction;

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

    Emitted emitFunction(Function* function_,
        const(Instruction)[] snapshot, const(JitOp)[] ops,
        const(Instruction.Handler)[] originals)
    {
        import core.atomic: atomicStore, MemoryOrder;

        const instructions = function_.instructions;
        const start = region.chunkUsed;
        const cap = region.chunkCapacity - start;
        Gen g;
        g.a.buf = region.writeBase + start;
        g.fixupScratch = &fixups;
        g.literalScratch = &literals;
        g.bmi2 = bmi2;
        g.instructions = instructions;
        g.snapshot = snapshot;
        g.constants = function_.constants;
        g.callSites = function_.callSites;
        auto labelMemory = labels.reserve(instructions.length + 1);
        if (labelMemory is null)
            return Emitted.failed;
        g.labels = labelMemory[0 .. instructions.length + 1];
        g.fixups = fixups.ptr;
        g.fixupCap = fixups.cap;

        foreach (i; 0 .. instructions.length) {
            if (cap - g.a.n - g.literalBytes < maximumBytesPerInstruction)
                return Emitted.full;
            g.labels[i] = g.a.n;
            const saved = g.a.n;
            const savedFixups = g.fixupCount;
            const savedLiterals = g.literalCount;
            bool done;
            if (originals[i] !is null && ops[i].kind != JitOp.Kind.none)
                done = g.emitOp(i, ops[i], originals[i]);
            if (g.outOfMemory)
                return Emitted.failed;
            if (!done) {
                g.a.n = saved;
                g.fixupCount = savedFixups;
                g.literalCount = savedLiterals;
                if (originals[i] is null)
                    g.a.ud2();
                else
                    g.jumpToHandler(i, originals[i]);
            }
        }
        if (cap - g.a.n - g.literalBytes < codeAlignment)
            return Emitted.full;
        if (g.literalCount && g.a.n + g.literalBytes + Asm.ud2Size > int.max)
            return Emitted.failed;
        g.labels[instructions.length] = g.a.n;
        g.a.ud2();
        g.emitLiterals;

        foreach (f; g.fixups[0 .. g.fixupCount])
            *cast(int*) (g.a.buf + f.position) = cast(int) (
                g.labels[f.target] - (f.position + 4));

        const size = (g.a.n + codeAlignment - 1) & ~(codeAlignment - 1UL);
        region.chunkUsed = start + size;
        if (region.chunkUsed + populateSize / 4 > region.populatedEnd)
            region.populate;

        const code = region.execBase + start;
        if (function_.jitName.length)
            perfMap.record(code, g.a.n, function_.jitName);
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

private shared JitState _jitState;

private struct PerfMap {
    import core.stdc.stdio: FILE;
    import core.sys.posix.sys.types: pid_t;

    @nogc nothrow:

    private FILE* _file;
    private pid_t _pid;

    void record(in ubyte* code, in size_t size, in char[] name) {
        import core.stdc.stdio: fclose, fflush, fprintf, fputc, perror;
        import core.sys.posix.unistd: getpid;

        const pid = getpid();
        if (pid != _pid) {
            if (_file !is null)
                fclose(_file);
            _pid = pid;
            _file = openMap(pid);
        }
        if (_file is null)
            return;
        if (fprintf(_file, "%zx %zx ", cast(size_t) code, size) < 0
                || !writeSymbol(name) || fputc('\n', _file) < 0
                || fflush(_file) != 0) {
            perror("snakebite: cannot write JIT perf map");
            fclose(_file);
            _file = null;
        }
    }

    private static FILE* openMap(in pid_t pid) {
        import core.stdc.stdio: perror, snprintf;
        import core.sys.posix.fcntl: O_CLOEXEC, O_CREAT, O_EXCL, O_WRONLY, open;
        import core.sys.posix.stdio: fdopen;
        import core.sys.posix.sys.stat: S_IRUSR, S_IWUSR;
        import core.sys.posix.unistd: close;

        char[64] path;
        snprintf(path.ptr, path.length, "/tmp/perf-%d.map", pid);
        const descriptor = open(path.ptr,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR);
        if (descriptor < 0) {
            perror(path.ptr);
            return null;
        }
        auto file = fdopen(descriptor, "w"); // The writer needs a mutable FILE.
        if (file is null) {
            perror(path.ptr);
            close(descriptor);
        }
        return file;
    }

    private bool writeSymbol(in char[] name) {
        import core.stdc.stdio: fputs, fwrite;

        size_t start;
        foreach (index, character; name) {
            if (character != '\r' && character != '\n')
                continue;
            const length = index - start;
            const escape = character == '\r' ? "\\r" : "\\n";
            if (fwrite(name.ptr + start, char.sizeof, length, _file) != length
                    || fputs(escape.ptr, _file) < 0)
                return false;
            start = index + 1;
        }
        const length = name.length - start;
        return fwrite(name.ptr + start, char.sizeof, length, _file) == length;
    }
}

// The code region. It is a memfd file that grows by chunks. Each chunk is
// mapped twice: `writeBase` is read+write, where the JIT emits, and `execBase`
// is read+execute, where the handlers point. No page changes protection.
// Functions are packed with 16-byte alignment, and a function never spans two
// chunks. Memory is made present (`MADV_POPULATE_*`) a part of a chunk at a
// time.
private struct CodeRegion {
    import core.sys.posix.sys.types: pid_t;

    @nogc nothrow:

    private pid_t _process;
    int file = -1;
    size_t fileSize;
    ubyte* writeBase;
    ubyte* execBase;
    size_t chunkCapacity;
    size_t chunkUsed;
    size_t populatedEnd;

    bool prepare() {
        import core.sys.posix.sys.mman: munmap;
        import core.sys.posix.unistd: close, getpid;

        const process = getpid();
        if (process == _process)
            return file >= 0;

        // After fork the copied cursor would write into the parent's file.
        // Keep the execute views because the child still uses their handlers.
        if (file >= 0) {
            munmap(writeBase, chunkCapacity);
            close(file);
        }
        this = CodeRegion.init;
        _process = process;

        file = memfd_create("snakebite-jit", MFD_CLOEXEC);
        if (file < 0)
            return false;
        if (newChunk(chunkSize))
            return true;
        close(file);
        file = -1;
        return false;
    }

    // Makes a chunk of at least `bytes` the current one. The old chunks stay
    // mapped: their code is in use.
    bool newChunk(size_t bytes) {
        import core.sys.posix.sys.mman: MAP_FAILED, MAP_SHARED, mmap, munmap,
            PROT_EXEC, PROT_READ, PROT_WRITE;
        import core.sys.posix.unistd: ftruncate;

        const size = (bytes + chunkSize - 1) & ~(chunkSize - 1);
        if (ftruncate(file, fileSize + size) != 0)
            return false;
        // `auto`: `munmap` takes a mutable pointer.
        auto write = mmap(null, size, PROT_READ | PROT_WRITE, MAP_SHARED,
            file, fileSize);
        auto execute = mmap(null, size, PROT_READ | PROT_EXEC, MAP_SHARED,
            file, fileSize);
        if (write is MAP_FAILED || execute is MAP_FAILED) {
            if (write !is MAP_FAILED)
                munmap(write, size);
            if (execute !is MAP_FAILED)
                munmap(execute, size);
            return false;
        }
        fileSize += size;
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
private enum maximumBytesPerInstruction = 1024;
// Druntime and Phobos declare none of these: no `memfd_create`, no
// `MFD_CLOEXEC`, no `MADV_POPULATE_*`, and `core.sys.linux.sys.mman` declares
// `madvise` only when `_DEFAULT_SOURCE` is true, which it is not for glibc.
private enum MADV_POPULATE_READ = 22;
private enum MADV_POPULATE_WRITE = 23;
private enum MFD_CLOEXEC = 1;

extern(C) private int madvise(void*, size_t, int) nothrow @nogc;
extern(C) private int memfd_create(const(char)* name, uint flags) nothrow @nogc;

// How far the one-time set-up got: nothing, a usable JIT, or a JIT that this
// process cannot have (no memfd). It is read without the lock.
private enum Setup : int { pending, ready, unavailable }
private shared Setup _setup;

private shared int _lockWord;

// The JIT lock. A thread takes it without waiting: a thread that waits for the
// lock can wait for a thread that the GC suspended while it held the lock. The
// lock is released when the `JitLock` that holds it goes out of scope.
package struct JitLock {
    import snakebite.backends.bytecode.vm: Function, Instruction;

    @nogc nothrow:

    private bool _held;

    @disable this(this);

    package static JitLock tryTake() {
        import core.atomic: cas;

        JitLock lock;
        lock._held = cas(&_lockWord, 0, 1);
        return lock;
    }

    ~this() {
        import core.atomic: atomicStore, MemoryOrder;

        if (_held)
            atomicStore!(MemoryOrder.rel)(_lockWord, 0);
    }

    package bool held() const {
        return _held;
    }

    // `state`, which belongs to the JIT lock, for the thread that holds it.
    package ref T owned(T)(return ref shared T state) {
        import snakebite.internalfailure: internalFailure;

        if (!_held)
            internalFailure("JIT state used without the JIT lock");
        return *cast(T*) &state;
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
        const(Instruction.Handler)[] originals)
    {
        if (snapshot.length == 0)
            return false;
        ref state = owned(_jitState);
        auto result = state.emitFunction(function_, snapshot, ops, originals);
        if (result == Emitted.full) {
            const worst = snapshot.length * maximumBytesPerInstruction
                + 4096;
            if (!state.region.newChunk(worst))
                return false;
            result = state.emitFunction(function_, snapshot, ops, originals);
        }
        return result == Emitted.done;
    }
}

// True when a function can get JIT code. The first call sets the JIT up:
// the CPU features, the region, and the check of the calling convention.
package bool jitUsable(ref JitLock lock) {
    import core.atomic: atomicLoad, atomicStore, MemoryOrder;

    final switch (atomicLoad!(MemoryOrder.acq)(_setup)) {
        case Setup.ready: return lock.owned(_jitState).region.prepare;
        case Setup.unavailable: return false;
        case Setup.pending:
            break;
    }
    ref state = lock.owned(_jitState);
    const ok = state.region.prepare;
    if (ok)
        checkCallingConvention(state.region);
    state.bmi2 = ok && cpuHasBmi2;
    atomicStore!(MemoryOrder.rel)(_setup, ok ? Setup.ready : Setup.unavailable);
    return ok;
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
    import snakebite.internalfailure: internalFailure;
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

// A growable buffer that lives as long as the process; compiles reuse it.
package struct Scratch(T) {
    T* ptr;
    size_t cap;

    // At least `n` elements; the contents are undefined. Null if no memory.
    T* reserve(size_t n) {
        import core.stdc.stdlib: free, malloc;

        if (n > cap) {
            auto newCap = cap ? cap : 1024;
            while (newCap < n)
                newCap *= 2;
            free(ptr);
            ptr = cast(T*) malloc(newCap * T.sizeof);
            cap = ptr is null ? 0 : newCap;
        }
        return ptr;
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
}

private struct Gen {
    import snakebite.backends.bytecode.vm: Activation, CallSite,
        chainedDispatch, CheckedAccess, CompareKind, Comparison, Destination,
        DispatchState, Function, indirectBit, IndexBase, Instruction;
    import snakebite.framestack: FrameStack;
    import snakebite.nativevalue: arrayLengthOffset, arrayPointerOffset;

    @nogc nothrow:

    Asm a;
    Scratch!Fixup* fixupScratch;
    Scratch!Literal* literalScratch;
    bool bmi2;
    const(Instruction)[] instructions;
    const(Instruction)[] snapshot;
    const(long)[] constants;
    const(CallSite)[] callSites;
    size_t[] labels;
    Fixup* fixups;
    size_t fixupCount;
    size_t fixupCap;
    size_t literalCount;
    bool outOfMemory;

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

    void jccTo(int cc, size_t target) {
        a.b(0x0F);
        a.b(cast(ubyte) (0x80 + cc));
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

    void patchHere(size_t p) {
        *cast(int*) (a.buf + p) = cast(int) (a.n - (p + 4));
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
    bool opnd(size_t raw, ubyte scratch, out Mem m) {
        if (raw & indirectBit) {
            const slot = (raw >> 32) & 0x7fff_ffff;
            const disp = cast(uint) raw;
            if (slot > 0x7fff_0000 || disp > 0x7fff_0000)
                return false;
            a.ld(8, scratch, Mem(FRAME, cast(int) slot));
            m = Mem(scratch, cast(int) disp);
            return true;
        }
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

    bool emitCallWindow(size_t i, in JitOp.CallWindow op,
        Instruction.Handler original)
    {
        import core.atomic: atomicLoad, MemoryOrder;

        const ins = snapshot[i];
        const site = &callSites[ins.source];
        const fast = &site.fast;
        // Preparing a site may compile guest bytecode. Only read facts that
        // the handler has published and that will stay valid for this site.
        if (atomicLoad!(MemoryOrder.acq)(
                *cast(shared(uint)*) &fast.state) != CallSite.FastCall.State.ready)
            return false;
        const callee = fast.callee;
        const hasPlace = callee.returnPlace.offset != size_t.max;
        const hasWindows = callee.windowSlot != size_t.max;
        if (site.windowSlot > int.max || site.windowDisp > int.max
                || site.windowScratch > int.max || fast.frameBytes > int.max
                || fast.frameOffset > int.max || fast.reachBytes > int.max
                || (hasPlace && fast.placeStore > int.max)
                || (hasWindows && (fast.windowStore > int.max
                    || fast.windowBase > int.max)))
            return false;

        a.ld(8, R9, Mem(STATE, DispatchState.frames.offsetof));
        a.ld(8, R10, Mem(FRAME, cast(int) site.windowSlot));
        a.lea(R11, Mem(R10, cast(int) site.windowDisp));
        a.lea(RAX, Mem(R11, cast(int) fast.reachBytes));
        a.alu(Alu.cmp, 8, RAX, Mem(R9, FrameStack.fastEndOffset));
        const grow = jccLocal(CC_A);

        a.movI(PCREG, cast(size_t) callee);
        size_t tierUp;
        if (op.counted) {
            const heat = Mem(PCREG, Function.jitHeat.offsetof);
            a.ld(4, RAX, heat);
            a.aluRI(Alu.add, 4, RAX, jitStep);
            // Let the counting handler perform the event on carry.
            tierUp = jccLocal(CC_B);
            a.st(4, heat, RAX);
        }
        a.st(8, Mem(R11, Activation.function_.offsetof), PCREG);

        Mem place;
        if (op.destination == Destination.discard)
            place = Mem(R10, cast(int) site.windowScratch);
        else if (!opnd(ins.destination, RAX, place))
            return false;
        a.lea(RAX, place);
        a.st(8, Mem(R11, Activation.returnPlace.offsetof), RAX);
        a.lea(FRAME, Mem(R11, cast(int) fast.frameOffset));
        a.st(8, Mem(R11, Activation.frame.offsetof), FRAME);
        if (hasPlace)
            a.st(8, Mem(FRAME, cast(int) fast.placeStore), RAX);
        if (hasWindows) {
            a.lea(RAX, Mem(R11, cast(int) fast.windowBase));
            a.st(8, Mem(FRAME, cast(int) fast.windowStore), RAX);
        }

        a.ld(8, RAX, Mem(R9, FrameStack.topOffset));
        a.alu(Alu.sub, 8, RAX, Mem(R9, FrameStack.baseOffset));
        a.st(8, Mem(R11, Activation.frameMark.offsetof), RAX);
        a.lea(RAX, Mem(R11, cast(int) fast.frameBytes));
        a.st(8, Mem(R9, FrameStack.topOffset), RAX);
        a.ld(8, RAX, Mem(R9, FrameStack.cleanupMarkOffset));
        a.st(8, Mem(R11, Activation.cleanupMark.offsetof), RAX);

        // A throw from the callee uses the call site in the parent.
        a.movI(PCREG, cast(size_t) &instructions[i]);
        a.st(8, Mem(ACTIVE, Activation.pc.offsetof), PCREG);
        a.lea(RAX, Mem(PCREG, Instruction.sizeof));
        a.st(8, Mem(ACTIVE, Activation.resume.offsetof), RAX);
        a.st(8, Mem(R11, Activation.parent.offsetof), ACTIVE);
        a.movI(PCREG, cast(size_t) callee.instructions.ptr);
        a.st(8, Mem(R11, Activation.pc.offsetof), PCREG);
        a.st(8, Mem(STATE, DispatchState.current.offsetof), R11);
        a.movRR64(ACTIVE, R11);
        a.jmpM(Mem(PCREG, Instruction.handler.offsetof));

        patchHere(grow);
        if (op.counted)
            patchHere(tierUp);
        jumpToHandler(i, original);
        return true;
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

        if (hasValue && ins.width != 0) {
            Mem source;
            if (!opnd(ins.source, SC2, source))
                return false;
            a.ld(8, R11, Mem(ACTIVE, Activation.returnPlace.offsetof));
            a.aluRI(Alu.cmp, 8, R11, 0);
            const discard = jccLocal(CC_E);
            a.lea(RAX, source);
            a.aluRR(Alu.cmp, 8, RAX, R11);
            const aliased = jccLocal(CC_E);
            copyChunks(source, Mem(R11, 0), ins.width);
            patchHere(aliased);
            patchHere(discard);
        }

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

    // The value of `width` bytes at a constant-pool address, zero-extended.
    static ulong constantAt(size_t address, int w) {
        switch (w) {
            case 1: return *cast(const ubyte*) address;
            case 2: return *cast(const ushort*) address;
            case 4: return *cast(const uint*) address;
            default: return *cast(const ulong*) address;
        }
    }

    // Whether `value`, of width `w`, is an immediate of an ALU op.
    static bool immOf(int w, ulong value, out int imm) {
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

    void jumpToHandler(size_t i, Instruction.Handler handler) {
        // The unchained dispatcher gets its register arguments from the state.
        static if (!chainedDispatch) {
            a.st(8, Mem(STATE, DispatchState.r0.offsetof), REG0);
            a.sse(doublePrefix, storeOpcode, fp0Register,
                Mem(STATE, DispatchState.fp0.offsetof));
        }
        a.movI(PCREG, cast(size_t) &instructions[i]);
        a.movI(RAX, cast(size_t) handler);
        a.jmpRax;
    }

    bool emitOp(size_t i, in JitOp op, Instruction.Handler original) {
        const ins = snapshot[i];
        final switch (op.kind) with (JitOp.Kind) {
        case none:
            return false;

        case callWindow:
            return emitCallWindow(i, op.callWindow, original);

        case returnValue:
        case returnVoid:
            return emitReturn(i, op.kind == returnValue, original);

        case copy: {
            const size = op.width ? op.width : ins.width;
            if (size > 64)
                return false;
            Mem d, s;
            if (!opnd(ins.destination, R9, d))
                return false;
            if (op.copy.staticSource) {
                a.movI(R10, ins.source);
                s = Mem(R10, 0);
            } else if (!opnd(ins.source, R10, s))
                return false;
            copyChunks(s, d, size);
            return true;
        }

        case constant: {
            const w = ins.width;
            if (!goodWidth(w) || ins.source >= constants.length)
                return false;
            Mem d;
            if (!opnd(ins.destination, R9, d))
                return false;
            const value = cast(ulong) constants[ins.source];
            int imm;
            if (immOf(cast(int) w, value, imm))
                a.stI(cast(int) w, d, imm);
            else {
                a.movI(RAX, value);
                a.st(8, d, RAX);
            }
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
            return true;
        }

        case jump: {
            size_t t;
            if (!targetIndex(ins.destination, t))
                return false;
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
            a.aluMI(Alu.cmp, cast(int) w, d, 0);
            jccTo(op.branch.jumpIfNonzero ? CC_NE : CC_E, t);
            return true;
        }

        case int3:
            return emitInt3(ins, op);
        case cmp3:
            return emitCmp3(ins, op);
        case fused:
            return emitFused(ins, op);
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
            a.ld(8, SC2, r);
            if (es == 1 || es == 2 || es == 4 || es == 8)
                a.lea(RAX, Mem(RAX, 0, SC2, cast(ubyte) es));
            else {
                a.imulRI(SC2, SC2, cast(int) es);
                a.aluRR(Alu.add, 8, RAX, SC2);
            }
            a.st(8, d, RAX);
            return true;
        }

        case checked:
            return emitChecked(ins, op);

        case castFixed: {
            Mem d, s;
            if (!opnd(ins.destination, R9, d) || !opnd(ins.source, R10, s))
                return false;
            if (op.castFixed.zeroExtend)
                a.ldzx(op.castFixed.sourceSize, RAX, s);
            else
                a.ldsx(op.castFixed.sourceSize, RAX, s);
            a.st(op.width, d, RAX);
            return true;
        }

        case widen: {
            // In place: the source width is in `source`, the width in `width`.
            if (!goodWidth(ins.source) || !goodWidth(ins.width))
                return false;
            Mem d;
            if (!opnd(ins.destination, R9, d))
                return false;
            if (op.widen.zeroExtend)
                a.ldzx(cast(int) ins.source, RAX, d);
            else
                a.ldsx(cast(int) ins.source, RAX, d);
            a.st(cast(int) ins.width, d, RAX);
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
        }
    }

    // Left, right and destination of a binary operation. Resolves the address
    // slots in the order destination, left, right.
    bool binary(in Instruction ins, bool twoAddress, bool constantRight,
        bool leftInReg, bool destInReg, out Mem d, out Mem l, out Mem r,
        out size_t rightRaw)
    {
        if (twoAddress) {
            if (!destInReg && !opnd(ins.destination, R9, d))
                return false;
            l = d;
            if (!opnd(ins.source, R11, r))
                return false;
            rightRaw = ins.source;
            return true;
        }
        if (!destInReg && !opnd(ins.destination, R9, d))
            return false;
        if (!leftInReg && !opnd(ins.source, R10, l))
            return false;
        rightRaw = ins.sourceWidth;
        if (!constantRight && !opnd(ins.sourceWidth, R11, r))
            return false;
        return true;
    }

    static Alu aluOf(JitOp.IntOperation operation) {
        import snakebite.internalfailure: internalFailure;

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
        Mem d, l, r;
        size_t rr;
        if (!binary(ins, p.twoAddress, p.constantRight, p.leftInR0,
                p.resultInR0, d, l, r, rr))
            return false;
        const acc = p.resultInR0 ? REG0 : RAX;
        int imm = 0;
        bool haveImm;
        if (p.constantRight)
            haveImm = immOf(w, constantAt(rr, w), imm);
        const mul = p.operation == JitOp.IntOperation.multiply;
        const narrowMul = mul && w < 4;
        if (p.leftInR0) {
            if (acc != REG0)
                a.movRR64(acc, REG0);
            if (narrowMul)
                a.movzxRR(w, acc, acc);
        } else if (narrowMul)
            a.ldzx(w, acc, l);
        else
            a.ld(w, acc, l);
        if (mul) {
            const mw = w == 8 ? 8 : 4;
            if (p.constantRight) {
                if (narrowMul || !haveImm) {
                    a.movI(SC2, constantAt(rr, w));
                    a.imulRR(mw, acc, SC2);
                } else {
                    // `imulRI` is 64-bit; for 4 bytes that is still right in
                    // the low 32 bits.
                    a.imulRI(acc, acc, imm);
                }
            } else if (narrowMul) {
                a.ldzx(w, SC2, r);
                a.imulRR(4, acc, SC2);
            } else
                a.imulM(mw, acc, r);
        } else if (p.constantRight) {
            if (haveImm)
                a.aluRI(aluOf(p.operation), w, acc, imm);
            else {
                a.movI(SC2, constantAt(rr, w));
                a.aluRR(aluOf(p.operation), w, acc, SC2);
            }
        } else
            a.alu(aluOf(p.operation), w, acc, r);
        if (!p.resultInR0)
            a.st(w, d, acc);
        return true;
    }

    bool emitCmp3(in Instruction ins, in JitOp op) {
        const p = op.cmp3;
        const w = cast(int) (op.width ? op.width : ins.width);
        if (!goodWidth(w))
            return false;
        Mem d, l, r;
        size_t rr;
        if (!binary(ins, p.twoAddress, p.constantRight,
                leftInReg: false, destInReg: false, d, l, r, rr))
            return false;
        a.ld(w, RAX, l);
        int imm;
        if (p.constantRight) {
            if (immOf(w, constantAt(rr, w), imm))
                a.aluRI(Alu.cmp, w, RAX, imm);
            else {
                a.movI(SC2, constantAt(rr, w));
                a.aluRR(Alu.cmp, w, RAX, SC2);
            }
        } else
            a.alu(Alu.cmp, w, RAX, r);
        a.setcc(p.signed ? signedCc(p.comparison) : unsignedCc(p.comparison),
            d);
        return true;
    }

    bool emitFused(in Instruction ins, in JitOp op) {
        const p = op.fused;
        const w = cast(int) ins.width;
        size_t t;
        if (!targetIndex(ins.sourceWidth, t))
            return false;
        Mem l, r;
        if (p.kind != CompareKind.floating) {
            if (!goodWidth(w))
                return false;
            if (!p.leftInR0 && !opnd(ins.destination, R9, l))
                return false;
            if (!p.constantRight && !opnd(ins.source, R10, r))
                return false;
            int leftReg = REG0;
            if (!p.leftInR0) {
                a.ld(w, RAX, l);
                leftReg = RAX;
            }
            int imm;
            if (p.constantRight) {
                const v = constantAt(ins.source, w);
                if (immOf(w, v, imm))
                    a.aluRI(Alu.cmp, w, leftReg, imm);
                else {
                    a.movI(SC2, v);
                    a.aluRR(Alu.cmp, w, leftReg, SC2);
                }
            } else
                a.alu(Alu.cmp, w, leftReg, r);
            int cc = p.kind == CompareKind.signed
                ? signedCc(p.comparison) : unsignedCc(p.comparison);
            if (!p.jumpWhen)
                cc ^= 1;
            jccTo(cc, t);
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
        int leftX = fp0Register;
        if (!p.leftInR0) {
            a.sse(prefix, loadOpcode, XMM1, l);
            leftX = XMM1;
        }
        final switch (p.comparison) with (Comparison) {
            case greaterThan:
            case greaterOrEqual: {
                sseRight(w, comparePrefix, compareOpcode, leftX, right);
                int cc = p.comparison == greaterThan ? CC_A : CC_AE;
                if (!p.jumpWhen)
                    cc ^= 1;
                jccTo(cc, t);
                break;
            }
            case lessThan:
            case lessOrEqual: {
                // Compares the right operand with the left one, so that an
                // unordered answer sets the carry flag.
                sseRight(w, prefix, loadOpcode, XMM2, right);
                a.sseRR(comparePrefix, compareOpcode, XMM2, leftX);
                int cc = p.comparison == lessThan ? CC_A : CC_AE;
                if (!p.jumpWhen)
                    cc ^= 1;
                jccTo(cc, t);
                break;
            }
            case equal:
            case notEqual: {
                sseRight(w, comparePrefix, compareOpcode, leftX, right);
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

    bool emitFp3(in Instruction ins, in JitOp op) {
        const p = op.fp3;
        const w = cast(int) ins.width;
        if (w != 8 && w != 4)
            return false;
        if (p.leftInFp0 && w != 8)
            return false;
        const prefix = w == 8 ? doublePrefix : singlePrefix;
        Mem d, l;
        if (!p.resultInFp0 && !opnd(ins.destination, R9, d))
            return false;
        if (!p.leftInFp0 && !opnd(ins.source, R10, l))
            return false;
        FloatRight right;
        if (!floatRight(R11, ins.sourceWidth, p.constantRight, right))
            return false;
        const acc = p.resultInFp0 ? fp0Register : XMM1;
        if (p.leftInFp0) {
            if (acc != fp0Register)
                a.sseRR(noPrefix, moveAlignedOpcode, acc, fp0Register);
        } else
            a.sse(prefix, loadOpcode, acc, l);
        sseRight(w, prefix, _floatOpcodes[p.operation], acc, right);
        if (!p.resultInFp0)
            a.sse(prefix, storeOpcode, acc, d);
        return true;
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

    bool emitChecked(in Instruction ins, in JitOp op) {
        const p = op.checked;
        const packed = ins.width;
        const idxOff = cast(uint) packed;
        const hi = packed >> 32;
        const es = op.width;
        const access = p.access;
        if (idxOff > 0x7fff_0000)
            return false;
        size_t target;
        if (access != CheckedAccess.storeUnchecked
                && !targetIndex(ins.sourceWidth, target))
            return false;
        Mem d, s;
        if (access != CheckedAccess.check && !p.constantValue
                && !opnd(ins.destination, R9, d))
            return false;
        if (!opnd(ins.source, R10, s))
            return false;
        const idx = Mem(FRAME, cast(int) idxOff);
        const offset = p.fixedLength ? 0 : cast(int) hi;
        if (p.indexWidth == 4) {
            a.ld(4, RAX, idx);
            if (offset != 0)
                a.aluRI(Alu.add, 4, RAX, offset);
            if (p.signed)
                a.rrOp(8, byteReg: false, RAX, RAX, signExtend32Opcode);
        } else {
            a.ld(8, RAX, idx);
            if (offset != 0)
                a.aluRI(Alu.add, 8, RAX, offset);
        }
        size_t failJump = size_t.max;
        if (access != CheckedAccess.storeUnchecked) {
            if (p.fixedLength) {
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
        if (access != CheckedAccess.check) {
            if (p.fixedLength)
                a.lea(SC2, s);
            else
                a.ld(8, SC2, Mem(s.base, s.disp + cast(int) arrayPointerOffset));
            const element = Mem(SC2, 0, RAX, cast(ubyte) es);
            if (access == CheckedAccess.load) {
                a.ld(es, R11, element);
                a.st(es, d, R11);
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
        if (access != CheckedAccess.storeUnchecked)
            jmpTo(target);
        if (failJump != size_t.max)
            patchHere(failJump);
        return true;
    }

    bool emitShift(in Instruction ins, in JitOp op) {
        const p = op.shift;
        const w = cast(int) (op.width ? op.width : ins.width);
        if (!bmi2 || !goodWidth(w))
            return false;
        Mem d, l, r;
        size_t rr;
        if (!binary(ins, p.twoAddress, p.constantRight,
                leftInReg: false, destInReg: false, d, l, r, rr))
            return false;
        if (p.kind == JitOp.ShiftKind.arithmeticRight)
            a.ldsx(w, RAX, l);
        else
            a.ldzx(w, RAX, l);
        if (p.constantRight)
            a.movI(SC2, constantAt(rr, w));
        else
            a.ldzx(w, SC2, r);
        a.aluRI(Alu.and, 4, SC2, w == 8 ? 63 : 31);
        // `shlx`, `shrx` or `sarx` rax, rax, SC2 (BMI2), VEX-encoded. The
        // first byte after the escape holds W = 1, `vvvv` as the inverted
        // second source register (SC2), L = 0 and the prefix `pp`.
        enum ubyte vexEscape = 0xC4;
        enum ubyte vexMap0F38 = 0xE2;
        enum ubyte vexW = 0x80;
        enum ubyte shiftOpcode = 0xF7;
        enum ubyte raxRaxModrm = 0xC0;
        ubyte pp;
        final switch (p.kind) with (JitOp.ShiftKind) {
            case left: pp = 1; break;
            case logicalRight: pp = 3; break;
            case arithmeticRight: pp = 2;
        }
        a.b(vexEscape);
        a.b(vexMap0F38);
        a.b(cast(ubyte) (vexW | ((~SC2 & 15) << 3) | pp));
        a.b(shiftOpcode);
        a.b(raxRaxModrm);
        a.st(w, d, RAX);
        return true;
    }
}


private enum Emitted { done, failed, full }
