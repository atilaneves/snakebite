module snakebite.faulthandler;


private:


// What a process of compiled D does when its code faults: it writes nothing
// and dies of the signal. This handler adds one line on standard error, then
// leaves the default action in place and returns, so that the instruction
// that faulted runs again and the process dies of the real signal.
//
// Nothing here is recoverable and nothing continues after a fault. The
// handler makes no allocation, takes no lock and throws nothing: the fault
// can happen while `malloc` or the collector holds a lock.

// Where the guest code that runs on a stack is at a moment, as the backend
// that runs it knows. `function_` is empty when the backend cannot tell, and
// `file` is empty when it cannot tell the line.
public struct GuestPosition {
    public const(char)[] function_;
    public const(char)[] file;
    public size_t line;
}

// What a backend registers while guest code runs on a native stack of its
// own: a Fiber and a thread each have one, and they run in turn. The
// handler picks the entry whose stack it runs on, so that each reports its
// own position. `position` runs inside the signal handler, so it must read
// state that already exists and nothing else.
public struct GuestRun {
    public alias Position = GuestPosition function(void* context)
        nothrow @nogc;

    public void* context;
    public Position position;
    public const(void)* stackBottom;
    public const(void)* stackTop;

    private GuestRun* _previous;
    private GuestRun* _next;
}

private GuestRun* _guestRuns;

public void register(GuestRun* run) @system nothrow @nogc {
    run._previous = null;
    run._next = _guestRuns;
    if (_guestRuns !is null)
        _guestRuns._previous = run;
    _guestRuns = run;
}

public void unregister(GuestRun* run) @system nothrow @nogc {
    if (run._previous is null)
        _guestRuns = run._next;
    else
        run._previous._next = run._next;
    if (run._next !is null)
        run._next._previous = run._previous;
}

private shared static this() @trusted nothrow @nogc {
    import core.sys.posix.signal:
        sigaction, sigaction_t, sigemptyset, SA_RESETHAND, SA_SIGINFO,
        SIGFPE, SIGSEGV;

    // `SA_RESETHAND` puts the default action back before the handler runs.
    sigaction_t action;
    action.sa_sigaction = &onFault;
    action.sa_flags = SA_SIGINFO | SA_RESETHAND;
    sigemptyset(&action.sa_mask);
    sigaction(SIGSEGV, &action, null);
    sigaction(SIGFPE, &action, null);
}

private extern (C) void onFault(
    int signal, imported!"core.sys.posix.signal".siginfo_t* info, void*,
) @system nothrow @nogc {
    import core.sys.posix.signal: raise;

    // A signal that something sent (`kill`, `raise`) is no fault of the
    // guest. `raise` leaves it pending: it is delivered when this handler
    // returns, and the default action ends the process. `raise` is on the
    // POSIX list of functions that a signal handler can call.
    if (info.si_code <= 0) {
        raise(signal);
        return;
    }

    Message message;
    const where = positionOf(&message);
    if (where.file.length != 0) {
        message.put(where.file);
        message.put("(");
        message.putNumber(where.line);
        message.put("): ");
    }
    message.put("fatal: ");
    message.put(kindOf(signal, info));
    if (where.function_.length != 0) {
        message.put(", in ");
        message.put(where.function_);
    }
    message.put("\n");
    message.flush;
}

// `onStack` is an address on the stack that faulted: the handler runs there.
private GuestPosition positionOf(in void* onStack) @system nothrow @nogc {
    for (auto run = _guestRuns; run !is null; run = run._next)
        if (run.stackBottom <= onStack && onStack < run.stackTop)
            return run.position(run.context);
    return GuestPosition.init;
}

private string kindOf(
    in int signal, imported!"core.sys.posix.signal".siginfo_t* info,
) @system nothrow @nogc {
    import core.sys.posix.signal:
        FPE_INTDIV, SEGV_MAPERR, SIGFPE;

    enum firstPage = 4096;

    if (signal == SIGFPE)
        return info.si_code == FPE_INTDIV
            ? "integer division by zero or overflow"
            : "arithmetic fault";
    return info.si_code == SEGV_MAPERR && cast(size_t) info.si_addr < firstPage
        ? "null pointer dereference"
        : "invalid memory access";
}

// A fixed buffer: a message that does not fit is cut.
private struct Message {
    private char[1024] _text = void;
    private size_t _used;

    private void put(in const(char)[] piece) @trusted nothrow @nogc {
        foreach (character; piece) {
            if (_used == _text.length)
                return;
            _text[_used++] = character;
        }
    }

    private void putNumber(in size_t number) @trusted nothrow @nogc {
        char[20] digits = void;
        size_t start = digits.length;
        size_t rest = number;
        do {
            digits[--start] = cast(char) ('0' + rest % 10);
            rest /= 10;
        } while (rest != 0);
        put(digits[start .. $]);
    }

    private void flush() @trusted nothrow @nogc {
        import core.sys.posix.unistd: write;

        size_t done;
        while (done < _used) {
            const written = write(2, _text.ptr + done, _used - done);
            if (written <= 0)
                break;
            done += written;
        }
    }
}
