module ut.repl.cell;


import ut;
import snakebite.repl.cell:
    isExpressionCell,
    isIncompleteDeclaration,
    isStandalonePragmaMessageStatement,
    replCellLineDirective;


@("isExpressionCell.arithmetic")
unittest {
    isExpressionCell("1 + 2").should == true;
}


@("isExpressionCell.functionCall")
unittest {
    isExpressionCell("answer()").should == true;
}


@("isExpressionCell.rejectsLocalDeclaration")
unittest {
    // `int x = 1;` parses as a `DeclarationExp`, not a plain expression:
    // the REPL sends it down the module-declaration path instead.
    isExpressionCell("int x = 1;").should == false;
}


@("isExpressionCell.rejectsUnittestBlock")
unittest {
    isExpressionCell(`unittest { assert(true); }`).should == false;
}


@("isExpressionCell.rejectsFunctionDeclaration")
unittest {
    isExpressionCell("int answer() { return 42; }").should == false;
}


@("isIncompleteDeclaration.unclosedBrace")
unittest {
    isIncompleteDeclaration("int answer() {").should == true;
}


@("isIncompleteDeclaration.wholeFunctionIsComplete")
unittest {
    isIncompleteDeclaration("int answer() { return 42; }").should == false;
}


@("isIncompleteDeclaration.unittestBlockIsComplete")
unittest {
    isIncompleteDeclaration(`unittest { assert(true); }`).should == false;
}


@("isStandalonePragmaMessageStatement.matchesPragmaMsg")
unittest {
    isStandalonePragmaMessageStatement(`pragma(msg, "hello");`).should == true;
}


@("isStandalonePragmaMessageStatement.rejectsExpression")
unittest {
    isStandalonePragmaMessageStatement("42").should == false;
}


@("isStandalonePragmaMessageStatement.rejectsFunctionDeclaration")
unittest {
    isStandalonePragmaMessageStatement("int answer() { return 42; }")
        .should == false;
}


@("replCellLineDirective.numbersTheCell")
unittest {
    replCellLineDirective(1).should == "#line 1 \"<repl cell 1>\"\n";
    replCellLineDirective(2).should == "#line 1 \"<repl cell 2>\"\n";
}
