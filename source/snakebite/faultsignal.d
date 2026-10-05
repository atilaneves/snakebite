module snakebite.faultsignal;


private:


import snakebite.backends.guestfault: GuestFault;
import snakebite.backends.haltprocess: Halted;

version (linux) version (X86_64)
    enum supported = true;
static if (!is(typeof(supported)))
    enum supported = false;


// Guest code that dereferences a bad address or divides by zero ends in a
// signal from the hardware. A guest fault must fail with a message instead
// of killing the host, and the guest hot path must not pay for it, so the
// host does not check: it handles the signal.
//
// The handler does almost nothing. It records the fault in thread-local
// memory and changes the saved context so that the thread continues in an
// assembly trampoline, on its own stack and outside signal context, which
// throws a `HardwareFault`. Everything after that is normal D code. This is
// the technique of druntime's `etc.linux.memoryerror`.
//
// Only a thread marked as running guest code (`runGuest`) gets that. Other
// faults keep the previous or default action, with a core dump when enabled.
// Until the backends mark their runs, this includes guest faults: an absent
// mark cannot establish that the host has a defect.
//
// A shared module constructor installs the handlers one time at start
// (`installFaultHandlers`). A guest that installs a handler of its own for
// one of these signals replaces ours, as it does in compiled D.
//
// Linux on x86-64 only. On any other target nothing is installed and a
// fault crashes the process.

// The thrown object: it carries the fault to the first `catch` of a
// backend, which reports it with the position that the backend knows. One
// object for each thread, made before any fault, because the handler and
// the trampoline must not allocate.
public final class HardwareFault: Halted {
    public GuestFault.Kind kind;
    public int signal;
    public size_t address;
    public size_t hostPc;

    private this() @safe @nogc nothrow pure {
        super("hardware fault", __FILE__, __LINE__);
    }
}


// A recovery entry must own required host cleanup outside `body`. The
// compiler can remove catches and cleanup around a faulting load or divide,
// even in a caller when it proves that the callee cannot throw. The assembly
// call keeps a real throwing call site here, including with LTO. Each entry
// releases only its own mark: other Fibers can have suspended entries on
// this thread. Use nested entries, not `GuestRun` locals, inside `body`.
// This does not restore other host state owned inside `body`.
// Backends must discard halted execution state, as required by #523.
public void runGuest(scope void delegate() body) @system {
    static if (supported) {
        if (_state.prepared is null)
            prepareThread;
        ++_state.runs;
        scope(exit) --_state.runs;
        snakebite_fault_invoke(&body, &invokeGuestBody);
    } else
        body();
}


static if (supported) {
    private alias GuestBody = extern(C) void function(void*);
    private extern(C) void snakebite_fault_invoke(void* context, GuestBody body);

    private extern(C) void invokeGuestBody(void* context) {
        (*cast(void delegate()*) context)();
    }
}


// A low-level mark, not a recovery entry: use `runGuest` around faulting
// work. A mark alone cannot preserve cleanup in its owning frame. It
// makes the state of the thread (an alternate signal stack, so that a
// fault of the stack itself can be handled, and the object to throw) the
// first time. Runs nest.
public struct GuestRun {
    @disable this(this);

    public static GuestRun begin() @trusted {
        GuestRun run;
        static if (supported) {
            if (_state.prepared is null)
                prepareThread;
            ++_state.runs;
            run._active = true;
        }
        return run;
    }

    public ~this() @trusted @nogc nothrow {
        static if (supported)
            if (_active)
                --_state.runs;
    }

    private bool _active;
}


// The catcher of a `HardwareFault` calls this first. Until it does, the
// thread has a fault in flight, and a second fault of the thread (in the
// unwinder, in a cleanup) gets the default action: throwing again would
// loop for ever.
public void takeFault(in HardwareFault) @trusted @nogc nothrow {
    static if (supported)
        _state.pending = false;
}


// The fault handlers for the signals that report a guest fault. It returns
// whether they are in use: not on a target that is not supported, and not
// when the environment variable `SNAKEBITE_NO_FAULT_HANDLER` is set, so
// that a maintainer can get the crash and the core dump of the guest.
public bool installFaultHandlers() @trusted nothrow @nogc {
    static if (supported) {
        import core.atomic: atomicLoad, atomicStore, cas;
        import core.stdc.stdlib: getenv;
        import core.sys.posix.signal: SIG_SETMASK, sigprocmask, sigset_t;

        if (getenv("SNAKEBITE_NO_FAULT_HANDLER") !is null)
            return false;

        // A handler on this thread must not wait for its own installation.
        // Block the collector too: a handler on another thread can be
        // waiting on its alternate stack until the saved action is complete.
        sigset_t blocked, savedMask;
        sigfillset(&blocked);
        if (sigprocmask(SIG_SETMASK, &blocked, &savedMask) != 0)
            assert(0, "cannot block signals during fault-handler installation");
        scope(exit)
            if (sigprocmask(SIG_SETMASK, &savedMask, null) != 0)
                assert(0, "cannot restore signals after fault-handler installation");

        if (!cas(&_installation, Installation.absent, Installation.inProgress)) {
            while (atomicLoad(_installation) == Installation.inProgress) {}
            return true;
        }

        sigaction_t action;
        action.sa_sigaction = &snakebite_fault_signal_entry;
        action.sa_flags = SA_SIGINFO | SA_ONSTACK;
        // The collector suspends threads with a signal. While the handler
        // runs on the alternate stack, the collector would take the pointer
        // into it as the top of the stack of the thread, and scan memory
        // that is not mapped. With every signal blocked, the suspension
        // waits until the thread is back on its own stack.
        sigfillset(&action.sa_mask);
        foreach (index, signal; handledSignals) {
            if (sigaction(signal, &action, &_previous[index]) != 0)
                assert(0, "sigaction failed for a fault signal");
            // sigaction publishes the kernel action before libc can finish
            // copying the old action to this array. Readers wait for that
            // copy, not merely for the kernel to accept the new action.
            atomicStore(_previousReady[index], true);
        }
        atomicStore(_installation, Installation.complete);

        return true;
    } else
        return false;
}


private shared static this() @safe @nogc nothrow {
    installFaultHandlers;
}


// What the hardware reported, and where.
public struct FaultReport {
    int signal;
    int code;
    size_t address;
    size_t pc;
    // For an integer division trap: whether the divisor is zero.
    Divisor divisor;
}

// The two causes of an integer division trap. x86 gives the same
// `si_code` for both, so the handler reads the instruction.
public enum Divisor {
    zero,
    nonZero,
    unknown,
}

// What a null pointer dereference is: no valid program maps the first 64 KiB
// (`vm.mmap_min_addr`), so an access that low is a null pointer with an
// offset.
public enum nullLimit = 64 * 1024;

private enum sigKernel = 0x80;
private enum segvMapError = 1;
private enum segvAccessError = 2;
private enum fpeIntegerDivide = 1;
private enum fpeIntegerOverflow = 2;

// The kind of fault from the signal. The hardware gives the address and
// nothing about the type of the access.
public GuestFault.Kind classify(in FaultReport report) @safe @nogc nothrow pure {
    import core.sys.posix.signal: SIGFPE, SIGSEGV;

    if (report.signal == SIGFPE) {
        final switch (report.divisor) with (Divisor) {
            case zero:
                return GuestFault.Kind.divisionByZero;
            case nonZero:
                return GuestFault.Kind.divisionOverflow;
            case unknown:
                return GuestFault.Kind.divisionFault;
        }
    }

    // A non-canonical address gives `SI_KERNEL` and an address of 0 that
    // is not the address of the access.
    if (report.signal != SIGSEGV || report.code == sigKernel)
        return GuestFault.Kind.invalidAccess;

    if (report.address >= nullLimit)
        return GuestFault.Kind.invalidAccess;

    return report.address == report.pc
        ? GuestFault.Kind.nullCall
        : GuestFault.Kind.nullDereference;
}

version (X86_64) {
    // The divisor of the `div` or `idiv` instruction that `instruction`
    // points at, given the registers numbered as the hardware does (`rax`
    // 0, `rcx` 1, `rdx` 2, `rbx` 3, `rsp` 4, `rbp` 5, `rsi` 6, `rdi` 7, then
    // `r8` to `r15`). It runs in a signal handler for a fault that has
    // happened: the instruction was read, and so was the operand in memory.
    // `Divisor.unknown` for any other instruction.
    public Divisor divisorOf(
        const(ubyte)* instruction, in ulong[16] registers,
    ) @system @nogc nothrow {
        auto at = instruction;

        bool operandSize16;
        for (;; ++at) {
            switch (*at) {
                case 0x66:
                    operandSize16 = true;
                    continue;
                // `cs`, `ss`, `ds` and `es` do not change the address. `fs`
                // and `gs` do, and their base is not in `registers`: the
                // instruction is then not known.
                case 0x2e, 0x36, 0x3e, 0x26:
                    continue;
                default:
                    break;
            }
            break;
        }

        ubyte rex;
        if ((*at & 0xf0) == 0x40)
            rex = *at++;

        const opcode = *at++;
        if (opcode != 0xf6 && opcode != 0xf7)
            return Divisor.unknown;

        const modrm = *at++;
        const mode = modrm >> 6;
        const operation = (modrm >> 3) & 7;
        const rm = modrm & 7;
        // `/6` is `div` and `/7` is `idiv`.
        if (operation != 6 && operation != 7)
            return Divisor.unknown;

        const size = opcode == 0xf6 ? 1 : (rex & 8) ? 8 : operandSize16 ? 2 : 4;
        ulong divisor;
        if (mode == 3) {
            const high = size == 1 && rex == 0 && rm >= 4;
            divisor = high
                ? registers[rm - 4] >> 8
                : registers[rm | ((rex & 1) << 3)];
        } else {
            size_t address;
            if (rm == 4) {
                const sib = *at++;
                const scale = sib >> 6;
                const index = ((sib >> 3) & 7) | ((rex & 2) << 2);
                const base = (sib & 7) | ((rex & 1) << 3);
                if (index != 4)
                    address += cast(size_t) (registers[index] << scale);
                if ((sib & 7) == 5 && mode == 0) {
                    address += cast(size_t) *cast(const(int)*) at;
                    at += 4;
                } else
                    address += cast(size_t) registers[base];
            } else if (rm == 5 && mode == 0) {
                const displacement = *cast(const(int)*) at;
                at += 4;
                // Relative to the next instruction, and no immediate follows.
                address = cast(size_t) at + displacement;
            } else
                address = cast(size_t) registers[rm | ((rex & 1) << 3)];

            if (mode == 1)
                address += *cast(const(byte)*) at;
            else if (mode == 2)
                address += *cast(const(int)*) at;

            const place = cast(const(ubyte)*) address;
            final switch (size) {
                case 1:
                    divisor = *place;
                    break;
                case 2:
                    divisor = *cast(const(ushort)*) place;
                    break;
                case 4:
                    divisor = *cast(const(uint)*) place;
                    break;
                case 8:
                    divisor = *cast(const(ulong)*) place;
                    break;
            }
        }

        const mask = size == 8 ? ulong.max : (1UL << (size * 8)) - 1;
        return (divisor & mask) == 0 ? Divisor.zero : Divisor.nonZero;
    }
}


static if (supported) {
    import core.sys.posix.signal:
        SA_ONSTACK,
        SA_SIGINFO,
        SIG_DFL,
        SIGBUS,
        SIGFPE,
        SIGSEGV,
        siginfo_t,
        sigaction,
        sigaction_t,
        sigaltstack,
        sigfillset,
        sigset_t,
        stack_t;
    import core.sys.posix.ucontext: REG_RIP, REG_RSP, ucontext_t;

    private extern(C) void snakebite_fault_trampoline() nothrow @nogc;
    private extern(C) void snakebite_fault_trampoline_call() nothrow @nogc;

    // `SIGILL` is not here: `-checkaction=halt` ends in an illegal
    // instruction, and that must stay a signal.
    private immutable int[3] handledSignals = [SIGSEGV, SIGFPE, SIGBUS];

    // What each thread knows. In the executable, so that the handler
    // reaches it with one instruction that is relative to `fs`.
    private struct ThreadState {
        // How many guest runs this thread is in.
        size_t runs;
        // A fault was recorded and no catcher has taken it yet (`takeFault`).
        // A fault of the thread in that time happens while the first one
        // unwinds, and is a defect of the host.
        bool pending;
        FaultReport record;
        // The thrown object lives here, not in the heap: the collector
        // scans the thread-local memory of threads it knows, and a thread
        // that the guest made is not one of them.
        align(16) void[__traits(classInstanceSize, HardwareFault)] storage;
        HardwareFault prepared;
        // The mapping of the alternate stack that this module made, with its
        // guard page, or null when the thread had an alternate stack.
        void* mapping;
        size_t mappingSize;
    }

    private ThreadState _state;
    private enum Installation {
        absent,
        inProgress,
        complete,
    }
    private shared Installation _installation;
    // What the signals did before this module: a fault of the host goes to
    // it (a sanitizer, a host that embeds snakebite).
    private __gshared sigaction_t[3] _previous;
    private shared bool[3] _previousReady;
    // The saved action stays unchanged while handlers on other threads read
    // it. A one-shot action is consumed before its call, not after it returns.
    // Resetting the installed action here would also disable guest recovery.
    private shared bool[3] _previousReset;

    // The trace of a thrown object is made by druntime from the stack. The
    // fault has no use for it, and making it allocates.
    private final class NoTrace: Throwable.TraceInfo {
        override int opApply(scope int delegate(ref const(char[]))) const {
            return 0;
        }

        override int opApply(scope int delegate(ref size_t, ref const(char[]))) const {
            return 0;
        }

        override string toString() const {
            return "";
        }
    }

    private __gshared NoTrace _noTrace = new NoTrace;

    private enum guardSize = 4096;

    private void prepareThread() @trusted {
        import core.sys.linux.sys.mman: MAP_ANONYMOUS;
        import core.sys.posix.pthread: pthread_once, pthread_setspecific;
        import core.sys.posix.signal: SS_DISABLE;
        import core.sys.posix.sys.mman:
            MAP_FAILED, MAP_PRIVATE, mmap, mprotect, PROT_NONE, PROT_READ,
            PROT_WRITE;
        import core.sys.posix.unistd: sysconf;

        // `_SC_SIGSTKSZ` of glibc.
        enum sysconfSignalStackSize = 250;
        enum minimum = 64 * 1024;

        // A guest that made an alternate stack of its own keeps it.
        stack_t current;
        sigaltstack(null, &current);
        if (current.ss_flags & SS_DISABLE) {
            const wanted = sysconf(sysconfSignalStackSize);
            const size = wanted > minimum ? cast(size_t) wanted : minimum;
            // The guard page is the lowest: the stack grows down.
            const total = size + guardSize;
            auto mapping = mmap(null, total, PROT_READ | PROT_WRITE,
                MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
            if (mapping == MAP_FAILED)
                assert(0, "cannot map an alternate signal stack");
            if (mprotect(mapping, guardSize, PROT_NONE) != 0)
                assert(0, "cannot protect the alternate signal stack");

            stack_t alternate;
            alternate.ss_sp = mapping + guardSize;
            alternate.ss_size = size;
            if (sigaltstack(&alternate, null) != 0)
                assert(0, "sigaltstack failed");

            _state.mapping = mapping;
            _state.mappingSize = total;
            // Raw pthreads do not run druntime's module destructors.
            if (pthread_once(&_threadKeyOnce, &createThreadKey) != 0
                || pthread_setspecific(_threadKey, &_state) != 0)
                assert(0, "cannot register alternate signal stack cleanup");
        }

        _state.storage[] = typeid(HardwareFault).initializer[];
        auto fault = cast(HardwareFault) _state.storage.ptr;
        fault.__ctor;
        fault.info = _noTrace;
        _state.prepared = fault;
    }

    private static ~this() @trusted {
        import core.sys.posix.pthread: pthread_setspecific;

        if (_state.mapping !is null) {
            pthread_setspecific(_threadKey, null);
            releaseThread(_state);
        }
    }

    import core.sys.posix.pthread: pthread_key_t, pthread_once_t, PTHREAD_ONCE_INIT;
    private __gshared pthread_key_t _threadKey;
    private __gshared pthread_once_t _threadKeyOnce = PTHREAD_ONCE_INIT;

    private extern(C) void createThreadKey() nothrow @nogc {
        import core.sys.posix.pthread: pthread_key_create;

        if (pthread_key_create(&_threadKey, &releaseForeignThread) != 0)
            assert(0, "cannot create alternate signal stack cleanup key");
    }

    private extern(C) void releaseForeignThread(void* state) nothrow @nogc {
        releaseThread(*cast(ThreadState*) state);
    }

    private void releaseThread(ref ThreadState state) nothrow @nogc {
        import core.sys.posix.sys.mman: munmap;
        import core.sys.posix.signal: SS_DISABLE;

        if (state.mapping is null)
            return;

        // The guest can have replaced the stack: its own stays.
        stack_t current;
        sigaltstack(null, &current);
        if (current.ss_sp is state.mapping + guardSize) {
            stack_t disabled;
            disabled.ss_flags = SS_DISABLE;
            sigaltstack(&disabled, null);
        }
        munmap(state.mapping, state.mappingSize);
        state.mapping = null;
    }

    // Runs on the thread that faulted, off signal context.
    public extern(C) void snakebite_fault_raise() {
        auto fault = _state.prepared;
        const record = _state.record;

        fault.signal = record.signal;
        fault.address = record.address;
        fault.hostPc = record.pc;
        fault.kind = classify(record);
        fault.msg = GuestFault.message(fault.kind);
        throw fault;
    }

    private extern(C) void snakebite_fault_signal_entry(
        int, siginfo_t*, void*) nothrow @nogc;

    // The assembly entry supplies the unmodified kernel frame address and
    // can tail-enter a saved handler after moving off the alternate stack.
    private extern(C) Forward* snakebite_fault_dispatch(
        int signal, siginfo_t* info, void* context, size_t frame) nothrow @nogc {
        // A signal that a program sent (`kill`, `raise`) has no faulting
        // instruction to continue from.
        const hardware = info.si_code > 0;
        const reportable = signal != SIGFPE
            || info.si_code == fpeIntegerDivide
            || info.si_code == fpeIntegerOverflow;
        if (!hardware || !reportable || _state.runs == 0 || _state.pending)
            return hostDefect(signal, info, context, frame);

        auto registers = &(cast(ucontext_t*) context).uc_mcontext.gregs;
        const pc = cast(size_t) (*registers)[REG_RIP];
        const sp = cast(size_t) (*registers)[REG_RSP];
        const address = cast(size_t) info.si_addr;
        if (signal == SIGSEGV
            && (info.si_code == segvMapError || info.si_code == segvAccessError)
            && (address < sp ? sp - address <= guardSize : address - sp < nullLimit)) {
            import core.sys.posix.unistd: _exit, write;

            // The trampoline and unwinder cannot use an exhausted stack.
            enum message = "snakebite: fatal: stack overflow\n";
            write(2, message.ptr, message.length);
            _exit(1);
        }
        _state.pending = true;
        _state.record = FaultReport(
            signal, info.si_code, cast(size_t) info.si_addr, pc,
            signal == SIGFPE
                ? divisorOfContext(*cast(const(ucontext_t)*) context)
                : Divisor.unknown);

        // A call through a bad function pointer has faulted with the
        // return address on the stack already.
        if (signal == SIGSEGV && cast(size_t) info.si_addr == pc) {
            (*registers)[REG_RIP] = cast(size_t) &snakebite_fault_trampoline_call;
            return null;
        }

        auto top = cast(size_t*) (*registers)[REG_RSP] - 1;
        *top = pc;
        (*registers)[REG_RSP] = cast(size_t) top;
        (*registers)[REG_RIP] = cast(size_t) &snakebite_fault_trampoline;
        return null;
    }

    private Divisor divisorOfContext(ref const(ucontext_t) context) @system nothrow @nogc {
        import core.sys.posix.ucontext:
            REG_R10, REG_R11, REG_R12, REG_R13, REG_R14, REG_R15, REG_R8,
            REG_R9, REG_RAX, REG_RBP, REG_RBX, REG_RCX, REG_RDI, REG_RDX,
            REG_RSI;

        const registers = &context.uc_mcontext.gregs;
        const ulong[16] byNumber = [
            (*registers)[REG_RAX], (*registers)[REG_RCX],
            (*registers)[REG_RDX], (*registers)[REG_RBX],
            (*registers)[REG_RSP], (*registers)[REG_RBP],
            (*registers)[REG_RSI], (*registers)[REG_RDI],
            (*registers)[REG_R8], (*registers)[REG_R9],
            (*registers)[REG_R10], (*registers)[REG_R11],
            (*registers)[REG_R12], (*registers)[REG_R13],
            (*registers)[REG_R14], (*registers)[REG_R15],
        ];
        return divisorOf(
            cast(const(ubyte)*) (*registers)[REG_RIP], byNumber);
    }

    // A fault that is not a guest fault: the previous action of the signal
    // if there was one, else the default action. Returning from the
    // handler runs the faulting instruction again, and that ends the
    // process with the signal (and a core dump if the user enabled them).
    private Forward* hostDefect(
        int signal, siginfo_t* info, void* context, size_t frame) nothrow @nogc {
        import core.atomic: atomicLoad, cas;
        import core.stdc.signal: raise;
        import core.sys.posix.signal:
            SA_NODEFER, SA_RESETHAND, SIG_IGN, SIG_SETMASK, SIG_UNBLOCK,
            sigaddset, sigemptyset, sigismember, sigprocmask, sigset_t;

        size_t index;
        foreach (candidate, handled; handledSignals)
            if (handled == signal)
                index = candidate;

        while (!atomicLoad(_previousReady[index])) {}
        const previous = &_previous[index];
        const handler = previous.sa_flags & SA_SIGINFO
            ? cast(void*) previous.sa_sigaction
            : cast(void*) previous.sa_handler;
        const callable = handler !is cast(void*) SIG_DFL
            && handler !is cast(void*) SIG_IGN;
        if (callable && (!(previous.sa_flags & SA_RESETHAND)
            || cas(&_previousReset[index], false, true))) {
            alias WithInformation = extern(C) void function(
                int, siginfo_t*, void*) nothrow @nogc;
            alias WithoutInformation = extern(C) void function(int) nothrow @nogc;

            // The one-shot claim must precede any change of mask. On the
            // normal stack the collector can suspend this thread safely.
            // On an alternate stack it must stay blocked, as at signal entry.
            const interrupted = cast(ucontext_t*) context;
            sigset_t savedMask;
            const location = cast(size_t) &savedMask;
            const alternate = cast(size_t) interrupted.uc_stack.ss_sp;
            const onAlternate = location >= alternate
                && location - alternate < interrupted.uc_stack.ss_size;
            const sp = cast(size_t) interrupted.uc_mcontext.gregs[REG_RSP];
            const wasOnAlternate = sp >= alternate
                && sp - alternate < interrupted.uc_stack.ss_size;
            if (onAlternate && !wasOnAlternate && !(previous.sa_flags & SA_ONSTACK))
                return forwardOnNormalStack(signal, info, interrupted, frame, handler,
                    previous.sa_mask, (previous.sa_flags & SA_NODEFER) != 0);
            const unmask = (previous.sa_flags & SA_NODEFER)
                && !sigismember(&previous.sa_mask, signal)
                && !sigismember(&interrupted.uc_sigmask, signal);
            bool changed;
            if (!onAlternate) {
                const allowed = previousHandlerMask(previous.sa_mask,
                    interrupted.uc_sigmask, signal, (previous.sa_flags & SA_NODEFER) != 0);
                changed = sigprocmask(SIG_SETMASK, &allowed, &savedMask) == 0;
            } else if (unmask) {
                sigset_t allowed;
                sigemptyset(&allowed);
                sigaddset(&allowed, signal);
                changed = sigprocmask(SIG_UNBLOCK, &allowed, &savedMask) == 0;
            }
            if (previous.sa_flags & SA_SIGINFO)
                (cast(WithInformation) handler)(signal, info, context);
            else
                (cast(WithoutInformation) handler)(signal);
            if (changed)
                sigprocmask(SIG_SETMASK, &savedMask, null);
            return null;
        }

        // A program that ignored the signal and a program that sent it get
        // what they asked for.
        if (info.si_code <= 0 && handler is cast(void*) SIG_IGN)
            return null;

        if (info.si_code > 0 && _state.runs != 0)
            reportUnhandledGuestFault(signal, info, context);
        sigaction_t default_;
        default_.sa_handler = SIG_DFL;
        sigaction(signal, &default_, null);
        // A signal that was sent is not raised again by returning.
        if (info.si_code <= 0)
            raise(signal);
        return null;
    }

    private struct Forward {
        void* stack;
        void* handler;
        siginfo_t* info;
        ucontext_t* context;
        int signal;
        sigset_t mask;
        const(void)* source;
        size_t length;
        void* floatingPoint;
    }
    // The assembly reads every field before unblocking signals. Nested
    // delivery can then reuse this thread's packet, not the moved frame.
    private Forward _forward;
    static assert(Forward.mask.offsetof == 40);
    static assert(Forward.source.offsetof == 168);
    static assert(Forward.length.offsetof == 176);
    static assert(Forward.floatingPoint.offsetof == 184);
    static assert(ucontext_t.uc_mcontext.offsetof == 40);
    static assert(imported!"core.sys.posix.ucontext".mcontext_t.gregs.offsetof == 0);
    static assert(imported!"core.sys.posix.ucontext".mcontext_t.fpregs.offsetof == 184);

    private imported!"core.sys.posix.signal".sigset_t previousHandlerMask(
        ref const(imported!"core.sys.posix.signal".sigset_t) saved,
        ref const(imported!"core.sys.posix.signal".sigset_t) interrupted,
        int signal, bool nodefer) nothrow @nogc {
        import core.sys.posix.signal: sigaddset;

        sigset_t allowed = saved;
        // Linux x86-64 has 64 signals; the other words are libc padding.
        allowed.__val[0] |= interrupted.__val[0];
        if (!nodefer)
            sigaddset(&allowed, signal);
        return allowed;
    }

    private Forward* forwardOnNormalStack(int signal, siginfo_t* info,
        const(ucontext_t)* context, size_t frame, const(void)* handler,
        ref const(imported!"core.sys.posix.signal".sigset_t) savedMask,
        bool nodefer) nothrow @nogc {
        // Linux x86-64 rt_sigreturn receives the context just after the
        // restorer slot. Relocate the kernel's actual frame, including its
        // variable-length XSAVE image, rather than construct a new frame.
        // Keep the same alignment and leave the interrupted red zone alone.
        const source = cast(size_t) context - size_t.sizeof;
        const base = cast(size_t) context.uc_stack.ss_sp;
        const limit = base + context.uc_stack.ss_size;
        if (source != frame || source < base || limit < base || source >= limit)
            brokenSignalFrame;
        size_t end = cast(size_t) info + siginfo_t.sizeof;
        if (end < source || end > limit)
            brokenSignalFrame;
        if (context.uc_mcontext.fpregs !is null) {
            const fp = cast(const(ubyte)*) context.uc_mcontext.fpregs;
            const address = cast(size_t) fp;
            size_t size = typeof(*context.uc_mcontext.fpregs).sizeof;
            if (address < source || address > limit || size > limit - address)
                brokenSignalFrame;
            // Linux's _fpx_sw_bytes header is in the legacy FXSAVE area.
            // extended_size includes the trailing FP_XSTATE_MAGIC2 word.
            if (*cast(const(uint)*) (fp + 464) == 0x46505853) {
                const extended = *cast(const(uint)*) (fp + 468);
                if (extended < size || extended > limit - address)
                    brokenSignalFrame;
                size = extended;
            }
            if (address + size > end)
                end = address + size;
        }
        const length = end - source;
        const low = source & 63;
        const sp = cast(size_t) context.uc_mcontext.gregs[REG_RSP];
        if (sp < 128 + length + low)
            brokenSignalFrame;
        const target = ((sp - 128 - length - low) & ~cast(size_t) 63) + low;
        // Placement happens in assembly after switching RSP to this stack.
        // Ordinary page faults can then grow a valid MAP_GROWSDOWN mapping;
        // remote memory access cannot establish native stack accessibility.
        _forward.stack = cast(void*) target;
        _forward.handler = cast(void*) handler;
        _forward.info = cast(siginfo_t*) (target + cast(size_t) info - source);
        _forward.context = cast(ucontext_t*) (target + size_t.sizeof);
        _forward.signal = signal;
        _forward.mask = previousHandlerMask(savedMask, context.uc_sigmask, signal, nodefer);
        _forward.source = cast(const(void)*) source;
        _forward.length = length;
        _forward.floatingPoint = context.uc_mcontext.fpregs is null ? null
            : cast(void*) (target + cast(size_t) context.uc_mcontext.fpregs - source);
        return &_forward;
    }

    private void brokenSignalFrame() nothrow @nogc {
        import core.stdc.signal: raise;
        import core.sys.posix.signal:
            SIG_UNBLOCK, sigaddset, sigemptyset, sigprocmask, sigset_t;
        import core.sys.posix.unistd: _exit;

        sigaction_t action;
        action.sa_handler = SIG_DFL;
        sigaction(SIGSEGV, &action, null);
        sigset_t allowed;
        sigemptyset(&allowed);
        sigaddset(&allowed, SIGSEGV);
        sigprocmask(SIG_UNBLOCK, &allowed, null);
        raise(SIGSEGV);
        _exit(128 + SIGSEGV);
    }

    private void reportUnhandledGuestFault(int signal, siginfo_t* info, void* context) nothrow @nogc {
        import core.sys.posix.unistd: write;

        char[128] line = void;
        size_t length;
        void put(in char[] text) nothrow @nogc {
            foreach (character; text)
                if (length < line.length)
                    line[length++] = character;
        }
        void putNumber(ulong value, in uint base) nothrow @nogc {
            char[20] digits = void;
            size_t start = digits.length;
            do {
                digits[--start] = "0123456789abcdef"[value % base];
                value /= base;
            } while (value != 0);
            put(digits[start .. $]);
        }

        // A thread in a guest run most likely has a fault of the guest that
        // no handler of the guest run took: do not blame the host.
        put("snakebite: fatal: fault of the guest program: signal ");
        putNumber(signal, 10);
        put(" at address 0x");
        putNumber(cast(size_t) info.si_addr, 16);
        put(" (host pc 0x");
        putNumber((cast(ucontext_t*) context).uc_mcontext.gregs[REG_RIP], 16);
        put(")");
        put("\n");
        write(2, line.ptr, length);
    }
}
