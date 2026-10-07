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

// Where the guest code that runs on a thread is at a moment, as the backend
// that runs it knows. `function_` is empty when the backend cannot tell.
public struct GuestPosition {
    public const(char)[] function_;
    public const(char)[] file;
    public size_t line;
}

// What a backend registers while it runs guest code on this thread. The
// handler calls `position` from inside the signal handler, so it must read
// state that already exists and nothing else.
public struct GuestRun {
    public alias Position = GuestPosition function(void* context)
        nothrow @nogc;

    public void* context;
    public Position position;
}

public GuestRun guestRun;


private shared static this() @trusted nothrow @nogc {
    import core.sys.posix.signal:
        sigaction, sigaction_t, sigemptyset, SA_SIGINFO, SIGFPE, SIGSEGV;

    sigaction_t action;
    action.sa_sigaction = &onFault;
    action.sa_flags = SA_SIGINFO;
    sigemptyset(&action.sa_mask);
    sigaction(SIGSEGV, &action, null);
    sigaction(SIGFPE, &action, null);
}

private extern (C) void onFault(
    int signal, imported!"core.sys.posix.signal".siginfo_t* info, void*,
) @system nothrow @nogc {
    import core.sys.posix.signal:
        sigaction, sigaction_t, sigemptyset, SIG_DFL, SIGFPE;

    sigaction_t action;
    action.sa_handler = SIG_DFL;
    sigemptyset(&action.sa_mask);
    sigaction(signal, &action, null);

    Message message;
    if (guestRun.position !is null) {
        const where = guestRun.position(guestRun.context);
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
    } else {
        message.put("fatal: ");
        message.put(kindOf(signal, info));
    }
    message.put("\n");
    message.flush;
}

private string kindOf(
    in int signal, imported!"core.sys.posix.signal".siginfo_t* info,
) @system nothrow @nogc {
    import core.sys.posix.signal: SIGFPE;

    enum firstPage = 4096;
    enum integerDivide = 1; // FPE_INTDIV

    if (signal == SIGFPE)
        return info.si_code == integerDivide
            ? "integer division by zero or overflow"
            : "arithmetic fault";
    return cast(size_t) info.si_addr < firstPage
        ? "null pointer dereference"
        : "invalid memory access";
}

// A fixed buffer: a message that does not fit is cut.
private struct Message {
    private char[1024] _text = void;
    private size_t _used;

    void put(in const(char)[] piece) @trusted nothrow @nogc {
        foreach (character; piece) {
            if (_used == _text.length)
                return;
            _text[_used++] = character;
        }
    }

    void putNumber(in size_t number) @trusted nothrow @nogc {
        char[20] digits = void;
        size_t start = digits.length;
        size_t rest = number;
        do {
            digits[--start] = cast(char) ('0' + rest % 10);
            rest /= 10;
        } while (rest != 0);
        put(digits[start .. $]);
    }

    void flush() @trusted nothrow @nogc {
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
