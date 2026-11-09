module snakebite.backends.bytecode.jit;

// Prototype template JIT for the bytecode VM (issue #873, P1).
//
// For each compiled function, every instruction that has a template gets
// x86-64 machine code with its operands as immediates. The address of the
// code of instruction i replaces `instructions[i].handler`. The code obeys
// the `Instruction.Handler` calling convention (System V: pc in rdi, activation
// in rsi, state in rdx, frame in rcx, r0 in r8, fp0 in xmm0). It has no stack
// frame, makes no call and uses only rax, rdi, r9, r10, r11, xmm1 and xmm2 as
// scratch, so r0 and fp0 survive and exceptions need no unwind information:
// they happen only in real handlers, which the JIT code reaches by a tail jump.
// An instruction without a template gets a stub that sets `pc` and jumps to
// its real handler.

import core.stdc.stdio: FILE, fopen, fprintf, fflush, stderr;
import core.stdc.stdlib: malloc, realloc, free, getenv, atexit;
import core.stdc.string: strcmp;
import core.sys.posix.sys.mman;
import core.sys.posix.time: clock_gettime, timespec, CLOCK_MONOTONIC;
import core.sys.posix.unistd: getpid;

import snakebite.backends.bytecode.vm: Instruction, indirectBit;

package enum JKind : ubyte {
    none, copy, constant, zero, jump, branch, int3, cmp3, fused, fp3, fpcmp3,
    index, checked, castFixed, widen, loadInd, storeInd, frameAddr,
    staticLoad, staticStore, staticAddr, boolOp, unary, shift,
}

// `a` to `e` have a meaning for each kind; see `emitOp`. `w` is a fixed
// operand width, or 0 when the instruction holds it.
package struct JitOp {
    JKind kind;
    ubyte a, b, c, d, e;
    ubyte w;
}

private enum : ubyte {
    RAX = 0, RCX = 1, RDX = 2, RSI = 6, RDI = 7, R8 = 8, R9 = 9, R10 = 10,
    R11 = 11,
}

private enum FRAME = RCX;

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

// Stats, printed at exit under SNAKEBITE_JIT_STATS=1.
private __gshared ulong statEmitNs, statProtectNs, statFunctions,
    statInstructions, statTemplated, statBytes, statPages, statDeclined;
private __gshared bool statsOn;
private __gshared bool statsHooked;

private ulong nowNs() {
    timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return cast(ulong) t.tv_sec * 1_000_000_000UL + t.tv_nsec;
}

private extern(C) void dumpStats() {
    fprintf(stderr, "JIT functions=%llu instructions=%llu templated=%llu "
        ~ "declined=%llu bytes=%llu pages=%llu emit_ms=%.3f mprotect_ms=%.3f\n",
        statFunctions, statInstructions, statTemplated, statDeclined,
        statBytes, statPages, statEmitNs / 1e6, statProtectNs / 1e6);
}

// The executable region. Code of one function starts on a fresh page, so that
// a page never changes from writable to executable while a thread runs code
// in it.
private __gshared ubyte* regionBase;
private __gshared size_t regionCursor;
private enum regionSize = 1UL << 30;
private enum pageSize = 4096;
private shared int regionLock;
private __gshared FILE* perfMap;

private void lock() {
    import core.atomic: cas;
    while (!cas(&regionLock, 0, 1)) {}
}

private void unlock() {
    import core.atomic: atomicStore;
    atomicStore(regionLock, 0);
}

private bool ensureRegion() {
    if (regionBase !is null)
        return true;
    auto p = mmap(null, regionSize, PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANON | 0x4000, -1, 0);
    if (p is MAP_FAILED)
        return false;
    regionBase = cast(ubyte*) p;
    const s = getenv("SNAKEBITE_JIT_STATS");
    statsOn = s !is null && s[0] == '1';
    if (statsOn && !statsHooked) {
        statsHooked = true;
        atexit(&dumpStats);
    }
    const m = getenv("SNAKEBITE_JIT_PERFMAP");
    if (m !is null && m[0] == '1') {
        import core.stdc.stdio: snprintf;
        char[64] path;
        snprintf(path.ptr, path.length, "/tmp/perf-%d.map", getpid());
        perfMap = fopen(path.ptr, "w");
    }
    return true;
}

private struct Fixup {
    size_t position;
    size_t target;
}

private struct Asm {
    ubyte* buf;
    size_t n;
    size_t cap;

    void b(ubyte x) { buf[n++] = x; }
    void d32(int x) { *cast(int*) (buf + n) = x; n += 4; }
    void q64(ulong x) { *cast(ulong*) (buf + n) = x; n += 8; }

    // Prefix, REX, then `opc`, then ModRM for `m`.
    void memOp(int w, bool byteReg, int reg, in Mem m, in ubyte[] opc,
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
        foreach (o; opc)
            b(o);
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
    void rrOp(int w, bool byteReg, int reg, int rm, in ubyte[] opc,
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
        foreach (o; opc)
            b(o);
        b(cast(ubyte) (0xC0 | ((reg & 7) << 3) | (rm & 7)));
    }

    // Loads and stores of width `w` with no extension.
    void ld(int w, int r, in Mem m) {
        memOp(w, w == 1, r, m, w == 1 ? [cast(ubyte) 0x8A] : [cast(ubyte) 0x8B]);
    }

    void st(int w, in Mem m, int r) {
        memOp(w, w == 1, r, m, w == 1 ? [cast(ubyte) 0x88] : [cast(ubyte) 0x89]);
    }

    // Zero and sign extension to 64 bits.
    void ldzx(int w, int r, in Mem m) {
        switch (w) {
            case 1: memOp(4, false, r, m, [cast(ubyte) 0x0F, 0xB6]); break;
            case 2: memOp(4, false, r, m, [cast(ubyte) 0x0F, 0xB7]); break;
            case 4: memOp(4, false, r, m, [cast(ubyte) 0x8B]); break;
            default: memOp(8, false, r, m, [cast(ubyte) 0x8B]);
        }
    }

    void ldsx(int w, int r, in Mem m) {
        switch (w) {
            case 1: memOp(8, false, r, m, [cast(ubyte) 0x0F, 0xBE]); break;
            case 2: memOp(8, false, r, m, [cast(ubyte) 0x0F, 0xBF]); break;
            case 4: memOp(8, false, r, m, [cast(ubyte) 0x63]); break;
            default: memOp(8, false, r, m, [cast(ubyte) 0x8B]);
        }
    }

    // ALU op (0 add, 1 or, 4 and, 5 sub, 6 xor, 7 cmp) reg, mem.
    void alu(int op, int w, int r, in Mem m) {
        memOp(w, w == 1, r, m, [cast(ubyte) (op * 8 + (w == 1 ? 2 : 3))]);
    }

    // ALU op mem, imm.
    void aluMI(int op, int w, in Mem m, int imm) {
        if (w == 1) {
            memOp(w, false, op, m, [cast(ubyte) 0x80]);
            b(cast(ubyte) imm);
        } else if (imm >= -128 && imm <= 127) {
            memOp(w, false, op, m, [cast(ubyte) 0x83]);
            b(cast(ubyte) imm);
        } else {
            memOp(w, false, op, m, [cast(ubyte) 0x81]);
            if (w == 2) { b(cast(ubyte) imm); b(cast(ubyte) (imm >> 8)); }
            else d32(imm);
        }
    }

    // ALU op reg, reg (reg is the destination).
    void aluRR(int op, int w, int dst, int src) {
        rrOp(w, w == 1, src, dst, [cast(ubyte) (op * 8 + (w == 1 ? 0 : 1))]);
    }

    void aluRI(int op, int w, int r, int imm) {
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
        memOp(w, false, r, m, [cast(ubyte) 0x0F, 0xAF]);
    }

    void imulRR(int w, int dst, int src) {
        rrOp(w, false, dst, src, [cast(ubyte) 0x0F, 0xAF]);
    }

    void imulRI(int dst, int src, int imm) {
        rrOp(8, false, dst, src, [cast(ubyte) 0x69]);
        d32(imm);
    }

    void movRR64(int dst, int src) {
        rrOp(8, false, src, dst, [cast(ubyte) 0x89]);
    }

    void movzxRR(int w, int dst, int src) {
        // Zero-extend the low `w` bytes of src into dst (32-bit result).
        switch (w) {
            case 1: rrOp(4, true, dst, src, [cast(ubyte) 0x0F, 0xB6]); break;
            case 2: rrOp(4, false, dst, src, [cast(ubyte) 0x0F, 0xB7]); break;
            default: rrOp(4, false, src, dst, [cast(ubyte) 0x89]);
        }
    }

    // mov store immediate.
    void stI(int w, in Mem m, int imm) {
        if (w == 1) {
            memOp(w, false, 0, m, [cast(ubyte) 0xC6]);
            b(cast(ubyte) imm);
        } else {
            memOp(w, false, 0, m, [cast(ubyte) 0xC7]);
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
        memOp(8, false, r, m, [cast(ubyte) 0x8D]);
    }

    void negNot(bool neg, int w, in Mem m) {
        memOp(w, false, neg ? 3 : 2, m,
            w == 1 ? [cast(ubyte) 0xF6] : [cast(ubyte) 0xF7]);
    }

    void setcc(int cc, in Mem m) {
        memOp(1, false, 0, m, [cast(ubyte) 0x0F, cast(ubyte) (0x90 + cc)]);
    }

    void setccR(int cc, int r) {
        rrOp(1, true, 0, r, [cast(ubyte) 0x0F, cast(ubyte) (0x90 + cc)]);
    }

    // SSE. `prefix` 0xF2 (sd), 0xF3 (ss), 0x66, or 0.
    void sse(ubyte prefix, ubyte op, int x, in Mem m) {
        memOp(4, false, x, m, [cast(ubyte) 0x0F, op], prefix);
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

    void ud2() { b(0x0F); b(0x0B); }
}

private struct Gen {
    Asm a;
    const(Instruction)[] instructions;
    const(Instruction)[] snapshot;
    const(long)[] constants;
    size_t[] labels;
    Fixup* fixups;
    size_t fixupCount;
    size_t fixupCap;
    bool declined;

    void fix(size_t target) {
        if (fixupCount == fixupCap) {
            fixupCap = fixupCap ? fixupCap * 2 : 256;
            fixups = cast(Fixup*) realloc(fixups, fixupCap * Fixup.sizeof);
        }
        fixups[fixupCount++] = Fixup(a.n, target);
        a.d32(0);
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
            a.sse(0, 0x10, 1, ss);
            a.sse(0, 0x11, 1, dd);
            off += 16;
        }
        foreach (c; [8, 4, 2, 1]) {
            if (size - off >= c) {
                auto ss = s; ss.disp += cast(int) off;
                auto dd = d; dd.disp += cast(int) off;
                a.ld(c, RAX, ss);
                a.st(c, dd, RAX);
                off += c;
            }
        }
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

    static int signedCc(int cmp) {
        // lt le gt ge eq ne
        static immutable ubyte[6] t = [CC_L, CC_LE, CC_G, CC_GE, CC_E, CC_NE];
        return t[cmp];
    }

    static int unsignedCc(int cmp) {
        static immutable ubyte[6] t = [CC_B, CC_BE, CC_A, CC_AE, CC_E, CC_NE];
        return t[cmp];
    }

    // The two operands of an integer or floating compare/arith, decoded in the
    // order the handlers decode them. `left` and `right` are raw fields.
    struct Operands {
        Mem dest, left, right;
        size_t rightRaw;
    }

    bool emitOp(size_t i, in JitOp op) {
        const ins = snapshot[i];
        final switch (op.kind) with (JKind) {
        case none:
            return false;

        case copy: {
            const size = op.w ? op.w : ins.width;
            if (size > 64)
                return false;
            Mem d, s;
            if (!opnd(ins.destination, R9, d))
                return false;
            if (op.a) {
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
            foreach (c; [8, 4, 2, 1]) {
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
            const w = op.w ? op.w : ins.width;
            size_t t;
            if (!goodWidth(w) || !targetIndex(ins.source, t))
                return false;
            Mem d;
            if (!opnd(ins.destination, R9, d))
                return false;
            a.aluMI(7, cast(int) w, d, 0);
            jccTo(op.a ? CC_NE : CC_E, t);
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
            switch (op.a) {
                case 0: a.ld(8, RAX, Mem(s.base, s.disp + 8)); break;
                case 1: a.lea(RAX, s); break;
                default: a.ld(8, RAX, s);
            }
            a.ld(8, RDI, r);
            if (es == 1 || es == 2 || es == 4 || es == 8)
                a.lea(RAX, Mem(RAX, 0, RDI, cast(ubyte) es));
            else {
                a.imulRI(RDI, RDI, cast(int) es);
                a.aluRR(0, 8, RAX, RDI);
            }
            a.st(8, d, RAX);
            return true;
        }

        case checked:
            return emitChecked(ins, op);

        case castFixed: {
            // a: 1 when the source is zero-extended; w: destination size;
            // b: source size.
            Mem d, s;
            if (!opnd(ins.destination, R9, d) || !opnd(ins.source, R10, s))
                return false;
            if (op.a)
                a.ldzx(op.b, RAX, s);
            else
                a.ldsx(op.b, RAX, s);
            a.st(op.w, d, RAX);
            return true;
        }

        case widen: {
            // In place: the source width is in `source`, the width in `width`.
            if (!goodWidth(ins.source) || !goodWidth(ins.width))
                return false;
            Mem d;
            if (!opnd(ins.destination, R9, d))
                return false;
            if (op.a)
                a.ldzx(cast(int) ins.source, RAX, d);
            else
                a.ldsx(cast(int) ins.source, RAX, d);
            a.st(cast(int) ins.width, d, RAX);
            return true;
        }

        case loadInd: {
            const size = op.w ? op.w : ins.width;
            if (size > 64)
                return false;
            Mem d, s;
            if (!opnd(ins.destination, R9, d) || !opnd(ins.source, R10, s))
                return false;
            a.ld(8, RDI, s);
            copyChunks(Mem(RDI, 0), d, size);
            return true;
        }

        case storeInd: {
            const size = op.w ? op.w : ins.width;
            if (size > 64)
                return false;
            Mem d, s;
            if (!opnd(ins.destination, R9, d) || !opnd(ins.source, R10, s))
                return false;
            a.ld(8, RDI, d);
            copyChunks(s, Mem(RDI, 0), size);
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
            a.aluMI(7, cast(int) w, d, 0);
            a.setcc(op.a ? CC_NE : CC_E, d);
            return true;
        }

        case unary: {
            const w = ins.width;
            if (!goodWidth(w))
                return false;
            Mem d;
            if (!opnd(ins.destination, R9, d))
                return false;
            a.negNot(op.a == 0, cast(int) w, d);
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

    // a: 0 add, 1 or, 4 and, 5 sub, 6 xor, 8 mul. b: constant right operand.
    // c: left operand in r0. d: result in r0. e: two-address form.
    bool emitInt3(in Instruction ins, in JitOp op) {
        const w = cast(int) (op.w ? op.w : ins.width);
        if (!goodWidth(w))
            return false;
        Mem d, l, r;
        size_t rr;
        if (!binary(ins, op.e != 0, op.b != 0, op.c != 0, op.d != 0, d, l, r, rr))
            return false;
        const acc = op.d ? R8 : RAX;
        int imm = 0;
        bool haveImm;
        if (op.b) {
            haveImm = immOf(w, constantAt(rr, w), imm);
        }
        const mul = op.a == 8;
        const narrowMul = mul && w < 4;
        // Left operand into acc.
        if (op.c) {
            if (acc != R8)
                a.movRR64(acc, R8);
            if (narrowMul)
                a.movzxRR(w, acc, acc);
        } else if (narrowMul)
            a.ldzx(w, acc, l);
        else
            a.ld(w, acc, l);
        if (mul) {
            const mw = w == 8 ? 8 : 4;
            if (op.b) {
                if (narrowMul || !haveImm) {
                    a.movI(RDI, constantAt(rr, w));
                    a.imulRR(mw, acc, RDI);
                } else {
                    a.imulRI(acc, acc, imm);
                    // imulRI is 64-bit; for 4 bytes that is still right in
                    // the low 32 bits.
                }
            } else if (narrowMul) {
                a.ldzx(w, RDI, r);
                a.imulRR(4, acc, RDI);
            } else
                a.imulM(mw, acc, r);
        } else if (op.b) {
            if (haveImm)
                a.aluRI(op.a, w, acc, imm);
            else {
                a.movI(RDI, constantAt(rr, w));
                a.aluRR(op.a, w, acc, RDI);
            }
        } else
            a.alu(op.a, w, acc, r);
        if (!op.d)
            a.st(w, d, acc);
        return true;
    }

    // a: comparison (lt le gt ge eq ne). b: signed. c: constant right.
    // e: two-address form (the byte result replaces the left operand).
    bool emitCmp3(in Instruction ins, in JitOp op) {
        const w = cast(int) (op.w ? op.w : ins.width);
        if (!goodWidth(w))
            return false;
        Mem d, l, r;
        size_t rr;
        if (!binary(ins, op.e != 0, op.c != 0, false, false, d, l, r, rr))
            return false;
        a.ld(w, RAX, l);
        int imm;
        if (op.c) {
            if (immOf(w, constantAt(rr, w), imm))
                a.aluRI(7, w, RAX, imm);
            else {
                a.movI(RDI, constantAt(rr, w));
                a.aluRR(7, w, RAX, RDI);
            }
        } else
            a.alu(7, w, RAX, r);
        a.setcc(op.b ? signedCc(op.a) : unsignedCc(op.a), d);
        return true;
    }

    // a: comparison, b: kind (0 signed, 1 unsigned, 2 floating), c: jump when,
    // d: constant right operand, e: left operand in a register.
    bool emitFused(in Instruction ins, in JitOp op) {
        const w = cast(int) ins.width;
        size_t t;
        if (!targetIndex(ins.sourceWidth, t))
            return false;
        Mem l, r;
        if (op.b != 2) {
            if (!goodWidth(w))
                return false;
            if (!op.e && !opnd(ins.destination, R9, l))
                return false;
            if (!op.d && !opnd(ins.source, R10, r))
                return false;
            int leftReg = R8;
            if (!op.e) {
                a.ld(w, RAX, l);
                leftReg = RAX;
            }
            int imm;
            if (op.d) {
                const v = constantAt(ins.source, w);
                if (immOf(w, v, imm))
                    a.aluRI(7, w, leftReg, imm);
                else {
                    a.movI(RDI, v);
                    a.aluRR(7, w, leftReg, RDI);
                }
            } else
                a.alu(7, w, leftReg, r);
            int cc = op.b == 0 ? signedCc(op.a) : unsignedCc(op.a);
            if (!op.c)
                cc ^= 1;
            jccTo(cc, t);
            return true;
        }
        // Floating.
        if (w != 8 && w != 4)
            return false;
        const prefix = cast(ubyte) (w == 8 ? 0xF2 : 0xF3);
        const ucomi = cast(ubyte) 0x2E;
        const ucomiPrefix = cast(ubyte) (w == 8 ? 0x66 : 0);
        if (!op.e && !opnd(ins.destination, R9, l))
            return false;
        if (op.d) {
            a.movI(R10, ins.source);
            r = Mem(R10, 0);
        } else if (!opnd(ins.source, R10, r))
            return false;
        int leftX = 0;
        if (!op.e) {
            a.sse(prefix, 0x10, 1, l);
            leftX = 1;
        }
        const cmp = op.a;
        if (cmp == 2 || cmp == 3) { // gt, ge: ucomis left, right
            a.sse(ucomiPrefix, ucomi, leftX, r);
            int cc = cmp == 2 ? CC_A : CC_AE;
            if (!op.c)
                cc ^= 1;
            jccTo(cc, t);
        } else if (cmp == 0 || cmp == 1) { // lt, le: ucomis right, left
            a.sse(prefix, 0x10, 2, r);
            a.sseRR(ucomiPrefix, ucomi, 2, leftX);
            int cc = cmp == 0 ? CC_A : CC_AE;
            if (!op.c)
                cc ^= 1;
            jccTo(cc, t);
        } else {
            a.sse(ucomiPrefix, ucomi, leftX, r);
            const eq = cmp == 4;
            if (eq == (op.c != 0)) {
                // Jump when ZF=1 and PF=0.
                const skip = jccLocal(CC_P);
                jccTo(CC_E, t);
                patchHere(skip);
            } else {
                jccTo(CC_P, t);
                jccTo(CC_NE, t);
            }
        }
        return true;
    }

    // a: 0 add, 1 sub, 2 mul, 3 div. c: constant right. d: left in fp0.
    // e: result in fp0.
    bool emitFp3(in Instruction ins, in JitOp op) {
        const w = cast(int) ins.width;
        if (w != 8 && w != 4)
            return false;
        if (op.d && w != 8)
            return false;
        const prefix = cast(ubyte) (w == 8 ? 0xF2 : 0xF3);
        Mem d, l, r;
        if (!op.e && !opnd(ins.destination, R9, d))
            return false;
        if (!op.d && !opnd(ins.source, R10, l))
            return false;
        if (op.c) {
            a.movI(R11, ins.sourceWidth);
            r = Mem(R11, 0);
        } else if (!opnd(ins.sourceWidth, R11, r))
            return false;
        const acc = op.e ? 0 : 1;
        if (op.d) {
            if (acc != 0)
                a.sseRR(0, 0x28, acc, 0);
        } else
            a.sse(prefix, 0x10, acc, l);
        static immutable ubyte[4] codes = [0x58, 0x5C, 0x59, 0x5E];
        a.sse(prefix, codes[op.a], acc, r);
        if (!op.e)
            a.sse(prefix, 0x11, acc, d);
        return true;
    }

    // a: comparison, c: constant right.
    bool emitFpCmp3(in Instruction ins, in JitOp op) {
        const w = cast(int) ins.width;
        if (w != 8 && w != 4)
            return false;
        const prefix = cast(ubyte) (w == 8 ? 0xF2 : 0xF3);
        const ucomiPrefix = cast(ubyte) (w == 8 ? 0x66 : 0);
        Mem d, l, r;
        if (!opnd(ins.destination, R9, d) || !opnd(ins.source, R10, l))
            return false;
        if (op.c) {
            a.movI(R11, ins.sourceWidth);
            r = Mem(R11, 0);
        } else if (!opnd(ins.sourceWidth, R11, r))
            return false;
        a.sse(prefix, 0x10, 1, l);
        const cmp = op.a;
        if (cmp == 2 || cmp == 3) {
            a.sse(ucomiPrefix, 0x2E, 1, r);
            a.setcc(cmp == 2 ? CC_A : CC_AE, d);
        } else if (cmp == 0 || cmp == 1) {
            a.sse(prefix, 0x10, 2, r);
            a.sseRR(ucomiPrefix, 0x2E, 2, 1);
            a.setcc(cmp == 0 ? CC_A : CC_AE, d);
        } else {
            a.sse(ucomiPrefix, 0x2E, 1, r);
            if (cmp == 4) {
                a.setccR(CC_E, RAX);
                a.setccR(CC_NP, RDI);
                a.aluRR(4, 1, RAX, RDI);
            } else {
                a.setccR(CC_NE, RAX);
                a.setccR(CC_P, RDI);
                a.aluRR(1, 1, RAX, RDI);
            }
            a.st(1, d, RAX);
        }
        return true;
    }

    // a: access (0 load, 1 store, 2 check, 3 storeUnchecked), b: fixed length,
    // c: index width, d: signed, e: constant value; w: element size.
    bool emitChecked(in Instruction ins, in JitOp op) {
        const packed = ins.width;
        const idxOff = cast(uint) packed;
        const hi = packed >> 32;
        const es = op.w;
        const access = op.a;
        if (idxOff > 0x7fff_0000)
            return false;
        size_t target;
        if (access != 3 && !targetIndex(ins.sourceWidth, target))
            return false;
        Mem d, s;
        if (access != 2 && !op.e && !opnd(ins.destination, R9, d))
            return false;
        if (!opnd(ins.source, R10, s))
            return false;
        const idx = Mem(FRAME, cast(int) idxOff);
        const offset = op.b ? 0 : cast(int) hi;
        if (op.c == 4) {
            a.ld(4, RAX, idx);
            if (offset != 0)
                a.aluRI(0, 4, RAX, offset);
            if (op.d)
                a.rrOp(8, false, RAX, RAX, [cast(ubyte) 0x63]);
        } else {
            a.ld(8, RAX, idx);
            if (offset != 0)
                a.aluRI(0, 8, RAX, offset);
        }
        size_t failJump = size_t.max;
        if (access != 3) {
            if (op.b) {
                if (hi <= int.max)
                    a.aluRI(7, 8, RAX, cast(int) hi);
                else {
                    a.movI(RDI, hi);
                    a.aluRR(7, 8, RAX, RDI);
                }
            } else
                a.alu(7, 8, RAX, s); // arrayLengthOffset is 0
            failJump = jccLocal(CC_AE);
        }
        if (access != 2) {
            if (op.b)
                a.lea(RDI, s);
            else
                a.ld(8, RDI, Mem(s.base, s.disp + 8));
            const element = Mem(RDI, 0, RAX, cast(ubyte) es);
            if (access == 0) {
                a.ld(es, R11, element);
                a.st(es, d, R11);
            } else if (op.e) {
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
        if (access != 3)
            jmpTo(target);
        if (failJump != size_t.max)
            patchHere(failJump);
        return true;
    }

    // a: 0 left, 1 logical right, 2 arithmetic right.
    bool emitShift(in Instruction ins, in JitOp op) {
        const w = cast(int) (op.w ? op.w : ins.width);
        if (!goodWidth(w))
            return false;
        Mem d, l, r;
        size_t rr;
        if (!binary(ins, op.e != 0, op.c != 0, false, false, d, l, r, rr))
            return false;
        if (op.a == 2)
            a.ldsx(w, RAX, l);
        else
            a.ldzx(w, RAX, l);
        if (op.c)
            a.movI(RDI, constantAt(rr, w));
        else
            a.ldzx(w, RDI, r);
        a.aluRI(4, 4, RDI, w == 8 ? 63 : 31);
        // shlx, shrx, sarx rax, rax, rdi (BMI2).
        a.b(0xC4);
        a.b(0xE2);
        a.b(cast(ubyte) (0xC0 | (op.a == 0 ? 1 : op.a == 1 ? 3 : 2)));
        a.b(0xF7);
        a.b(0xC0);
        a.st(w, d, RAX);
        return true;
    }
}

// Returns true when the function got JIT code.
package bool jitFunction(Instruction[] instructions,
    const(Instruction)[] snapshot, const(JitOp)[] ops,
    const(long)[] constants, const(char)[] name)
{
    if (instructions.length == 0 || !ensureRegion())
        return false;
    const t0 = nowNs();
    lock();
    scope (exit)
        unlock();
    const start = (regionCursor + pageSize - 1) & ~(pageSize - 1UL);
    const cap = regionSize - start;
    if (cap < instructions.length * 1024 + 4096)
        return false;

    Gen g;
    g.a.buf = regionBase + start;
    g.a.cap = cap;
    g.instructions = instructions;
    g.snapshot = snapshot;
    g.constants = constants;
    auto labels = cast(size_t*) malloc((instructions.length + 1) * size_t.sizeof);
    g.labels = labels[0 .. instructions.length + 1];
    scope (exit) {
        free(labels);
        free(g.fixups);
    }

    auto originals = cast(Instruction.Handler*) malloc(
        instructions.length * Instruction.Handler.sizeof);
    scope (exit)
        free(originals);
    foreach (i, ref instruction; instructions)
        originals[i] = instruction.handler;

    size_t templated;
    foreach (i; 0 .. instructions.length) {
        g.labels[i] = g.a.n;
        const saved = g.a.n;
        const savedFixups = g.fixupCount;
        bool done;
        if (originals[i] !is null && ops[i].kind != JKind.none)
            done = g.emitOp(i, ops[i]);
        if (done)
            ++templated;
        else {
            g.a.n = saved;
            g.fixupCount = savedFixups;
            if (originals[i] is null)
                g.a.ud2();
            else {
                // mov rdi, &instruction; mov rax, handler; jmp rax
                g.a.movI(RDI, cast(size_t) &instructions[i]);
                g.a.movI(RAX, cast(size_t) originals[i]);
                g.a.b(0xFF);
                g.a.b(0xE0);
            }
        }
    }
    g.labels[instructions.length] = g.a.n;
    g.a.ud2();

    foreach (f; g.fixups[0 .. g.fixupCount])
        *cast(int*) (g.a.buf + f.position) = cast(int) (
            g.labels[f.target] - (f.position + 4));

    const size = g.a.n;
    const pages = (size + pageSize - 1) / pageSize;
    const t1 = nowNs();
    if (mprotect(g.a.buf, pages * pageSize, PROT_READ | PROT_EXEC) != 0)
        return false;
    const t2 = nowNs();
    regionCursor = start + pages * pageSize;

    foreach (i, ref instruction; instructions)
        instruction.handler = cast(Instruction.Handler) (g.a.buf + g.labels[i]);

    ++statFunctions;
    statInstructions += instructions.length;
    statTemplated += templated;
    statBytes += size;
    statPages += pages;
    statEmitNs += t1 - t0;
    statProtectNs += t2 - t1;
    if (perfMap !is null) {
        fprintf(perfMap, "%lx %lx %.*s\n", cast(size_t) g.a.buf, size,
            cast(int) name.length, name.ptr);
        fflush(perfMap);
    }
    return true;
}
