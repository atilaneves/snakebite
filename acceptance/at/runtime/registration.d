module at.runtime.registration;


import core.memory: GC;
import ut.backends;
import snakebite.backends.backend: Program, run;
import snakebite.backends.guestmodules: GuestModules;
import snakebite.ffi.callback: callbackEntriesInUse;
import snakebite.frontend.compiler: parseSnippet;


// How many of `runs` runs of `code` leave nothing registered with druntime,
// no registry image and no callback entry that the calling thread took. A D
// thread that starts while a program runs keeps the registration of that
// program until the thread ends, so the count is exact only in a process in
// which no other test starts a thread: the serial run of `bin/at`.
private size_t runsThatGiveBack(Backend)(
    in string code,
    in int status,
    in size_t runs,
) {
    // Starts the marking threads of the collector before the measured runs.
    // A run during which a thread that is not a D thread starts keeps its
    // registration, which is a known defect of the product. Without this
    // line the test fails at random for that reason, not for the behaviour
    // that it tests.
    GC.collect;

    size_t givenBack;
    foreach (_; 0 .. runs) {
        const held = GuestModules.held;
        const entries = callbackEntriesInUse;
        auto program = Program([parseSnippet(code)]);
        auto instance = Owned!Backend(program);
        run(instance, program).should == status;
        if (GuestModules.held == held && callbackEntriesInUse == entries)
            ++givenBack;
    }

    return givenBack;
}


// A process that runs many programs must not grow with each program that
// has module constructors and destructors: when it ended, with no thread left
// alive, what its registration took is given back. So does a program whose
// startup failed, which is not run.
static foreach (backend; Matrix!(
    Omit!(Native, Because.inexpressible,
        "the Native arm runs no guest program in the test process, so no registration exists"),
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot run module destructors"),
)) {
    @("registrationOfEndedProgramIsGivenBack." ~ backend.stringof)
    @Tags(backend.stringof, "alone")
    unittest {
        enum runs = 20;
        runsThatGiveBack!backend(q{
            shared static this() {}
            shared static ~this() {}
            void main() {}
        }, 0, runs).should == runs;
    }

    @("registrationOfProgramThatFailedToStartIsGivenBack." ~ backend.stringof)
    @Tags(backend.stringof, "alone")
    unittest {
        enum runs = 20;
        runsThatGiveBack!backend(q{
            shared static this() { throw new Exception("ctor failed"); }
            shared static ~this() {}
            void main() {}
        }, 1, runs).should == runs;
    }
}
