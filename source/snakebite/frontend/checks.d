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
    // Off unless `-check=nullderef` asks: no flag, not even `-unittest`,
    // turns it on.
    public CHECKENABLE nullDeref = CHECKENABLE.off;
    public CHECKACTION action = CHECKACTION.D;
    // Imported template declarations use the root compilation's versions,
    // while ordinary dependency functions keep their library's flags.
    public bool betterC;

    private enum Category {
        assertion,
        preconditions,
        postconditions,
        invariants,
        arrayBounds,
        switchError,
        nullDeref,
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

        if (argument == "-release" || argument == "--release")
            _release = true;
        else if (argument == "-betterC" || argument == "--betterC")
            betterC = true;
        else if (argument == "-noboundscheck")
            _boundscheck = CHECKENABLE.off;
        else if (argument.startsWith("--boundscheck"))
            return acceptBoundscheck(argument["--boundscheck".length .. $]);
        else if (argument.startsWith("-boundscheck"))
            return acceptBoundscheck(argument["-boundscheck".length .. $]);
        else if (isLdcCheckFlag(argument))
            return acceptLdcCheck(argument);
        else if (argument.startsWith("--checkaction="))
            return acceptAction(argument["--checkaction=".length .. $]);
        else if (argument.startsWith("-checkaction="))
            return acceptAction(argument["-checkaction=".length .. $]);
        else if (argument.startsWith("-check"))
            return acceptCheck(argument["-check".length .. $]);

        return true;
    }

    private bool acceptLdcCheck(in const(char)[] argument) @safe pure nothrow @nogc {
        import std.algorithm.searching: findSplit, startsWith;

        const option = argument[argument.startsWith("--") ? 2 : 1 .. $];
        const enabled = option.startsWith("enable-");
        const split = option[enabled ? "enable-".length : "disable-".length .. $]
            .findSplit("=");
        bool value;
        // LDC's FlagParser accepts these spellings, not arbitrary case.
        switch (split[2]) {
            case "": case "true": case "True": case "TRUE": case "1":
                value = enabled;
                break;
            case "false": case "False": case "FALSE": case "0":
                value = !enabled;
                break;
            default: return false;
        }
        const request = value ? CHECKENABLE.on : CHECKENABLE.off;
        switch (split[0]) {
            case "asserts": _requested[Category.assertion] = request; break;
            case "preconditions": _requested[Category.preconditions] = request; break;
            case "postconditions": _requested[Category.postconditions] = request; break;
            case "invariants": _requested[Category.invariants] = request; break;
            case "switch-errors": _requested[Category.switchError] = request; break;
            case "contracts":
                _requested[Category.preconditions] = request;
                _requested[Category.postconditions] = request;
                break;
            default: return false;
        }
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
            case "nullderef": _requested[Category.nullDeref] = enable; return true;
            default: return false;
        }
    }

    public void resolve() @safe pure nothrow @nogc {
        import std.traits: EnumMembers;

        if (betterC && action != CHECKACTION.halt)
            action = CHECKACTION.C;

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
            case nullDeref: return this.nullDeref;
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
            case nullDeref:
                return CHECKENABLE.off;
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
        params.useNullCheck = nullDeref;
        params.checkAction = action;
        params.betterC = betterC;
        params.useModuleInfo = !betterC;
        params.useTypeInfo = !betterC;
        params.useExceptions = !betterC;
        params.useGC = !betterC;
    }

    // The predefined version identifiers that dmd defines only when the
    // check is on (`dmd.target.addPredefinedGlobalIdentifiers`).
    public bool defines(in const(char)[] identifier) const @safe pure nothrow @nogc {
        switch (identifier) {
            case "assert": return assertion == CHECKENABLE.on;
            case "D_PreConditions": return preconditions == CHECKENABLE.on;
            case "D_PostConditions": return postconditions == CHECKENABLE.on;
            case "D_Invariants": return invariants == CHECKENABLE.on;
            case "D_BetterC": return betterC;
            case "D_ModuleInfo":
            case "D_Exceptions":
            case "D_TypeInfo": return !betterC;
            default: return true;
        }
    }

    // The predefined version identifiers that dmd defines only when the
    // check is off.
    public immutable(string)[] definitions() const @safe pure nothrow @nogc {
        static immutable noBounds = ["D_NoBoundsChecks"];
        static immutable betterCVersion = ["D_BetterC"];
        static immutable both = ["D_NoBoundsChecks", "D_BetterC"];

        if (betterC)
            return arrayBounds == CHECKENABLE.off ? both : betterCVersion;
        return arrayBounds == CHECKENABLE.off ? noBounds : null;
    }

    // DMD lets `-check=bounds` win over `-boundscheck=` in either order.
    // Resolve before translation so the guest and image use the same flags.
    // A check that no flag named keeps LDC's default. LDC has no null check.
    public string[] ldcFlags() const @safe pure nothrow {
        import std.traits: EnumMembers;

        string[] flags;
        static foreach (category; EnumMembers!Category)
            if (isNamed(category))
                flags ~= ldcFlag(category);

        return flags;
    }

    private bool isNamed(in Category category) const @safe pure nothrow @nogc {
        // LDC has no flag for it.
        if (category == Category.nullDeref)
            return false;

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
            case nullDeref:
                assert(0, "LDC has no null dereference check");
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

private bool isLdcCheckFlag(in const(char)[] argument) @safe pure nothrow @nogc {
    import std.algorithm.searching: startsWith;

    const option = argument.startsWith("--") ? argument[1 .. $] : argument;
    static foreach (name; ["asserts", "preconditions", "postconditions",
            "invariants", "switch-errors", "contracts"])
        if (option.startsWith("-enable-" ~ name)
                || option.startsWith("-disable-" ~ name))
            return true;

    return false;
}

// Normalize both compiler dialects so a later native flag cannot override
// the resolved DMD precedence in the image alone.
public string[] ldcArguments(in string[] arguments) {
    Checks checks;
    string[] kept;
    foreach (argument; joinedCheckArguments(expandedCompilerArguments(arguments))) {
        // The compiler reports a flag that is not valid.
        if (!checks.accept(argument) || !isCheckFlag(argument))
            kept ~= argument;
    }
    checks.resolve;

    return kept ~ checks.ldcFlags;
}

public bool isCheckFlag(in const(char)[] argument) @safe pure nothrow @nogc {
    import std.algorithm.searching: startsWith;

    return argument == "-noboundscheck"
        || argument.startsWith("-boundscheck")
        || argument.startsWith("--boundscheck")
        || isLdcCheckFlag(argument)
        || (argument.startsWith("-check")
            && !argument.startsWith("-checkaction="));
}

// Use the frontend's response syntax, including environment lookup and
// nested files, before any consumer resolves compiler flags.
public string[] expandedCompilerArguments(in string[] arguments) {
    import dmd.arraytypes: Strings;
    import dmd.root.response: responseExpand;
    import dmd.root.string: toDString;
    import std.algorithm: any, startsWith;
    import std.algorithm.iteration: map;
    import std.array: array;
    import std.conv: text;
    import std.string: toStringz;

    if (!arguments.any!(argument => argument.startsWith("@")))
        return arguments.dup;
    const argumentText = ["dmd"] ~ arguments;
    auto expanded = Strings(argumentText.length);
    foreach (index, argument; argumentText)
        expanded[index] = argument.toStringz;
    if (const missing = responseExpand(expanded))
        throw new Exception(text(
            "failed to expand dub compiler response file ", missing.toDString,
        ));
    return expanded[][1 .. $].map!(argument => argument.toDString.idup).array;
}

// LDC also accepts a separate value for enum options. Use one argument
// form for both the guest parser and the image translation.
public string[] joinedCheckArguments(in string[] arguments) @safe pure nothrow {
    string[] joined;
    for (size_t index; index < arguments.length; ++index) {
        const argument = arguments[index];
        const separate = argument == "-boundscheck" || argument == "--boundscheck"
            || argument == "-checkaction" || argument == "--checkaction";
        if (separate && index + 1 < arguments.length)
            joined ~= argument ~ "=" ~ arguments[++index];
        else
            joined ~= argument;
    }

    return joined;
}
