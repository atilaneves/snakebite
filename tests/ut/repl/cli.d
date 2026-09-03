module ut.repl.cli;


import ut;
import snakebite.backends: BackendName;
import snakebite.repl.cli: parseReplArgs;


@("backend.defaultsToInterpreter")
unittest {
    const result = parseReplArgs(["sb"]);

    result.status.should == 0;
    result.options.backend.should == BackendName.interpreter;
}


@("backend.selectsBytecode")
unittest {
    const result = parseReplArgs(["sb", "-b", "bytecode"]);

    result.status.should == 0;
    result.options.backend.should == BackendName.bytecode;
}


@("backend.selectsCtfeByLongFlag")
unittest {
    const result = parseReplArgs(["sb", "--backend", "ctfe"]);

    result.status.should == 0;
    result.options.backend.should == BackendName.ctfe;
}


@("backend.unknownNameFails")
unittest {
    const result = parseReplArgs(["sb", "-b", "nope"]);

    result.status.should == 1;
    (result.diagnostic.length > 0).should == true;
}


@("command.setsHasCommandAndText")
unittest {
    const result = parseReplArgs(["sb", "-c", "1 + 2"]);

    result.status.should == 0;
    result.options.hasCommand.should == true;
    result.options.command.should == "1 + 2";
}


@("noCommand.leavesHasCommandFalse")
unittest {
    const result = parseReplArgs(["sb"]);

    result.options.hasCommand.should == false;
}


@("importPaths.repeatableFlagAccumulatesInOrder")
unittest {
    const result = parseReplArgs(["sb", "-I", "first", "-I", "second"]);

    result.status.should == 0;
    result.options.importPaths.should == ["first", "second"];
}


@("live.flagSetsLiveAfterFiles")
unittest {
    const result = parseReplArgs(["sb", "-l", "loaded.d"]);

    result.status.should == 0;
    result.options.liveAfterFiles.should == true;
}


@("live.defaultsToFalse")
unittest {
    const result = parseReplArgs(["sb", "loaded.d"]);

    result.options.liveAfterFiles.should == false;
}


@("files.capturedInOrder")
unittest {
    const result = parseReplArgs(["sb", "first.d", "second.d"]);

    result.status.should == 0;
    result.options.files.should == ["first.d", "second.d"];
}


@("files.emptyWhenNoneGiven")
unittest {
    const result = parseReplArgs(["sb"]);

    result.options.files.should == [];
}


@("help.setsShowHelpAndDiagnostic")
unittest {
    const result = parseReplArgs(["sb", "--help"]);

    result.status.should == 0;
    result.options.showHelp.should == true;
    (result.diagnostic.length > 0).should == true;
}
