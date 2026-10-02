module snakebite.frontend.checks;


private:


import dmd.astenums: CHECKACTION, CHECKENABLE;
import dmd.globals: Param;


// The run-time checks that the compiler flags `-release`, `-check=`,
// `-boundscheck=`, `-noboundscheck` and `-checkaction=` select, resolved
// the way `dmd -unittest <flags>` resolves them (`mars.d` parses the flags,
// the block in `main.d` that follows option parsing fills in the defaults).
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

    private enum Category {
        assertion,
        preconditions,
        postconditions,
        invariants,
        arrayBounds,
        switchError,
    }

    private bool _release;
    // `-boundscheck=` only supplies the default of the bounds check: a
    // `-check=bounds` flag wins over it wherever it comes.
    private CHECKENABLE _boundscheck = CHECKENABLE._default;
    private CHECKENABLE[Category.max + 1] _requested = CHECKENABLE._default;

    // Whether `argument` is a valid value of a flag that this reads, or
    // not one of its flags at all.
    public bool accept(in const(char)[] argument) @safe pure nothrow @nogc {
        import std.algorithm.searching: startsWith;

        if (argument == "-release")
            _release = true;
        else if (argument == "-noboundscheck")
            _boundscheck = CHECKENABLE.off;
        else if (argument.startsWith("-boundscheck"))
            return acceptBoundscheck(argument["-boundscheck".length .. $]);
        else if (argument.startsWith("-checkaction="))
            return acceptAction(argument["-checkaction=".length .. $]);
        else if (argument.startsWith("-check"))
            return acceptCheck(argument["-check".length .. $]);

        return true;
    }

    private bool acceptBoundscheck(in const(char)[] value) @safe pure nothrow @nogc {
        switch (value) {
            case "=on": _boundscheck = CHECKENABLE.on; return true;
            case "=safeonly": _boundscheck = CHECKENABLE.safeonly; return true;
            case "=off": _boundscheck = CHECKENABLE.off; return true;
            default: return false;
        }
    }

    private bool acceptAction(in const(char)[] name) @safe pure nothrow @nogc {
        switch (name) {
            case "D": action = CHECKACTION.D; return true;
            case "C": action = CHECKACTION.C; return true;
            case "halt": action = CHECKACTION.halt; return true;
            case "context": action = CHECKACTION.context; return true;
            default: return false;
        }
    }

    // `value` is what follows `-check`: `=on`, `=off`, `=<name>` or
    // `=<name>=on|off`.
    private bool acceptCheck(in const(char)[] value) @safe pure nothrow @nogc {
        import std.algorithm.searching: findSplit;

        if (value.length == 0 || value[0] != '=')
            return false;

        const request = value[1 .. $];
        if (request == "on" || request == "off") {
            _requested[] = request == "on" ? CHECKENABLE.on : CHECKENABLE.off;
            return true;
        }

        const split = request.findSplit("=");
        const state = split[1].length == 0 ? "on" : split[2];
        if (state != "on" && state != "off")
            return false;
        const enable = state == "on" ? CHECKENABLE.on : CHECKENABLE.off;

        switch (split[0]) {
            case "assert": _requested[Category.assertion] = enable; return true;
            case "bounds": _requested[Category.arrayBounds] = enable; return true;
            case "in": _requested[Category.preconditions] = enable; return true;
            case "invariant": _requested[Category.invariants] = enable; return true;
            case "out": _requested[Category.postconditions] = enable; return true;
            case "switch": _requested[Category.switchError] = enable; return true;
            // dmd accepts it; neither backend has a separate null check.
            case "nullderef": return true;
            default: return false;
        }
    }

    public void resolve() @safe pure nothrow @nogc {
        import std.traits: EnumMembers;

        static foreach (category; EnumMembers!Category)
            fieldOf(category) = _requested[category] == CHECKENABLE._default
                ? defaultOf(category)
                : _requested[category];
    }

    private ref CHECKENABLE fieldOf(in Category category) return @safe pure nothrow @nogc {
        final switch (category) with (Category) {
            case assertion: return this.assertion;
            case preconditions: return this.preconditions;
            case postconditions: return this.postconditions;
            case invariants: return this.invariants;
            case arrayBounds: return this.arrayBounds;
            case switchError: return this.switchError;
        }
    }

    // What `main.d` gives a check that no flag named: `-unittest` turns
    // `assert` on first, then `-release` turns the others off.
    private CHECKENABLE defaultOf(in Category category) const @safe pure nothrow @nogc {
        final switch (category) with (Category) {
            case assertion:
                return CHECKENABLE.on;
            case arrayBounds:
                if (_boundscheck != CHECKENABLE._default)
                    return _boundscheck;
                return _release ? CHECKENABLE.safeonly : CHECKENABLE.on;
            case preconditions:
            case postconditions:
            case invariants:
            case switchError:
                return _release ? CHECKENABLE.off : CHECKENABLE.on;
        }
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

    // The predefined version identifiers that dmd defines only when the
    // check is off.
    public immutable(string)[] definitions() const @safe pure nothrow @nogc {
        static immutable noBounds = ["D_NoBoundsChecks"];

        return arrayBounds == CHECKENABLE.off ? noBounds : null;
    }

    // The `ldc2` flags for the checks that a flag named: `ldc2` reads none
    // of the flags that `accept` reads, and it keeps the last of two flags
    // for one check where dmd lets `-check=bounds` win over
    // `-boundscheck=`, so these come from the resolved checks. A check that
    // no flag named keeps the default of `ldc2`. `ldc2` has no null check.
    public string[] ldcFlags() const @safe pure nothrow {
        import std.traits: EnumMembers;

        string[] flags;
        static foreach (category; EnumMembers!Category)
            if (isNamed(category))
                flags ~= ldcFlag(category);

        return flags;
    }

    private bool isNamed(in Category category) const @safe pure nothrow @nogc {
        return _requested[category] != CHECKENABLE._default
            || (category == Category.arrayBounds
                && _boundscheck != CHECKENABLE._default);
    }

    private string ldcFlag(in Category category) const @safe pure nothrow {
        final switch (category) with (Category) {
            case assertion:
                return "--enable-asserts=" ~ ldcBool(this.assertion);
            case preconditions:
                return "--enable-preconditions=" ~ ldcBool(this.preconditions);
            case postconditions:
                return "--enable-postconditions=" ~ ldcBool(this.postconditions);
            case invariants:
                return "--enable-invariants=" ~ ldcBool(this.invariants);
            case switchError:
                return "--enable-switch-errors=" ~ ldcBool(this.switchError);
            case arrayBounds:
                return "--boundscheck=" ~ ldcBounds;
        }
    }

    private static string ldcBool(in CHECKENABLE enable) @safe pure nothrow @nogc {
        return enable == CHECKENABLE.on ? "true" : "false";
    }

    private string ldcBounds() const @safe pure nothrow @nogc {
        final switch (arrayBounds) with (CHECKENABLE) {
            case on: return "on";
            case safeonly: return "safeonly";
            case off: return "off";
            case _default: assert(0, "bounds check was not resolved");
        }
    }
}

// `arguments` for `ldc2`: the flags that `Checks` reads and `ldc2` does not
// understand give way to the `ldc2` flags of the checks they select.
public string[] ldcArguments(in string[] arguments) @safe pure nothrow {
    import std.algorithm.searching: startsWith;

    Checks checks;
    string[] kept;
    foreach (argument; arguments) {
        const isCheckFlag = argument == "-noboundscheck"
            || argument.startsWith("-boundscheck")
            || (argument.startsWith("-check")
                && !argument.startsWith("-checkaction="));
        // The compiler reports a flag that is not valid.
        if (!checks.accept(argument) || !isCheckFlag)
            kept ~= argument;
    }
    checks.resolve;

    return kept ~ checks.ldcFlags;
}
