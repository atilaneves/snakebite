module ut.backends.guestfault;


import snakebite.backends.backend: Program;
import snakebite.backends.guestfault: GuestFault, GuestFaultException;
import snakebite.backends.haltprocess: Halted, HostActions, isHalt;
import snakebite.frontend.checks: Checks;
import snakebite.frontend.compiler: parseSnippets;
import std.algorithm.iteration: map;
import std.array: appender, array;
import std.traits: EnumMembers;
import ut;


private string rendered(
    in GuestFault.Kind kind,
    in string file,
    in size_t line,
    in GuestFault.Frame[] frames,
) {
    auto text = appender!string;
    GuestFault.render(kind, file, line,
        (scope sink) { foreach (frame; frames) sink(frame); },
        (in piece) { text ~= piece; });
    return text[];
}


@("guestFault.message.eachKindHasItsOwn")
unittest {
    GuestFault.message(GuestFault.Kind.nullDereference)
        .should == "null pointer dereference";
    GuestFault.message(GuestFault.Kind.invalidAccess)
        .should == "invalid memory access";
    GuestFault.message(GuestFault.Kind.nullCall)
        .should == "call of a null function pointer";
    GuestFault.message(GuestFault.Kind.divisionByZero)
        .should == "integer division by zero";
    GuestFault.message(GuestFault.Kind.divisionOverflow)
        .should == "integer overflow in division";
    GuestFault.message(GuestFault.Kind.throwNull)
        .should == "throw of a null reference";
    GuestFault.message(GuestFault.Kind.stackOverflow)
        .should == "stack overflow";

    EnumMembers!(GuestFault.Kind).length.should == 7;
}


@("guestFault.render.headlineThenOneLineForEachFrame")
unittest {
    rendered(GuestFault.Kind.nullDereference, "app.d", 2, [
        GuestFault.Frame("app.C.~this", "app.d", 2),
        GuestFault.Frame("D main", "app.d", 4),
    ]).should ==
        "app.d(2): fatal: null pointer dereference\n"
        ~ "    in app.C.~this (app.d(2))\n"
        ~ "    in D main (app.d(4))\n";
}


@("guestFault.render.noFramesIsOnlyTheHeadline")
unittest {
    rendered(GuestFault.Kind.divisionByZero, "app.d", 17, [])
        .should == "app.d(17): fatal: integer division by zero\n";
}


@("guestFault.render.largeLineNumber")
unittest {
    rendered(GuestFault.Kind.invalidAccess, "a.d", 18_446_744_073_709_551_615UL, [])
        .should == "a.d(18446744073709551615): fatal: invalid memory access\n";
}


@("guestFault.throwFault.throwsAHaltThatCarriesTheFault")
unittest {
    GuestFaultException caught;
    try
        GuestFault.throwFault(
            GuestFault.Kind.divisionOverflow, "app.d", 9,
            (scope sink) {
                sink(GuestFault.Frame("f", "app.d", 8));
                sink(GuestFault.Frame("D main", "app.d", 12));
            });
    catch (GuestFaultException fault)
        caught = fault;

    caught.shouldNotBeNull;
    caught.kind.should == GuestFault.Kind.divisionOverflow;
    caught.file.should == "app.d";
    caught.line.should == 9;
    caught.msg.should == "app.d(9): fatal: integer overflow in division";
    caught.stack.map!(frame => frame.function_).array
        .should == ["f", "D main"];
    isHalt(caught).shouldBeTrue;
}


@("guestFault.throwFault.copiesTheFramesTheStackLends")
unittest {
    char[] name = "volatile".dup;
    GuestFaultException caught;
    try
        GuestFault.throwFault(GuestFault.Kind.nullDereference, "app.d", 1,
            (scope sink) { sink(GuestFault.Frame(name, "app.d", 1)); });
    catch (GuestFaultException fault)
        caught = fault;

    name[] = 'x';
    caught.stack[0].function_.should == "volatile";
}


@("guestFault.exception.isAHaltAndNeitherExceptionNorError")
unittest {
    const Throwable fault = new GuestFaultException(
        GuestFault.Kind.nullCall, "app.d", 3, []);

    isHalt(fault).shouldBeTrue;
    (cast(Halted) fault).shouldNotBeNull;
    (cast(Exception) fault).shouldBeNull;
    (cast(Error) fault).shouldBeNull;
}


@("guestFault.halted.theHaltOfACheckIsNotAFault")
unittest {
    const Throwable halted = new Halted;

    isHalt(halted).shouldBeTrue;
    (cast(GuestFaultException) halted).shouldBeNull;
}


@("program.fault.runsTheActionOfTheHostThatMadeTheProgram")
unittest {
    static string seen;
    static noreturn action(
        in GuestFault.Kind kind, in const(char)[] file, in size_t line,
        scope GuestFault.Stack stack,
    ) {
        seen = GuestFault.message(kind) ~ "@" ~ file ~ ":" ~ cast(char)('0' + line);
        throw new Halted;
    }

    auto module_ = parseSnippets(["module programFaultAction;"])[0];
    const program = Program(
        [module_], "", Checks(), HostActions(&action));

    program.fault(GuestFault.Kind.nullCall, "x.d", 5, (scope sink) {})
        .shouldThrow!Halted;
    seen.should == "call of a null function pointer@x.d:5";
}


@("program.fault.defaultActionThrowsToTheCaller")
unittest {
    auto module_ = parseSnippets(["module programFaultDefault;"])[0];
    const program = Program([module_]);

    try
        program.fault(GuestFault.Kind.divisionByZero, "x.d", 5, (scope sink) {});
    catch (GuestFaultException fault) {
        fault.kind.should == GuestFault.Kind.divisionByZero;
        return;
    }
    assert(0, "the default action does not throw");
}
