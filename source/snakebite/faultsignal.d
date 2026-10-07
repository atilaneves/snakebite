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
// (`installFaultHandlers`). From then until the process ends, the kernel
// action of these signals is ours, with no `SA_RESETHAND`: druntime's
// `runModuleUnitTests` installs a one-shot handler for `SIGSEGV` and
// `SIGBUS` and a guest fault on another thread would then kill the process.
// This executable therefore defines `sigaction` (`interposedSigaction`) and
// the functions of glibc that do the same job (`signal`, `sigset`, ...). A
// request for one of these signals never reaches the kernel, from any
// thread, and the guest is not an exception: its calls resolve to these
// definitions too (`interposedAddress`). A guest that installs a handler of
// its own for a fault signal gets it called for a fault on its thread, as in
// compiled D, but the kernel keeps ours.
//
// What no symbol can stop is a system call: `rt_sigaction` made directly,
// by assembly, by a library that does not use libc, or through glibc's
// private `__libc_sigaction`, changes the kernel
// action. That is the one exception.
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
// this thread. Nested entries are allowed inside `body`.
// This does not restore other host state owned inside `body`.
// Backends must discard halted execution state, as required by #523.
public void runGuest(scope void delegate() body) @system {
    static if (supported)
        runGuest(&body, &invokeGuestBody);
    else
        body();
}


public alias GuestBody = extern(C) void function(void*);
public alias BeforeFault = void function(void*, HardwareFault) nothrow @nogc;

// A backend already has an entry record. Calling its entry directly avoids
// a second delegate entry and keeps the same protected cleanup owner.
public void runGuest(void* context, GuestBody body) @system {
    runGuest(context, body, null, null);
}

// Runs outside signal context, before throwing starts native unwinding.
// The hook only marks owned host state. It must not run guest code: native
// cleanup can call back before the backend's first catch receives the fault.
public void runGuest(
    void* context, GuestBody body, void* faultContext, BeforeFault beforeFault,
) @system {
    static if (supported) {
        if (_state.prepared is null)
            prepareThread;
        RunOwner owner;
        owner.faultContext = faultContext;
        owner.beforeFault = beforeFault;
        owner.enter;
        scope(exit) owner.leave;
        snakebite_fault_invoke(context, body);
    } else
        body(context);
}


static if (supported) {
    private extern(C) void snakebite_fault_invoke(void* context, GuestBody body);

    private extern(C) void invokeGuestBody(void* context) {
        (*cast(void delegate()*) context)();
    }

    private struct RunOwner {
        import core.thread.fiber: Fiber;

        Fiber fiber;
        RunOwner* next;
        void* faultContext;
        BeforeFault beforeFault;

        void enter() nothrow @nogc {
            // Resolve druntime's TLS accessor before a signal can use it.
            fiber = Fiber.getThis;
            next = _state.runs;
            _state.runs = &this;
        }

        void leave() nothrow @nogc {
            auto link = &_state.runs;
            while (*link !is &this)
                link = &(*link).next;
            *link = next;
            // The actions that the guest set end with its outermost run.
            if (_state.runs is null)
                foreach (ref guest; _state.guest)
                    guest.set = false;
        }
    }
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
        import core.atomic: atomicLoad, atomicStore;
        import core.stdc.stdlib: getenv;

        if (getenv("SNAKEBITE_NO_FAULT_HANDLER") !is null)
            return false;

        const next = nextSigaction;
        auto held = SignalTableLock.acquire;
        if (atomicLoad(_installed))
            return true;

        sigaction_t action;
        action.sa_sigaction = &snakebite_fault_signal_entry;
        action.sa_flags = SA_SIGINFO | SA_ONSTACK;
        // The collector suspends threads with a signal. While the handler
        // runs on the alternate stack, the collector would take the pointer
        // into it as the top of the stack of the thread, and scan memory
        // that is not mapped. With every signal blocked, the suspension
        // waits until the thread is back on its own stack.
        sigfillset(&action.sa_mask);
        foreach (signal; handledSignals) {
            sigaction_t previous;
            if (next(signal, &action, &previous) != 0)
                assert(0, "sigaction failed for a fault signal");
            publishPrevious(cast(size_t) signal, previous);
        }
        // The kernel needs a restorer to return from a handler, and libc
        // adds its own to each action it installs. A request that the
        // interposer records gets the same one, because the handler
        // forwards to the recorded action.
        sigaction_t installed;
        if (next(SIGSEGV, null, &installed) != 0)
            assert(0, "sigaction failed to read the fault action");
        if (installed.sa_flags & saRestorer)
            _restorer = installed.sa_restorer;
        atomicStore(_installed, true);

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
        SIG_IGN,
        SIGBUS,
        SIGFPE,
        SIGSEGV,
        siginfo_t,
        sigaction_t,
        SA_RESETHAND,
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
    private bool ownsCurrentFiber() nothrow @nogc {
        import core.thread.fiber: Fiber;

        if (_state.runs is null)
            return false;
        const fiber = Fiber.getThis;
        auto owner = _state.runs;
        while (owner !is null) {
            if (owner.fiber is fiber)
                return true;
            owner = owner.next;
        }
        return false;
    }

    // What a guest asked of `sigaction` on this thread (`interposedSigaction`).
    private struct GuestAction {
        bool set;
        sigaction_t action;
    }

    private struct ThreadState {
        RunOwner* runs;
        GuestAction[signalCapacity] guest;
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
    private shared bool _installed;
    private enum saRestorer = 0x04000000;
    // Written once under the lock before `_installed` is set.
    private __gshared typeof(sigaction_t.sa_restorer) _restorer;
    // What the signals did before this module, or what the last caller of
    // `interposedSigaction` asked for: a fault of the host goes to it (a
    // sanitizer, a host that embeds snakebite, druntime's backtrace
    // handler). Direct signal indices avoid a search on each forwarded
    // delivery.
    private enum signalCapacity = SIGSEGV + 1;
    static assert(SIGFPE < signalCapacity && SIGBUS < signalCapacity);

    // `sequence` guards `action` for readers in a signal handler, which
    // cannot take the lock. Bit 0: a write is in progress. Bit 1: the
    // action has `SA_RESETHAND` and a handler already claimed its one
    // delivery. The remaining bits count the writes, and zero means that
    // nothing has been written. A write clears bit 1.
    private enum writing = 1UL;
    private enum claimed = 2UL;
    private enum step = 4UL;
    private struct PreviousAction {
        sigaction_t action;
        shared size_t sequence;
    }
    private __gshared PreviousAction[signalCapacity] _previous;
    private shared bool _tableLock;

    // Holds the lock of `_previous` and the kernel action of the fault
    // signals with every signal blocked. A handler on this thread waits for
    // a write to finish, so the thread must not receive one in the
    // meantime. The collector is blocked too, as in the handler itself.
    private struct SignalTableLock {
        import core.sys.posix.signal: sigset_t;

        sigset_t saved;

        @disable this(this);

        static SignalTableLock acquire() @trusted nothrow @nogc {
            import core.atomic: cas;
            import core.sys.posix.signal: SIG_SETMASK, sigprocmask;

            SignalTableLock held;
            sigset_t blocked;
            sigfillset(&blocked);
            if (sigprocmask(SIG_SETMASK, &blocked, &held.saved) != 0)
                assert(0, "cannot block signals for the fault action table");
            while (!cas(&_tableLock, false, true)) {}
            return held;
        }

        ~this() @trusted nothrow @nogc {
            import core.atomic: atomicStore;
            import core.sys.posix.signal: SIG_SETMASK, sigprocmask;

            atomicStore(_tableLock, false);
            if (sigprocmask(SIG_SETMASK, &saved, null) != 0)
                assert(0, "cannot restore signals after the fault action table");
        }
    }

    // The caller holds the lock.
    private void publishPrevious(size_t index, ref const sigaction_t action)
        @trusted nothrow @nogc {
        import core.atomic: atomicFence, atomicLoad, atomicStore;

        auto slot = &_previous[index];
        const current = atomicLoad(slot.sequence);
        atomicStore(slot.sequence, (current | writing));
        atomicFence;
        slot.action = action;
        atomicFence;
        atomicStore(slot.sequence, ((current & ~(writing | claimed)) + step));
    }

    // The next definition of `sigaction` after the one of this executable:
    // libc's, or a library that wraps it (a test can put one in between).
    // A call by name from here would reach `interposedSigaction`.
    private alias NextSigaction = extern(C) int function(
        int, const(sigaction_t)*, sigaction_t*) nothrow @nogc;
    private __gshared NextSigaction _nextSigaction;

    private NextSigaction nextSigaction() @trusted nothrow @nogc {
        import core.sys.posix.dlfcn: dlsym;

        // Not in druntime's declarations, which lack `_GNU_SOURCE`.
        enum RTLD_NEXT = cast(void*) -1;

        if (auto known = _nextSigaction)
            return known;
        auto found = cast(NextSigaction) dlsym(RTLD_NEXT, "sigaction");
        if (found is null)
            assert(0, "cannot find the next sigaction");
        _nextSigaction = found;
        return found;
    }

    // The definition that every other caller of `sigaction` gets, in the
    // executable and in a shared druntime: the dynamic linker binds the
    // shared library to the executable's symbol first. Once the fault
    // handlers are installed, a request to change the action of a fault
    // signal never reaches the kernel, from any thread. `runModuleUnitTests`
    // saves and restores actions this way, and nothing in between can change
    // what the kernel delivers.
    //
    // The request of a thread that runs guest code is the action of the
    // guest on that thread: a fault of the guest on that thread goes to it,
    // and the guest reads it back, until the outermost run of the thread
    // ends. Any other request becomes what the handlers forward a fault to
    // when it is not a guest fault, and the caller sees it as the action in
    // force. `SA_RESETHAND` is one delivery, then `SIG_DFL`. `SIG_DFL` and
    // `SIG_IGN` of the guest leave a guest fault to the recovery.
    //
    // A system call that sets the action (`rt_sigaction`) does not use this
    // symbol and still reaches the kernel.
    pragma(mangle, "sigaction")
    public extern(C) int interposedSigaction(
        int signal, const(sigaction_t)* action, sigaction_t* old)
        @trusted nothrow @nogc {
        import core.atomic: atomicLoad;
        import core.sys.posix.signal: SA_RESETHAND;

        const next = nextSigaction;
        if (signal != SIGSEGV && signal != SIGFPE && signal != SIGBUS)
            return next(signal, action, old);

        // Before the lock: a bad pointer of the caller is its own fault.
        sigaction_t requested = action is null ? sigaction_t.init : *action;
        sigaction_t reported;
        {
            auto held = SignalTableLock.acquire;
            if (!atomicLoad(_installed))
                return next(signal, action, old);

            if (_restorer !is null && !(requested.sa_flags & saRestorer)) {
                requested.sa_flags |= saRestorer;
                requested.sa_restorer = _restorer;
            }
            const index = cast(size_t) signal;
            auto slot = &_previous[index];
            auto mine = &_state.guest[index];
            const forGuest = ownsCurrentFiber;
            if (forGuest && mine.set)
                reported = mine.action;
            else {
                reported = slot.action;
                // The handler that ran its one delivery has reset the action.
                if (atomicLoad(slot.sequence) & claimed) {
                    reported = sigaction_t.init;
                    reported.sa_handler = SIG_DFL;
                }
            }
            if (action !is null) {
                if (forGuest) {
                    mine.set = true;
                    mine.action = requested;
                } else
                    publishPrevious(index, requested);
            }
        }
        if (old !is null)
            *old = reported;
        return 0;
    }

    // glibc exports a second name for `sigaction`.
    pragma(mangle, "__sigaction")
    public extern(C) int interposedUnderscoreSigaction(
        int signal, const(sigaction_t)* action, sigaction_t* old)
        @trusted nothrow @nogc {
        return interposedSigaction(signal, action, old);
    }

    // The other functions of glibc that change the action of a signal. They
    // call an internal `sigaction` that no symbol can interpose, so each
    // one is the same request made of `interposedSigaction`. A handler of
    // `SIG_ERR` is `-1`.
    private enum sigHold = cast(size_t) 2;
    private enum sigError = cast(void*) -1;

    private void* setHandler(
        int signal, void* handler, int flags, bool blockSignal) @trusted nothrow @nogc {
        import core.sys.posix.signal: sigaddset, sigemptyset;

        if (handler is sigError)
            return invalidSignal;
        sigaction_t requested;
        requested.sa_handler = cast(typeof(requested.sa_handler)) handler;
        requested.sa_flags = flags;
        sigemptyset(&requested.sa_mask);
        if (blockSignal)
            sigaddset(&requested.sa_mask, signal);
        sigaction_t old;
        if (interposedSigaction(signal, &requested, &old) != 0)
            return sigError;
        return cast(void*) old.sa_handler;
    }

    private void* invalidSignal() @trusted nothrow @nogc {
        import core.stdc.errno: EINVAL, errno;

        errno = EINVAL;
        return sigError;
    }

    private enum bsdFlags = imported!"core.sys.posix.signal".SA_RESTART;
    private enum sysvFlags = imported!"core.sys.posix.signal".SA_RESETHAND
        | imported!"core.sys.posix.signal".SA_NODEFER;

    pragma(mangle, "signal")
    public extern(C) void* interposedSignal(int signal, void* handler)
        @trusted nothrow @nogc {
        return setHandler(signal, handler, bsdFlags, true);
    }

    pragma(mangle, "bsd_signal")
    public extern(C) void* interposedBsdSignal(int signal, void* handler)
        @trusted nothrow @nogc {
        return setHandler(signal, handler, bsdFlags, true);
    }

    pragma(mangle, "ssignal")
    public extern(C) void* interposedSsignal(int signal, void* handler)
        @trusted nothrow @nogc {
        return setHandler(signal, handler, bsdFlags, true);
    }

    pragma(mangle, "sysv_signal")
    public extern(C) void* interposedSysvSignal(int signal, void* handler)
        @trusted nothrow @nogc {
        return setHandler(signal, handler, sysvFlags, false);
    }

    pragma(mangle, "__sysv_signal")
    public extern(C) void* interposedUnderscoreSysvSignal(int signal, void* handler)
        @trusted nothrow @nogc {
        return setHandler(signal, handler, sysvFlags, false);
    }

    pragma(mangle, "sigset")
    public extern(C) void* interposedSigset(int signal, void* handler)
        @trusted nothrow @nogc {
        import core.sys.posix.signal: SIG_BLOCK, SIG_UNBLOCK, sigaddset,
            sigemptyset, sigismember, sigprocmask;

        sigset_t one;
        sigemptyset(&one);
        sigaddset(&one, signal);
        if (handler is cast(void*) sigHold) {
            sigset_t before;
            sigprocmask(SIG_BLOCK, &one, &before);
            sigaction_t old;
            if (interposedSigaction(signal, null, &old) != 0)
                return sigError;
            return sigismember(&before, signal) == 1 ? cast(void*) sigHold : cast(void*) old.sa_handler;
        }
        sigset_t before;
        sigprocmask(SIG_UNBLOCK, &one, &before);
        void* old = setHandler(signal, handler, 0, false);
        if (old is sigError)
            return old;
        return sigismember(&before, signal) == 1 ? cast(void*) sigHold : old;
    }

    pragma(mangle, "sigignore")
    public extern(C) int interposedSigignore(int signal) @trusted nothrow @nogc {
        return setHandler(signal, cast(void*) SIG_IGN, 0, false) is sigError ? -1 : 0;
    }

    pragma(mangle, "siginterrupt")
    public extern(C) int interposedSiginterrupt(int signal, int interrupt)
        @trusted nothrow @nogc {
        import core.sys.posix.signal: SA_RESTART;

        sigaction_t action;
        if (interposedSigaction(signal, null, &action) != 0)
            return -1;
        if (interrupt)
            action.sa_flags &= ~SA_RESTART;
        else
            action.sa_flags |= SA_RESTART;
        return interposedSigaction(signal, &action, null);
    }

    private struct SigVec {
        void* sv_handler;
        int sv_mask;
        int sv_flags;
    }

    pragma(mangle, "sigvec")
    public extern(C) int interposedSigvec(int signal, const(SigVec)* vector, SigVec* old)
        @trusted nothrow @nogc {
        import core.sys.posix.signal: SA_RESTART, sigemptyset;

        // `SV_ONSTACK`, `SV_INTERRUPT` and `SV_RESETHAND` of the BSD API.
        enum onStack = 1, interrupt = 2, resetHand = 4;

        sigaction_t requested;
        if (vector !is null) {
            const vec = *vector;
            requested.sa_handler = cast(typeof(requested.sa_handler)) vec.sv_handler;
            sigemptyset(&requested.sa_mask);
            requested.sa_mask.__val[0] = cast(uint) vec.sv_mask;
            requested.sa_flags = ((vec.sv_flags & onStack) ? SA_ONSTACK : 0)
                | ((vec.sv_flags & resetHand) ? SA_RESETHAND : 0)
                | ((vec.sv_flags & interrupt) ? 0 : SA_RESTART);
        }
        sigaction_t previous;
        if (interposedSigaction(signal, vector is null ? null : &requested, &previous) != 0)
            return -1;
        if (old !is null) {
            SigVec reported;
            reported.sv_handler = cast(void*) previous.sa_handler;
            reported.sv_mask = cast(int) previous.sa_mask.__val[0];
            reported.sv_flags = ((previous.sa_flags & SA_ONSTACK) ? onStack : 0)
                | ((previous.sa_flags & SA_RESETHAND) ? resetHand : 0)
                | ((previous.sa_flags & SA_RESTART) ? 0 : interrupt);
            *old = reported;
        }
        return 0;
    }

    // The address of the definition here for a name that this executable
    // takes from the libraries (see `interposedSigaction`), or null. dmd emits
    // each function as a weak symbol, so the linker does not report another
    // definition of one of these names: a test compares the symbol that the
    // process binds with this address.
    public void* interposedAddress(in char[] name) @trusted nothrow @nogc {
        switch (name) {
            case "sigaction": return &interposedSigaction;
            case "__sigaction": return &interposedUnderscoreSigaction;
            case "signal": return &interposedSignal;
            case "bsd_signal": return &interposedBsdSignal;
            case "ssignal": return &interposedSsignal;
            case "sysv_signal": return &interposedSysvSignal;
            case "__sysv_signal": return &interposedUnderscoreSysvSignal;
            case "sigset": return &interposedSigset;
            case "sigignore": return &interposedSigignore;
            case "siginterrupt": return &interposedSiginterrupt;
            case "sigvec": return &interposedSigvec;
            default: return null;
        }
    }

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
        import core.thread.fiber: Fiber;

        const fiber = Fiber.getThis;
        auto owner = _state.runs;
        while (owner !is null) {
            if (owner.fiber is fiber && owner.beforeFault !is null)
                owner.beforeFault(owner.faultContext, fault);
            owner = owner.next;
        }
        throw fault;
    }

    private extern(C) void snakebite_fault_signal_entry(
        int, siginfo_t*, void*) nothrow @nogc;

    // The assembly entry supplies the unmodified kernel frame address and
    // can tail-enter a saved handler after moving off the alternate stack.
    private extern(C) Forward* snakebite_fault_dispatch(
        int signal, siginfo_t* info, void* context, size_t frame) nothrow @nogc {
        if (guestHandlerTakes(signal))
            return forwardToGuest(signal, info, context, frame);

        // A signal that a program sent (`kill`, `raise`) has no faulting
        // instruction to continue from.
        const hardware = info.si_code > 0;
        const reportable = signal != SIGFPE
            || info.si_code == fpeIntegerDivide
            || info.si_code == fpeIntegerOverflow;
        if (!hardware || !reportable || _state.pending || !ownsCurrentFiber)
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

    private bool guestHandlerTakes(int signal) nothrow @nogc {
        const mine = &_state.guest[cast(size_t) signal];
        if (!mine.set || !ownsCurrentFiber)
            return false;
        const handler = mine.action.sa_flags & SA_SIGINFO
            ? cast(void*) mine.action.sa_sigaction
            : cast(void*) mine.action.sa_handler;
        return handler !is cast(void*) SIG_DFL && handler !is cast(void*) SIG_IGN;
    }

    private Forward* forwardToGuest(
        int signal, siginfo_t* info, void* context, size_t frame) nothrow @nogc {
        auto mine = &_state.guest[cast(size_t) signal];
        _snapshot = mine.action;
        if (mine.action.sa_flags & SA_RESETHAND) {
            mine.action = sigaction_t.init;
            mine.action.sa_handler = SIG_DFL;
        }
        return forwardPreviousAction(
            signal, info, cast(ucontext_t*) context, frame, &_snapshot);
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

    // This thread's copy of the previous action. `_forward.previous` points
    // here until the assembly has entered the handler.
    private sigaction_t _snapshot;

    // A consistent copy of the action, and the sequence it was read at.
    private size_t snapshotPrevious(size_t index, ref sigaction_t copy)
        nothrow @nogc {
        import core.atomic: atomicFence, atomicLoad;

        auto slot = &_previous[index];
        for (;;) {
            const before = atomicLoad(slot.sequence);
            // Zero: the installation has not published the action yet.
            if (before == 0 || (before & writing))
                continue;
            atomicFence;
            copy = slot.action;
            atomicFence;
            if (atomicLoad(slot.sequence) == before)
                return before;
        }
    }

    // A fault that is not a guest fault: the previous action of the signal
    // if there was one, else the default action. Returning from the
    // handler runs the faulting instruction again, and that ends the
    // process with the signal (and a core dump if the user enabled them).
    private Forward* hostDefect(
        int signal, siginfo_t* info, void* context, size_t frame) nothrow @nogc {
        import core.atomic: atomicLoad, cas;
        import core.stdc.signal: raise;
        
        const index = cast(size_t) signal;
        const previous = &_snapshot;
        bool forward;
        const guest = &_state.guest[index];
        if (guest.set && ownsCurrentFiber)
            _snapshot = guest.action;
        else for (;;) {
            const version_ = snapshotPrevious(index, _snapshot);
            const handler = previous.sa_flags & SA_SIGINFO
                ? cast(void*) previous.sa_sigaction
                : cast(void*) previous.sa_handler;
            const callable = handler !is cast(void*) SIG_DFL
                && handler !is cast(void*) SIG_IGN;
            if (!callable)
                break;
            if (!(previous.sa_flags & SA_RESETHAND)) {
                forward = true;
                break;
            }
            if (version_ & claimed)
                break;
            // The one-shot claim fails when the action changed meanwhile.
            if (cas(&_previous[index].sequence, version_, version_ | claimed)) {
                forward = true;
                break;
            }
        }
        if (forward) {
            // The one-shot claim must precede any change of mask. On the
            // normal stack the collector can suspend this thread safely.
            // On an alternate stack it must stay blocked, as at signal entry.
            return forwardPreviousAction(signal, info, cast(ucontext_t*) context,
                frame, previous);
        }
        const handler = previous.sa_flags & SA_SIGINFO
            ? cast(void*) previous.sa_sigaction
            : cast(void*) previous.sa_handler;

        // A program that ignored the signal and a program that sent it get
        // what they asked for.
        if (info.si_code <= 0 && handler is cast(void*) SIG_IGN)
            return null;

        if (info.si_code > 0 && ownsCurrentFiber)
            reportUnhandledGuestFault(signal, info, context);
        sigaction_t default_;
        default_.sa_handler = SIG_DFL;
        nextSigaction()(signal, &default_, null);
        // A signal that was sent is not raised again by returning.
        if (info.si_code <= 0)
            raise(signal);
        return null;
    }

    pragma(inline, true) private Forward* forwardPreviousAction(int signal,
        imported!"core.sys.posix.signal".siginfo_t* info,
        imported!"core.sys.posix.ucontext".ucontext_t* context,
        size_t frame,
        const(imported!"core.sys.posix.signal".sigaction_t)* previous) nothrow @nogc {
        import core.sys.posix.signal: SA_NODEFER, sigdelset, sigismember;

        const location = cast(size_t) &frame;
        const alternate = cast(size_t) context.uc_stack.ss_sp;
        const onAlternate = location >= alternate
            && location - alternate < context.uc_stack.ss_size;
        const sp = cast(size_t) context.uc_mcontext.gregs[REG_RSP];
        const wasOnAlternate = sp >= alternate
            && sp - alternate < context.uc_stack.ss_size;
        const relocate = onAlternate && !wasOnAlternate
            && !(previous.sa_flags & SA_ONSTACK);
        const nodefer = (previous.sa_flags & SA_NODEFER) != 0;
        if (relocate) {
            placeNormalSignalFrame(info, context, frame);
        } else {
            _forward.stack = cast(void*) frame;
            _forward.length = 0;
        }
        _forward.previous = previous;
        _forward.setMask = !onAlternate || relocate;
        if (_forward.setMask) {
            previousHandlerMask(_forward.mask, previous.sa_mask,
                context.uc_sigmask, signal, nodefer);
        } else if (nodefer && !sigismember(&previous.sa_mask, signal)
            && !sigismember(&context.uc_sigmask, signal)) {
            // Retain the entry's collector block on the alternate stack.
            sigfillset(&_forward.mask);
            sigdelset(&_forward.mask, signal);
            _forward.setMask = true;
        }
        return &_forward;
    }

    private struct Forward {
        void* stack;
        const(sigaction_t)* previous;
        siginfo_t* info;
        ucontext_t* context;
        bool setMask;
        sigset_t mask;
        const(void)* source;
        size_t length;
        void* floatingPoint;
    }
    // The assembly reads the packet before unblocking signals. Nested
    // delivery can then reuse this thread's packet, not the moved frame.
    private Forward _forward;
    static assert(Forward.stack.offsetof == 0);
    static assert(Forward.previous.offsetof == 8);
    static assert(sigaction_t.sa_handler.offsetof == 0);
    static assert(sigaction_t.sa_sigaction.offsetof == 0);
    static assert(sigaction_t.sa_flags.offsetof == 136);
    static assert(sigaction_t.sa_restorer.offsetof == 144);
    static assert(Forward.info.offsetof == 16);
    static assert(Forward.context.offsetof == 24);
    static assert(Forward.mask.offsetof == 40);
    static assert(Forward.source.offsetof == 168);
    static assert(Forward.length.offsetof == 176);
    static assert(Forward.floatingPoint.offsetof == 184);
    static assert(Forward.setMask.offsetof == 32);
    static assert(Forward.sizeof == 192);
    static assert(ucontext_t.uc_mcontext.offsetof == 40);
    static assert(imported!"core.sys.posix.ucontext".mcontext_t.gregs.offsetof == 0);
    static assert(imported!"core.sys.posix.ucontext".mcontext_t.fpregs.offsetof == 184);

    pragma(inline, true) private void previousHandlerMask(
        ref imported!"core.sys.posix.signal".sigset_t allowed,
        ref const(imported!"core.sys.posix.signal".sigset_t) saved,
        ref const(imported!"core.sys.posix.signal".sigset_t) interrupted,
        int signal, bool nodefer) @safe pure nothrow @nogc {
        // Linux x86-64 has 64 signals; the other words are libc padding.
        const self = nodefer ? 0UL : 1UL << (signal - 1);
        allowed.__val[0] = saved.__val[0] | interrupted.__val[0] | self;
    }

    pragma(inline, true) private void placeNormalSignalFrame(
        imported!"core.sys.posix.signal".siginfo_t* info,
        const(imported!"core.sys.posix.ucontext".ucontext_t)* context,
        size_t frame) nothrow @nogc {
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
        _forward.info = cast(siginfo_t*) (target + cast(size_t) info - source);
        _forward.context = cast(ucontext_t*) (target + size_t.sizeof);
        _forward.source = cast(const(void)*) source;
        _forward.length = length;
        _forward.floatingPoint = context.uc_mcontext.fpregs is null ? null
            : cast(void*) (target + cast(size_t) context.uc_mcontext.fpregs - source);
    }

    private void brokenSignalFrame() nothrow @nogc {
        import core.stdc.signal: raise;
        import core.sys.posix.signal:
            SIG_UNBLOCK, sigaddset, sigemptyset, sigprocmask, sigset_t;
        import core.sys.posix.unistd: _exit;

        sigaction_t action;
        action.sa_handler = SIG_DFL;
        nextSigaction()(SIGSEGV, &action, null);
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

static if (!supported)
    public void* interposedAddress(in char[]) @safe @nogc nothrow pure {
        return null;
    }
