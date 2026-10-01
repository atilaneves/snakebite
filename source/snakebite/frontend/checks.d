module snakebite.frontend.checks;


private:


import dmd.astenums: CHECKACTION, CHECKENABLE;
import dmd.globals: Param;


// The run-time checks that the compiler flags `-release` and
// `-checkaction=` select, resolved the way `dmd -unittest <flags>`
// resolves them (the block in dmd's `main.d` that follows option parsing).
// Every snakebite run is a unittest run, and `dmd -unittest` keeps `assert`
// on under `-release`.
//
// The frontend reads these while it analyses (contracts, `final switch`,
// `version (assert)`) and the backends read them while they run
// (assertions, bounds checks), after the frontend has put its own flags
// back; `Program.checks` carries them from one to the other.
public struct Checks {
    public CHECKENABLE assertion = CHECKENABLE.on;
    public CHECKENABLE preconditions = CHECKENABLE.on;
    public CHECKENABLE postconditions = CHECKENABLE.on;
    public CHECKENABLE invariants = CHECKENABLE.on;
    public CHECKENABLE arrayBounds = CHECKENABLE.on;
    public CHECKENABLE switchError = CHECKENABLE.on;
    public CHECKACTION action = CHECKACTION.D;

    private bool _release;

    public void accept(in const(char)[] argument) @safe pure nothrow @nogc {
        import std.algorithm.searching: startsWith;

        if (argument == "-release")
            _release = true;
        else if (argument.startsWith("-checkaction="))
            acceptAction(argument["-checkaction=".length .. $]);
    }

    private void acceptAction(in const(char)[] name) @safe pure nothrow @nogc {
        switch (name) {
            case "D": action = CHECKACTION.D; break;
            case "C": action = CHECKACTION.C; break;
            case "halt": action = CHECKACTION.halt; break;
            case "context": action = CHECKACTION.context; break;
            default: break;
        }
    }

    public void resolve() @safe pure nothrow @nogc {
        if (!_release)
            return;

        preconditions = CHECKENABLE.off;
        postconditions = CHECKENABLE.off;
        invariants = CHECKENABLE.off;
        arrayBounds = CHECKENABLE.safeonly;
        switchError = CHECKENABLE.off;
    }

    public void applyTo(ref Param params) const @safe pure nothrow @nogc {
        params.useAssert = assertion;
        params.useIn = preconditions;
        params.useOut = postconditions;
        params.useInvariants = invariants;
        params.useArrayBounds = arrayBounds;
        params.useSwitchError = switchError;
        params.checkAction = action;
    }

    // The predefined version identifiers that dmd defines only when the
    // check is on (`dmd.target.addPredefinedGlobalIdentifiers`).
    public bool defines(in const(char)[] identifier) const @safe pure nothrow @nogc {
        switch (identifier) {
            case "assert": return assertion == CHECKENABLE.on;
            case "D_PreConditions": return preconditions == CHECKENABLE.on;
            case "D_PostConditions": return postconditions == CHECKENABLE.on;
            case "D_Invariants": return invariants == CHECKENABLE.on;
            default: return true;
        }
    }
}
