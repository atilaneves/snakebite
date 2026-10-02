module ut.frontend.checks;


// The compiler flags that select run-time checks resolve the way dmd
// resolves them: a flag that names a check beats a default, and the last
// of two flags for the same check wins.


import dmd.astenums: CHECKACTION, CHECKENABLE;
import snakebite.frontend.checks: Checks, ldcArguments;
import ut;


private Checks resolved(in string[] flags) {
    Checks checks;
    foreach (flag; flags)
        checks.accept(flag).should == true;
    checks.resolve;

    return checks;
}


@("checks.bounds")
unittest {
    with (CHECKENABLE) {
        resolved([]).arrayBounds.should == on;
        resolved(["-release"]).arrayBounds.should == safeonly;
        resolved(["-boundscheck=off"]).arrayBounds.should == off;
        resolved(["-noboundscheck"]).arrayBounds.should == off;
        resolved(["-boundscheck=safeonly"]).arrayBounds.should == safeonly;
        resolved(["-release", "-boundscheck=on"]).arrayBounds.should == on;
        resolved(["-check=bounds=on", "-boundscheck=off"]).arrayBounds.should == on;
        resolved(["-boundscheck=off", "-check=bounds"]).arrayBounds.should == on;
        resolved(["-check=off", "-boundscheck=on"]).arrayBounds.should == off;
        resolved(["-check=off", "-release"]).arrayBounds.should == off;
        resolved(["-check=bounds=off", "-check=on"]).arrayBounds.should == on;
    }
}


@("checks.release")
unittest {
    with (CHECKENABLE) {
        const checks = resolved(["-release"]);
        checks.assertion.should == on;
        checks.preconditions.should == off;
        checks.postconditions.should == off;
        checks.invariants.should == off;
        checks.switchError.should == off;
    }
}


@("checks.each")
unittest {
    with (CHECKENABLE) {
        resolved(["-check=assert=off"]).assertion.should == off;
        resolved(["-check=in=off"]).preconditions.should == off;
        resolved(["-check=out=off"]).postconditions.should == off;
        resolved(["-check=invariant=off"]).invariants.should == off;
        resolved(["-check=switch=off"]).switchError.should == off;
        resolved(["-release", "-check=in"]).preconditions.should == on;
        resolved(["-release", "-check=in"]).postconditions.should == off;
        resolved(["-check=off", "-check=switch"]).switchError.should == on;
        resolved(["-check=off", "-check=switch"]).invariants.should == off;
    }
}


@("checks.action")
unittest {
    resolved(["-checkaction=halt"]).action.should == CHECKACTION.halt;
    resolved(["-checkaction=C", "-check=off"]).action.should == CHECKACTION.C;
}


@("checks.invalid")
unittest {
    foreach (flag; [
        "-check", "-check=", "-check=bogus", "-check=bounds=maybe",
        "-check=bounds=", "-check=bounds=ON", "-check=assertx",
        "-checkaction", "-checkaction=bogus", "-boundscheck",
        "-boundscheck=", "-boundscheck=bogus", "-boundscheckon",
    ]) {
        Checks checks;
        checks.accept(flag).should == false;
    }
}


@("checks.otherFlags")
unittest {
    Checks checks;
    foreach (flag; ["-unittest", "-g", "-version=check"])
        checks.accept(flag).should == true;
}


@("checks.nullderef.accepted")
unittest {
    foreach (flag; ["-check=nullderef", "-check=nullderef=off"]) {
        Checks checks;
        checks.accept(flag).should == true;
    }
    Checks checks;
    checks.accept("-check=nullderef=x").should == false;
}


@("checks.noBoundsChecksDefinition")
unittest {
    resolved(["-check=bounds=off"]).definitions.should == ["D_NoBoundsChecks"];
    resolved(["-boundscheck=off"]).definitions.should == ["D_NoBoundsChecks"];
    resolved(["-noboundscheck"]).definitions.should == ["D_NoBoundsChecks"];
    resolved(["-boundscheck=off", "-check=bounds=on"]).definitions.length.should == 0;
    resolved([]).definitions.length.should == 0;
    resolved(["-release"]).definitions.length.should == 0;
}


@("checks.ldc.noFlagChangesNothing")
unittest {
    ldcArguments(null).length.should == 0;
    ldcArguments(["-g", "-release", "-checkaction=C", "-version=x"])
        .should == ["-g", "-release", "-checkaction=C", "-version=x"];
}


@("checks.ldc.eachCheck")
unittest {
    ldcArguments(["-check=assert=off"]).should == ["--enable-asserts=false"];
    ldcArguments(["-check=in"]).should == ["--enable-preconditions=true"];
    ldcArguments(["-check=out=off"]).should == ["--enable-postconditions=false"];
    ldcArguments(["-check=invariant=off"]).should == ["--enable-invariants=false"];
    ldcArguments(["-check=switch=off"]).should == ["--enable-switch-errors=false"];
    ldcArguments(["-check=bounds=on"]).should == ["--boundscheck=on"];
    ldcArguments(["-check=nullderef"]).length.should == 0;
}


@("checks.ldc.boundscheckForms")
unittest {
    ldcArguments(["-boundscheck=safeonly"]).should == ["--boundscheck=safeonly"];
    ldcArguments(["-noboundscheck"]).should == ["--boundscheck=off"];
    ldcArguments(["-g", "-boundscheck=off"]).should == ["-g", "--boundscheck=off"];
}


@("checks.ldc.checkBoundsWinsOverBoundscheck")
unittest {
    ldcArguments(["-check=bounds=on", "-boundscheck=off"])
        .should == ["--boundscheck=on"];
    ldcArguments(["-boundscheck=off", "-check=bounds=on"])
        .should == ["--boundscheck=on"];
}


@("checks.ldc.allChecks")
unittest {
    ldcArguments(["-check=off"]).should == [
        "--enable-asserts=false", "--enable-preconditions=false",
        "--enable-postconditions=false", "--enable-invariants=false",
        "--boundscheck=off", "--enable-switch-errors=false",
    ];
}
