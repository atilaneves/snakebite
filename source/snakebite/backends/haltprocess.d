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

// What a halt action that ends only a cell throws. A guest `catch` or
// `finally` does not see it: a halt is not an error that guest code
// handles.
public final class Halted: Exception {
    public this(
        string file = __FILE__,
        size_t line = __LINE__,
    ) @safe @nogc nothrow pure scope {
        super("a check failed under -checkaction=halt", file, line);
    }
}
