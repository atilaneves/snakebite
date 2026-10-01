module snakebite.backends.haltprocess;


private:


// What compiled `-checkaction=halt` code runs for a failed check: an
// illegal instruction, so the process dies of a signal and no guest code
// or druntime hook sees the failure. No frontend import: the bytecode VM
// uses it.
public noreturn haltProcess() nothrow @nogc @trusted {
    import core.stdc.stdlib: abort;

    version (X86_64)
        asm nothrow @nogc {
            ud2;
        }
    abort;
}
