module ut.frontend.checks;


// The compiler flags that select run-time checks resolve the way dmd
// resolves them: a flag that names a check beats a default, and the last
// of two flags for the same check wins.


import dmd.astenums: CHECKACTION, CHECKENABLE;
import snakebite.frontend.checks: Checks, ldcArguments;
import snakebite.frontend.compiler: checksOf, FrontendFlags, parseSnippet;
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


// The program is refused before it runs anything, as dmd refuses the flag.
@("checks.invalid.isAnError")
unittest {
    foreach (flag; ["-check=bogus", "-boundscheck=bogus", "-checkaction=bogus"]) {
        checksOf(FrontendFlags([flag])).shouldThrowWithMessage(
            "switch `" ~ flag ~ "` is invalid");
        parseSnippet("", null, FrontendFlags([flag])).shouldThrowWithMessage(
            "switch `" ~ flag ~ "` is invalid");
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


@("checks.betterC")
unittest {
    foreach (flag; ["-betterC", "--betterC"]) {
        const checks = resolved([flag]);
        checks.betterC.should == true;
        checks.action.should == CHECKACTION.C;
        checks.definitions.should == ["D_BetterC"];
        checks.defines("D_BetterC").should == true;
        foreach (identifier; ["D_ModuleInfo", "D_TypeInfo", "D_Exceptions"])
            checks.defines(identifier).should == false;
        resolved([flag, "-checkaction=D"]).action.should == CHECKACTION.C;
        resolved([flag, "-checkaction=halt"]).action.should == CHECKACTION.halt;
        resolved([flag, "-boundscheck=off"]).definitions
            .should == ["D_NoBoundsChecks", "D_BetterC"];
    }
    resolved([]).betterC.should == false;
    resolved([]).defines("D_BetterC").should == false;
}


@("checks.betterC.parseState")
unittest {
    foreach (betterC; [false, true, false, true]) {
        const source = betterC ? q{
            version (D_BetterC) {} else static assert(false);
            version (D_ModuleInfo) static assert(false);
            version (D_TypeInfo) static assert(false);
            version (D_Exceptions) static assert(false);
        } : q{
            version (D_BetterC) static assert(false);
            version (D_ModuleInfo) {} else static assert(false);
            version (D_TypeInfo) {} else static assert(false);
            version (D_Exceptions) {} else static assert(false);
        };
        parseSnippet(source, null, FrontendFlags(betterC ? ["-betterC"] : null));
    }
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


@("checks.ldc.nativePreconditions")
unittest {
    with (CHECKENABLE)
        resolved(["--enable-preconditions=false"]).preconditions.should == off;
}


@("checks.ldc.nativeChecks")
unittest {
    with (CHECKENABLE) {
        const checks = resolved([
            "--enable-asserts=false",
            "--enable-preconditions=false",
            "--enable-postconditions=false",
            "--enable-invariants=false",
            "--enable-switch-errors=false",
            "--boundscheck=safeonly",
        ]);
        checks.assertion.should == off;
        checks.preconditions.should == off;
        checks.postconditions.should == off;
        checks.invariants.should == off;
        checks.switchError.should == off;
        checks.arrayBounds.should == safeonly;
    }
}


@("checks.ldc.booleanForms")
unittest {
    foreach (dash; ["-", "--"])
        foreach (name; ["asserts", "preconditions", "postconditions",
                "invariants", "switch-errors", "contracts"]) {
            foreach (value; ["", "=", "=true", "=True", "=TRUE", "=1"]) {
                ldcArguments([dash ~ "enable-" ~ name ~ value]).should ==
                    (name == "contracts"
                        ? ["--enable-preconditions=true", "--enable-postconditions=true"]
                        : ["--enable-" ~ name ~ "=true"]);
                ldcArguments([dash ~ "disable-" ~ name ~ value]).should ==
                    (name == "contracts"
                        ? ["--enable-preconditions=false", "--enable-postconditions=false"]
                        : ["--enable-" ~ name ~ "=false"]);
            }
            foreach (value; ["=false", "=False", "=FALSE", "=0"]) {
                ldcArguments([dash ~ "enable-" ~ name ~ value]).should ==
                    (name == "contracts"
                        ? ["--enable-preconditions=false", "--enable-postconditions=false"]
                        : ["--enable-" ~ name ~ "=false"]);
                ldcArguments([dash ~ "disable-" ~ name ~ value]).should ==
                    (name == "contracts"
                        ? ["--enable-preconditions=true", "--enable-postconditions=true"]
                        : ["--enable-" ~ name ~ "=true"]);
            }
            foreach (value; ["=yes", "=TrUe", "=FaLsE", "=2"]) {
                Checks checks;
                checks.accept(dash ~ "enable-" ~ name ~ value).should == false;
                ldcArguments([dash ~ "enable-" ~ name ~ value])
                    .should == [dash ~ "enable-" ~ name ~ value];
            }
        }
}


@("checks.ldc.contractPrecedence")
unittest {
    with (CHECKENABLE) {
        resolved(["--disable-contracts", "-enable-preconditions"])
            .preconditions.should == on;
        resolved(["-enable-preconditions", "--disable-contracts"])
            .preconditions.should == off;
        resolved(["--disable-contracts", "-enable-preconditions"])
            .postconditions.should == off;
        resolved(["--release", "-enable-preconditions"])
            .preconditions.should == on;
        resolved(["--release"]).postconditions.should == off;
        resolved(["--checkaction=halt"]).action.should == CHECKACTION.halt;
    }
}


@("checks.ldc.nativeBoundsPrecedence")
unittest {
    with (CHECKENABLE) {
        resolved(["--boundscheck=off", "-check=bounds=on"])
            .arrayBounds.should == on;
        resolved(["-check=bounds=on", "--boundscheck=off"])
            .arrayBounds.should == on;
    }
}


@("checks.ldc.normalizesNativeFlags")
unittest {
    ldcArguments([
        "--enable-preconditions=false",
        "--enable-preconditions=true",
    ]).should == ["--enable-preconditions=true"];
    ldcArguments(["--boundscheck=off", "-check=bounds=on"])
        .should == ["--boundscheck=on"];
    ldcArguments(["-check=bounds=on", "--boundscheck=off"])
        .should == ["--boundscheck=on"];
}


@("checks.ldc.boundscheckForms")
unittest {
    ldcArguments(["-boundscheck=safeonly"]).should == ["--boundscheck=safeonly"];
    ldcArguments(["-noboundscheck"]).should == ["--boundscheck=off"];
    ldcArguments(["-g", "-boundscheck=off"]).should == ["-g", "--boundscheck=off"];
}


@("checks.ldc.separateBoundsValue")
unittest {
    ldcArguments(["--boundscheck", "off"])
        .should == ["--boundscheck=off"];
    ldcArguments(["-boundscheck", "safeonly", "--boundscheck=on"])
        .should == ["--boundscheck=on"];
    ldcArguments(["--boundscheck", "off", "-check=bounds=on"])
        .should == ["--boundscheck=on"];
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
