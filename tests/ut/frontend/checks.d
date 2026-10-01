module ut.frontend.checks;


// The compiler flags that select run-time checks resolve the way dmd
// resolves them: a flag that names a check beats a default, and the last
// of two flags for the same check wins.


import dmd.astenums: CHECKACTION, CHECKENABLE;
import snakebite.frontend.checks: Checks;
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
