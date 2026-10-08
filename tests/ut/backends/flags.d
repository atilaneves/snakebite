module ut.backends.flags;


// Compiler flags change what a whole program means. Each test runs guest
// programs under the flags of a row and says what each program does:
// returns, raises a throwable, or halts. `parseSnippet` analyses the program
// under the flags with the function that `bin/sb` uses for the modules of a
// project, and the `Program` carries the checks that the backend reads while
// it runs. What needs a process (the signal of a real halt, the C abort, the
// exit status) is in tests/run_flags.py.


import snakebite.backends.backend: Program;
import snakebite.backends.checkplan: BoundsCheck, cMessageOf;
import snakebite.backends.haltprocess: Halted, HostActions;
import snakebite.frontend.compiler: checksOf, FrontendFlags, parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;
import std.conv: text;
import ut.backends;


private alias NoNative = Omit!(Native, Because.inexpressible,
    "the flags differ per row, and the Native arm is code compiled into "
    ~ "bin/ut with its own flags");

private alias NoCtfe = Omit!(Ctfe, Because.diverges,
    "dmd's own interpreter raises its own error, with its own message, "
    ~ "where the others return or halt; ut.backends.flags.flags.preconditions "
    ~ "states what it does");

private alias Guests = Matrix!(NoNative);
private alias Compiled = Matrix!(NoNative, NoCtfe);


// What a run of the program did. CTFE reports a throwable as a diagnostic,
// so there the type of the throwable is not comparable.
private struct Expect {
    enum How { returned, raised, halted, same }

    How how;
    string thrown;
    string message;

    static Expect returned() {
        return Expect(How.returned);
    }

    static Expect raised(in string thrown = "", in string message = "") {
        return Expect(How.raised, thrown, message);
    }

    static Expect halted() {
        return Expect(How.halted);
    }

    // CTFE reports a diagnostic with a message of its own, and no type.
    static Expect diagnosed(in string message) {
        return Expect(How.raised, "", message);
    }

    // For a row where CTFE does what the other backends do.
    static Expect same() {
        return Expect(How.same);
    }
}

private enum assertError = "core.exception.AssertError";
private enum indexError = "core.exception.ArrayIndexError";
private enum sliceError = "core.exception.ArraySliceError";
private enum rangeError = "core.exception.RangeError";
private enum switchError = "core.exception.SwitchError";
private enum nullPointerError = "core.exception.NullPointerError";
private enum failure = "Assertion failure";

private enum haltFlags = ["-checkaction=halt"];


private struct Row {
    string[] flags;
    string code;
    Expect expected;
    // CTFE has no halt and always checks bounds.
    Expect ctfe = Expect.same;
}


// What a check that is off does not do: no `assert` raises.
static foreach (backend; Compiled) {
    @("flags.assert." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        enum failing = q{ unittest { int x = 1; assert(x == 2); } };

        foreach (row; [
            Row([], failing, Expect.raised(assertError, "unittest failure")),
            Row(["-check=assert=off"], failing, Expect.returned),
        ])
            shouldRun!backend(row);
    }
}


private void shouldRun(Backend)(
    in Row row,
    in string file = __FILE__,
    in size_t line = __LINE__,
) {
    const wanted = wantedOn!Backend(row);
    const actual = ranOn!Backend(row.flags, row.code);
    const matches = actual.how == wanted.how
        && (is(Backend == Ctfe)
            || wanted.thrown.length == 0
            || actual.thrown == wanted.thrown)
        && (wanted.message.length == 0 || actual.message == wanted.message);
    if (!matches)
        throw new UnitTestException(
            text(
                "flags ", row.flags, " and ", row.code, "\nwanted ", wanted,
                "\ngot    ", actual,
            ),
            file, line,
        );
}


private Expect ranOn(Backend)(in string[] flags, in string code) {
    const frontendFlags = FrontendFlags(flags.dup);
    auto module_ = parseSnippet(
        code ~ "\nvoid __run() {\n"
            ~ "    foreach (test; __traits(getUnitTests,\n"
            ~ "            __traits(parent, __run)))\n"
            ~ "        test();\n"
            ~ "}\n",
        [], frontendFlags,
    );
    HostActions actions;
    actions.halt = &endRun;
    auto program = Program(
        [module_], "flags", checksOf(frontendFlags), actions);
    auto backend = Owned!Backend(program);

    try {
        backend.call(findFunction(module_, "__run"), null, []);
        return Expect.returned;
    } catch (Halted) {
        return Expect.halted;
    } catch (Throwable thrown) {
        return Expect.raised(typeid(thrown).name, thrown.msg);
    }
}


private Expect wantedOn(Backend)(in Row row) {
    static if (is(Backend == Ctfe))
        if (row.ctfe.how != Expect.How.same)
            return row.ctfe;

    return row.expected;
}


private noreturn endRun() {
    throw new Halted;
}


// The operands of an assert that is off are not evaluated.
static foreach (backend; Compiled) {
    @("flags.assertOperands." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        shouldRun!backend(Row(["-check=assert=off"], q{
            int fail() { assert(0, "evaluated"); return 0; }
            unittest { assert(fail() == 1); }
        }, Expect.returned));
    }
}


// `assert(0)` is not a check: with the check off it halts.
static foreach (backend; Compiled) {
    @("flags.assertZero." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        shouldRun!backend(Row(
            ["-check=assert=off"], q{ unittest { assert(0); } },
            Expect.halted));
    }
}


static foreach (backend; Guests) {
    @("flags.preconditions." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        enum program = q{
            int positive(int x) in (x > 0) { return x; }
            unittest { positive(-1); }
        };
        enum diagnosed = Expect.diagnosed("`assert(x > 0)` failed");

        foreach (row; [
            Row([], program, Expect.raised(assertError, failure), diagnosed),
            Row(["-check=in=off"], program, Expect.returned),
            Row(["-release"], program, Expect.returned),
            Row(["-check=assert=off"], program, Expect.returned, diagnosed),
            Row(["-check=in=on", "-checkaction=halt"], program,
                Expect.halted, diagnosed),
        ])
            shouldRun!backend(row);
    }
}


static foreach (backend; Guests) {
    @("flags.postconditions." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        enum program = q{
            int positive(int x) out (result; result > 0) { return x; }
            unittest { positive(-1); }
        };
        enum diagnosed = Expect.diagnosed("`assert(result > 0)` failed");

        foreach (row; [
            Row([], program, Expect.raised(assertError, failure), diagnosed),
            Row(["-check=out=off"], program, Expect.returned),
            Row(["-release"], program, Expect.returned),
            Row(["-check=out=on", "-checkaction=halt"], program,
                Expect.halted, diagnosed),
        ])
            shouldRun!backend(row);
    }
}


static foreach (backend; Guests) {
    @("flags.invariants." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        enum method = q{
            class C {
                int x = 1;
                invariant { assert(x > 0); }
                void set(int value) { x = value; }
            }
            unittest {
                auto c = new C;
                c.set(-1);
            }
        };
        enum diagnosed = Expect.diagnosed("`assert(this.x > 0)` failed");

        foreach (row; [
            Row([], method, Expect.raised(assertError, failure), diagnosed),
            Row(["-check=invariant=off"], method, Expect.returned),
            Row(["-release"], method, Expect.returned),
            Row(["-check=invariant=on", "-checkaction=halt"], method,
                Expect.halted, diagnosed),
        ])
            shouldRun!backend(row);
    }
}


// `assert(c)` on a class reference calls its invariant: that is the
// invariant check, not the assert check. Its halt form is `c || halt`, which
// never reaches the invariant call.
static foreach (backend; Guests) {
    @("flags.invariantsOnReference." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        enum onReference = q{
            class C {
                int x = 1;
                invariant { assert(x > 0); }
            }
            unittest {
                auto c = new C;
                c.x = -1;
                assert(c);
            }
        };

        foreach (row; [
            // dmd's own interpreter does not call the invariant here.
            Row([], onReference, Expect.raised(assertError, failure),
                Expect.returned),
            Row(["-check=invariant=off"], onReference, Expect.returned),
            Row(["-release"], onReference, Expect.returned),
            Row(["-checkaction=halt"], onReference, Expect.returned),
        ])
            shouldRun!backend(row);
    }
}


// No member of the enum matches, so a `final switch` has nothing to run. With
// the check off the switch halts, as dmd's `assert(0)` of a release build
// does.
static foreach (backend; Compiled) {
    @("flags.switchError." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        enum program = q{
            enum E { a, b }
            @system unittest {
                E e = cast(E) 7;
                final switch (e) { case E.a: break; case E.b: break; }
            }
        };

        foreach (row; [
            Row([], program, Expect.raised(switchError)),
            Row(["-check=switch=off"], program, Expect.halted),
            Row(["-release"], program, Expect.halted),
            Row(["-check=switch=on", "-checkaction=halt"], program,
                Expect.halted),
        ])
            shouldRun!backend(row);
    }
}


// A null dereference is only checked when the flag asks for it.
static foreach (backend; Guests) {
    @("flags.nullDerefField." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        enum program = q{
            struct S { int x; }
            @system unittest {
                S* p;
                int y = p.x;
            }
        };

        foreach (row; [
            Row(["-check=nullderef"], program,
                Expect.raised(nullPointerError), Expect.same),
            Row(["-check=nullderef=on"], program,
                Expect.raised(nullPointerError), Expect.same),
            Row(["-check=nullderef", "-checkaction=halt"], program,
                Expect.halted, Expect.raised),
        ])
            shouldRun!backend(row);
    }
}


static foreach (backend; Guests) {
    @("flags.nullDerefPointer." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        enum program = q{
            @system unittest {
                int* p;
                int y = *p;
            }
        };

        foreach (row; [
            Row(["-check=nullderef"], program,
                Expect.raised(nullPointerError), Expect.same),
            Row(["-check=nullderef=on"], program,
                Expect.raised(nullPointerError), Expect.same),
            Row(["-check=nullderef", "-checkaction=halt"], program,
                Expect.halted, Expect.raised),
        ])
            shouldRun!backend(row);
    }
}


static foreach (backend; Guests) {
    @("flags.nullDerefVirtualCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        enum program = q{
            class C { int f() { return 1; } }
            @system unittest {
                C c;
                c.f();
            }
        };

        foreach (row; [
            Row(["-check=nullderef"], program,
                Expect.raised(nullPointerError), Expect.same),
            Row(["-check=nullderef=on"], program,
                Expect.raised(nullPointerError), Expect.same),
            Row(["-check=nullderef", "-checkaction=halt"], program,
                Expect.halted, Expect.raised),
        ])
            shouldRun!backend(row);
    }
}


static foreach (backend; Guests) {
    @("flags.nullDerefDelegate." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        enum program = q{
            class C { int f() { return 1; } }
            @system unittest {
                C c;
                auto dg = &c.f;
            }
        };

        foreach (row; [
            Row(["-check=nullderef"], program,
                Expect.raised(nullPointerError), Expect.same),
            Row(["-check=nullderef=on"], program,
                Expect.raised(nullPointerError), Expect.same),
            Row(["-check=nullderef", "-checkaction=halt"], program,
                Expect.halted, Expect.raised),
        ])
            shouldRun!backend(row);
    }
}


static foreach (backend; Guests) {
    @("flags.nullDerefClassFieldRead." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        shouldRun!backend(Row(["-check=nullderef"], q{
            class C { int x; }
            @system unittest {
                C c;
                int y = c.x;
            }
        }, Expect.raised(nullPointerError), Expect.same));
    }
}


static foreach (backend; Guests) {
    @("flags.nullDerefClassFieldWrite." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        shouldRun!backend(Row(["-check=nullderef"], q{
            class C { int x; }
            @system unittest {
                C c;
                c.x = 1;
            }
        }, Expect.raised(nullPointerError), Expect.same));
    }
}


static foreach (backend; Guests) {
    @("flags.nullDerefDelegateCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        shouldRun!backend(Row(["-check=nullderef"], q{
            @system unittest {
                int delegate() dg;
                dg();
            }
        }, Expect.raised(nullPointerError), Expect.same));
    }
}


static foreach (backend; Guests) {
    @("flags.nullDerefFunctionPointerCall." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        shouldRun!backend(Row(["-check=nullderef"], q{
            @system unittest {
                int function() fp;
                fp();
            }
        }, Expect.raised(nullPointerError), Expect.same));
    }
}


// Native code reads the vtable of the receiver after it evaluates the
// arguments, and the check is at that read.
static foreach (backend; Guests) {
    @("flags.nullDerefVirtualCallArguments." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        shouldRun!backend(Row(["-check=nullderef"], q{
            class C { int f(int a) { return a; } }
            int evaluated;
            int argument() { evaluated = 1; return 1; }
            @system unittest {
                C c;
                try c.f(argument());
                catch (Error) {}
                assert(evaluated == 1);
            }
        }, Expect.returned, Expect.diagnosed(
            "function call through null class reference `null`")));
    }
}


// The context action puts the operands of the failed comparison in the
// message.
static foreach (backend; Guests) {
    @("flags.checkactionContext." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        shouldRun!backend(Row(["-checkaction=context"], q{
            unittest { int x = 1; assert(x == 2); }
        }, Expect.raised(assertError, "1 != 2")));
    }
}

// A comparison of two literals reaches the backend as `assert(false)` with
// the operands in the message.
static foreach (backend; Guests) {
    @("flags.checkactionContextLiteralOperands." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        shouldRun!backend(Row(["-checkaction=context"], q{
            unittest { assert(1 == 2); }
        }, Expect.raised(assertError, "1 != 2")));
    }
}


private enum indexBody = q{
    int[4] storage = [1, 2, 3, 4];
    int[] slice = storage[0 .. 2];
    auto value = slice[3];
};

private enum sliceBody = q{
    int[4] storage = [1, 2, 3, 4];
    int[] slice = storage[0 .. 2];
    auto value = slice[0 .. 3];
};

private enum copyBody = q{
    int[4] target;
    int[4] source = [1, 2, 3, 4];
    int[] to = target[0 .. 3];
    int[] from = source[0 .. 2];
    to[] = from[];
};


static foreach (backend; Compiled) {
    @("flags.boundsIndex." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        foreach (row; boundsRows(indexBody, indexError))
            shouldRun!backend(row);
    }
}


// What the bounds check does, by the check that the flags end up with and by
// the safety of the function that holds the access: on checks all, safeonly
// checks `@safe` code only, off checks none. Reading past a slice but inside
// its storage is well defined, so the unchecked rows read the storage.
private Row[] boundsRows(in string body_, in string thrown) {
    Row[] rows;
    foreach (attribute; ["@safe", "@trusted", "@system"]) {
        const code = unittestOf(attribute, body_);
        const checked = Expect.raised(thrown);
        rows ~= Row(["-check=bounds=on"], code, checked);
        rows ~= Row(
            ["-boundscheck=safeonly"], code,
            attribute == "@safe" ? checked : Expect.returned,
        );
        rows ~= Row(["-check=bounds=off"], code, Expect.returned);
    }

    return rows;
}


private string unittestOf(in string attribute, in string body_) {
    return text(attribute, " unittest {\n", body_, "\n}");
}


// The slice is a bounds check that dmd's glue layer emits separately from
// the index.
static foreach (backend; Compiled) {
    @("flags.boundsSlice." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        foreach (row; boundsRows(sliceBody, sliceError))
            shouldRun!backend(row);
    }
}


// So is the slice copy.
static foreach (backend; Compiled) {
    @("flags.boundsSliceCopy." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        foreach (row; boundsRows(copyBody, rangeError))
            shouldRun!backend(row);
    }
}


// The bounds check does not depend on the assert check.
static foreach (backend; Compiled) {
    @("flags.boundsWithAssertOff." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        shouldRun!backend(Row(
            ["-check=assert=off"], unittestOf("@safe", indexBody),
            Expect.raised(indexError)));
    }
}


// `-release` is bounds checks for `@safe` code only.
static foreach (backend; Compiled) {
    @("flags.release.bounds." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        foreach (row; [
            Row(["-release"], unittestOf("@safe", indexBody),
                Expect.raised(indexError)),
            Row(["-release"], unittestOf("@system", indexBody),
                Expect.returned),
            Row(["-release"], unittestOf("@safe", sliceBody),
                Expect.raised(sliceError)),
            Row(["-release"], unittestOf("@system", sliceBody),
                Expect.returned),
            Row(["-release"], unittestOf("@safe", copyBody),
                Expect.raised(rangeError)),
            Row(["-release"], unittestOf("@system", copyBody),
                Expect.returned),
        ])
            shouldRun!backend(row);
    }
}


// A pointer has no length to check an upper bound against, and its slice is
// never `@safe`; the order of its bounds is checked as any bounds are.
static foreach (backend; Compiled) {
    @("flags.boundsPointerSlice." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        string pointerSlice(in string attribute, in int lower, in int upper) {
            return unittestOf(attribute, text(
                "int[4] storage = [1, 2, 3, 4];\n",
                "int* pointer = storage.ptr;\n",
                "size_t lower = ", lower, ";\n",
                "size_t upper = ", upper, ";\n",
                "auto value = pointer[lower .. upper];\n",
            ));
        }

        foreach (attribute; ["@trusted", "@system"]) {
            foreach (flags; [
                ["-check=bounds=on"], ["-check=bounds=off"],
                ["-boundscheck=safeonly"],
            ])
                shouldRun!backend(Row(
                    flags, pointerSlice(attribute, 1, 3), Expect.returned));

            shouldRun!backend(Row(
                ["-check=bounds=on"], pointerSlice(attribute, 2, 1),
                Expect.raised(sliceError)));
            foreach (flags; [["-check=bounds=off"], ["-boundscheck=safeonly"]])
                shouldRun!backend(Row(
                    flags, pointerSlice(attribute, 2, 1), Expect.returned));
        }
    }
}


// A failed bounds check and a failed copy are each a halt under
// `-checkaction=halt`. CTFE has no halt: it reports an error.
static foreach (backend; Compiled) {
    @("flags.checkactionHalt." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        foreach (row; [
            Row(haltFlags, unittestOf("@system", indexBody), Expect.halted),
            Row(haltFlags, unittestOf("@system", sliceBody), Expect.halted),
            Row(haltFlags, unittestOf("@system", copyBody), Expect.halted),
            // A slice copy onto an overlapping slice is a bounds failure, as
            // a length mismatch is.
            Row(haltFlags, unittestOf("@system", q{
                int[4] storage = [1, 2, 3, 4];
                int[] lower = storage[0 .. 3];
                int[] upper = storage[1 .. 4];
                lower[] = upper[];
            }), Expect.halted),
            Row(["-check=bounds=off", "-checkaction=halt"],
                unittestOf("@system", indexBody), Expect.returned),
        ])
            shouldRun!backend(row);
    }
}


// A static array target has a length that the source must match, however the
// copy is written.
static foreach (backend; Compiled) {
    @("flags.checkactionHaltStaticCopy." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        enum staticCopy = q{
            int[4] target;
            int[] from = [1, 2, 3];
        };

        foreach (statement; [
            "target[] = from[];", "target = from;", "int[4] copy = from;",
        ]) {
            const body_ = staticCopy ~ statement;
            shouldRun!backend(Row(
                [], unittestOf("@system", body_), Expect.raised(rangeError)));
            shouldRun!backend(Row(
                haltFlags, unittestOf("@system", body_), Expect.halted));
        }
    }
}


// dmd defines `D_NoBoundsChecks` when the bounds check is off for all code.
static foreach (backend; Guests) {
    @("flags.versions.bounds." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        enum definedWhenOff = q{
            unittest {
                version (D_NoBoundsChecks) {} else
                    assert(0, "D_NoBoundsChecks is not defined");
            }
        };
        enum undefinedWhenNotOff = q{
            unittest {
                version (D_NoBoundsChecks)
                    assert(0, "D_NoBoundsChecks is defined");
            }
        };

        foreach (row; [
            Row(["-check=bounds=off"], definedWhenOff, Expect.returned),
            Row([], undefinedWhenNotOff, Expect.returned),
            Row(["-boundscheck=safeonly"], undefinedWhenNotOff,
                Expect.returned),
        ])
            shouldRun!backend(row);
    }
}


// dmd defines the contract identifiers only for the contracts that are on.
static foreach (backend; Guests) {
    @("flags.versions.contracts." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        enum contracts = q{
            unittest {
                version (D_PreConditions) {} else
                    assert(0, "D_PreConditions is not defined");
                version (D_PostConditions) {} else
                    assert(0, "D_PostConditions is not defined");
                version (D_Invariants) {} else
                    assert(0, "D_Invariants is not defined");
                version (assert) {} else assert(0, "assert is not defined");
            }
        };
        enum noContracts = q{
            unittest {
                version (D_PreConditions)
                    assert(0, "D_PreConditions is defined");
                version (D_PostConditions)
                    assert(0, "D_PostConditions is defined");
                version (D_Invariants) assert(0, "D_Invariants is defined");
                version (assert) {} else assert(0, "assert is not defined");
            }
        };
        enum onlyPostconditions = q{
            unittest {
                version (D_PreConditions)
                    assert(0, "D_PreConditions is defined");
                version (D_PostConditions) {} else
                    assert(0, "D_PostConditions is not defined");
                version (D_Invariants) {} else
                    assert(0, "D_Invariants is not defined");
            }
        };

        foreach (row; [
            Row([], contracts, Expect.returned),
            Row(["-release"], noContracts, Expect.returned),
            Row(["-check=in=off"], onlyPostconditions, Expect.returned),
        ])
            shouldRun!backend(row);
    }
}


// A response file is expanded as dmd expands it, and the flags in it apply
// to the program like flags on the command line. An absolute path does not
// depend on the working directory of the process, which a test must not
// change.
static foreach (backend; Guests) {
    @("flags.responseFile." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        enum precondition = q{
            int positive(int x) in (x > 0) { return x; }
            unittest { positive(-1); }
        };
        enum unchecked = q{
            unittest {
                version (D_NoBoundsChecks) {} else
                    assert(0, "D_NoBoundsChecks is not defined");
            }
        };
        enum checked = q{
            unittest {
                version (D_NoBoundsChecks)
                    assert(0, "D_NoBoundsChecks is defined");
            }
        };

        const sandbox = Sandbox();
        sandbox.writeFile("checks.rsp", "# check selection\n-check=in=off\n");
        sandbox.writeFile("unchecked.rsp", "\"-noboundscheck\"\n");
        sandbox.writeFile(
            "checked.rsp", "-check=bounds=on\n-noboundscheck\n");
        sandbox.writeFile(
            "outer.rsp", "@" ~ sandbox.inSandboxPath("checks.rsp") ~ "\n");

        foreach (row; [
            Row(["@" ~ sandbox.inSandboxPath("checks.rsp")], precondition,
                Expect.returned),
            Row(["@" ~ sandbox.inSandboxPath("outer.rsp")], precondition,
                Expect.returned),
            Row(["@" ~ sandbox.inSandboxPath("unchecked.rsp")], unchecked,
                Expect.returned),
            // A flag that names the check beats `-noboundscheck`, whatever
            // their order.
            Row(["@" ~ sandbox.inSandboxPath("checked.rsp")], checked,
                Expect.returned),
        ])
            shouldRun!backend(row);
    }
}


// The text that `-checkaction=C` gives the C runtime for each bounds check.
// The abort that prints it ends the process, so tests/run_flags.py reaches
// only the text of the index.
@("flags.cMessagesOfBoundsChecks")
unittest {
    cMessageOf(BoundsCheck.index).should == "array index out of bounds";
    cMessageOf(BoundsCheck.slice).should == "array slice out of bounds";
    cMessageOf(BoundsCheck.sliceCopy).should == "array overflow";
}


// `-betterC` sets no lowering on a `~`, and dmd's glue never emits it. A
// `case` in an `if (__ctfe)` block makes that block a jump target at run
// time, so a backend still compiles the `~` in it.
static foreach (backend; Guests) {
    @("flags.betterC.catInCtfeBlockWithCase." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        shouldRun!backend(Row(["-betterC"], q{
            int f(int x, string a, string b) {
                switch (x) {
                    if (__ctfe) {
                        case 1:
                            auto s = a ~ b;
                            return cast(int) s.length;
                    }
                    default:
                        return 0;
                }
            }
            unittest { assert(f(0, "a", "b") == 0); }
        }, Expect.returned));
    }
}
