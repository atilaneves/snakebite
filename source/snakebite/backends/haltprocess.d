module snakebite.backends.haltprocess;


private:


// What a program does when a check fails under `-checkaction=halt`. The
// process that owns the program decides: `bin/sb` runs the guest as the
// process, so a halt ends it; a REPL session runs many cells in one
// process, so a halt ends only the cell. No frontend import: the bytecode
// VM uses it.
public alias HaltAction = noreturn function();

// What compiled `-checkaction=halt` code runs for a failed check: an
// illegal instruction, so the process dies of a signal and no guest code
// or druntime hook sees the failure.
public noreturn haltProcess() nothrow @nogc @trusted {
    version (X86_64)
        asm nothrow @nogc {
            ud2;
        }
    else
        static assert(false, "haltProcess has no trapping instruction for this target");

    // `ud2` does not return, but the compiler cannot know that of an
    // `asm` block.
    assert(0);
}

// What a program does when a check fails under `-checkaction=halt`. The
// process that owns the program decides, so the program carries the action
// and no backend keeps a global one.
public struct HostActions {
    public HaltAction halt = &haltProcess;
}

// What an action that ends only a cell throws. A halt is not an error
// that guest code handles, so it is neither an `Exception` nor an `Error`:
// druntime code that handles every `Exception` (`rt_finalize2` makes a
// `FinalizeError` of one) lets it pass. Each backend checks `isHalt` before
// it runs any guest code on the way up: no `catch`, `finally`,
// `scope(exit)` or destructor sees it. Native code that handles every
// `Throwable` is the one thing that still can: that is a limit of using an
// exception to leave native frames, which the host cannot unwind in any
// other way.
public class Halted: Throwable {
    public this(
        string file = __FILE__,
        size_t line = __LINE__,
    ) @safe @nogc nothrow pure scope {
        this("a check failed under -checkaction=halt", file, line);
    }

    protected this(
        string message,
        string file,
        size_t line,
    ) @safe @nogc nothrow pure scope {
        super(message, file, line);
    }
}

public bool isHalt(in Throwable throwable) @safe @nogc nothrow pure {
    return cast(const(Halted)) throwable !is null;
}
