module snakebite.backends.guestfault;


private:


import snakebite.backends.haltprocess: Halted;


// Guest code that compiled D would kill with a signal: a null dereference,
// an invalid memory access, an integer division that the hardware traps. A
// backend does not decide what happens next. It calls the fault action of
// its `Program`, which the host that made the program chose:
//
//  - `bin/sb` runs the guest as the process: `endProcess` prints the message
//    and the guest call stack and ends the process, as compiled D dies.
//  - A session (the REPL, an in-process test) runs many calls in one
//    process: `throwFault`, the default, ends the one call with a
//    `GuestFaultException`.
//
// A fault is a halt: the exception is a `Halted`, so no guest `catch`,
// `finally`, `scope` guard or destructor sees it on the way up, and druntime
// code that handles every `Exception` lets it pass.
public struct GuestFault {
    // One kind for each fact that the hardware gives: it does not know the
    // D type of the access, so the kinds do not either.
    public enum Kind {
        nullDereference,
        invalidAccess,
        nullCall,
        divisionByZero,
        divisionOverflow,
        throwNull,
        stackOverflow,
    }

    public static string message(in Kind kind) @safe @nogc nothrow pure {
        final switch (kind) with (Kind) {
            case nullDereference:
                return "null pointer dereference";
            case invalidAccess:
                return "invalid memory access";
            case nullCall:
                return "call of a null function pointer";
            case divisionByZero:
                return "integer division by zero";
            case divisionOverflow:
                return "integer overflow in division";
            case throwNull:
                return "throw of a null reference";
            case stackOverflow:
                return "stack overflow";
        }
    }

    // One guest function that was running at the fault, innermost first.
    // `line` is where the function is declared: that is enough to name a
    // `unittest` block, which has no name of its own.
    public struct Frame {
        public const(char)[] function_;
        public const(char)[] file;
        public size_t line;
    }

    // What an action gets and what it makes of it: the frames are visited
    // when the action asks, so that a backend keeps no call record while the
    // guest runs, and an action that only prints allocates nothing. A fault
    // can be in a destructor that the garbage collector runs, where an
    // allocation is an error.
    public alias FrameSink = void delegate(in Frame);
    public alias Stack = void delegate(scope FrameSink);
    public alias Action = noreturn function(
        in Kind kind, in const(char)[] file, in size_t line, scope Stack stack,
    );

    public static noreturn throwFault(
        in Kind kind, in const(char)[] file, in size_t line, scope Stack stack,
    ) {
        const(Frame)[] frames;
        stack((in frame) {
            frames ~= Frame(
                frame.function_.idup, frame.file.idup, frame.line);
        });
        throw new GuestFaultException(kind, file.idup, line, frames);
    }

    public alias Sink = void delegate(in const(char)[]);

    // The text of a fault, as pieces for `sink`: the message and then one
    // line for each frame. It allocates nothing.
    public static void render(
        in Kind kind, in const(char)[] file, in size_t line,
        scope Stack stack, scope Sink sink,
    ) {
        renderHeadline(kind, file, line, sink);
        sink("\n");
        stack((in frame) {
            sink("    in ");
            sink(frame.function_);
            sink(" (");
            renderPosition(frame.file, frame.line, sink);
            sink(")\n");
        });
    }

    public static void renderHeadline(
        in Kind kind, in const(char)[] file, in size_t line, scope Sink sink,
    ) {
        renderPosition(file, line, sink);
        sink(": fatal: ");
        sink(message(kind));
    }

    // The message and the stack on standard error, as `bin/sb` prints them
    // and the REPL does for a fault that no cell joins. It runs after a
    // fault that can have interrupted native code that holds a lock, so it
    // uses neither the garbage collector nor `stdio`: the text is formatted
    // into a fixed buffer and written with `write`.
    public static void print(
        in Kind kind, in const(char)[] file, in size_t line, scope Stack stack,
    ) @trusted {
        import core.stdc.stdio: fflush;

        // The output of the guest comes before the message.
        fflush(null);
        StandardError buffer;
        render(kind, file, line, stack, &buffer.put);
        buffer.flush;
    }

    // The action of a process that runs only the guest: compiled D dies of
    // the signal with no guest cleanup, and so does this.
    public static noreturn endProcess(
        in Kind kind, in const(char)[] file, in size_t line, scope Stack stack,
    ) {
        import core.stdc.stdlib: _Exit;

        print(kind, file, line, stack);
        _Exit(1);
    }
}

private void renderPosition(
    in const(char)[] file, in size_t line, scope GuestFault.Sink sink,
) {
    char[20] digits = void;
    size_t start = digits.length;
    ulong rest = line;
    do {
        digits[--start] = cast(char) ('0' + rest % 10);
        rest /= 10;
    } while (rest != 0);

    sink(file);
    sink("(");
    sink(digits[start .. $]);
    sink(")");
}

private struct StandardError {
    private char[4096] _text = void;
    private size_t _used;

    public void put(in const(char)[] piece) @trusted {
        foreach (character; piece) {
            if (_used == _text.length)
                flush;
            _text[_used++] = character;
        }
    }

    public void flush() @trusted {
        import core.sys.posix.unistd: write;

        size_t done;
        while (done < _used) {
            const written = write(2, _text.ptr + done, _used - done);
            if (written <= 0)
                break;
            done += written;
        }
        _used = 0;
    }
}


public final class GuestFaultException: Halted {
    public const GuestFault.Kind kind;
    public const(GuestFault.Frame)[] stack;

    public this(
        in GuestFault.Kind kind,
        string file,
        in size_t line,
        const(GuestFault.Frame)[] stack,
    ) {
        import std.array: appender;

        auto text = appender!string;
        GuestFault.renderHeadline(kind, file, line, (in piece) {
            text ~= piece;
        });
        super(text[], file, line);
        this.kind = kind;
        this.stack = stack;
    }
}
