module ut.dub;


import snakebite.dub: parseDescribeLists;
import ut;


// dub prints each kind's lines joined by newlines, the kinds joined by one
// blank line, then a final newline. An empty kind is nothing between two
// blank lines and must keep its place among the others.
@("parseDescribeLists.keepsEmptyKindsInPlace")
unittest {
    const output =
        "a.d\nb.d" ~ "\n\n" ~ "-checkaction=context" ~ "\n\n" ~ "" ~ "\n\n"
        ~ "Have_x" ~ "\n";

    parseDescribeLists(output, 4).should == [
        ["a.d", "b.d"],
        ["-checkaction=context"],
        [],
        ["Have_x"],
    ];
}


// Nothing follows the last blank line when the last kind is empty.
@("parseDescribeLists.trailingEmptyKinds")
unittest {
    parseDescribeLists("a.d\n\n\n", 2).should == [["a.d"], []];
    parseDescribeLists("a.d\n\n\n\n\n", 3).should == [["a.d"], [], []];
}


@("parseDescribeLists.wrongNumberOfListsThrows")
unittest {
    parseDescribeLists("a.d\n", 2).shouldThrowWithMessage(
        "dub describe printed 1 lists, expected 2:\na.d\n",
    );
    parseDescribeLists("a.d\n\n\n\n\n", 2).shouldThrowWithMessage(
        "dub describe printed 3 lists, expected 2:\na.d\n\n\n\n\n",
    );
}


@("parseDescribeLists.missingFinalNewlineThrows")
unittest {
    parseDescribeLists("a.d\n\nb.d", 2).shouldThrowWithMessage(
        "dub describe output does not end in a newline:\na.d\n\nb.d",
    );
}
