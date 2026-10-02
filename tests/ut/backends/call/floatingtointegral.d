module ut.backends.call.floatingtointegral;


import ut.backends;


// `cast(I) floating` for a value that `I` cannot hold. D leaves it
// undefined, and compiled D gives what the x86 instructions give: a value
// out of range makes a 32-bit or 64-bit conversion give the smallest signed
// integer of its width (so NaN and infinity do too). `byte`, `short`, `int`
// and their unsigned types convert through a 32-bit register and keep the low
// bits; `uint` converts through a 64-bit one; `ulong` converts a value below
// 2^63 as a signed integer and a larger one after subtracting 2^63. A `real`
// converts to a type of 4 bytes or less through `double`. The value comes
// from a call so dmd cannot fold it. dmd's own CTFE gives another value
// for some of these: pinned per case by the `.Ctfe.diverges` test.
private alias DiffersInCtfe = Omit!(Ctfe, Because.diverges,
    "CTFE gives another value for a cast out of range: pinned by the " ~
    "`.Ctfe.diverges` test of the same case");

private struct CastCase {
    enum Outcome { agrees, differs }

    string source;
    string dest;
    string name;
    string value;
    string expected;
    Outcome ctfe;
    string ctfeValue;
}

private enum agrees = CastCase.Outcome.agrees;
private enum differs = CastCase.Outcome.differs;

private enum castCases = [
    CastCase("double", "int", "inRangeNegative", "-1.5", "-1", agrees),
    CastCase("double", "int", "aboveMax", "3e9", "int.min", agrees),
    CastCase("float", "int", "aboveMax", "3e9", "int.min", agrees),
    CastCase("double", "int", "belowMin", "-3e9", "int.min", agrees),
    CastCase("double", "int", "nan", "double.nan", "int.min", agrees),
    CastCase("double", "int", "infinity", "double.infinity", "int.min",
        agrees),
    CastCase("float", "int", "roundsUpToTwoToThe31", "2147483647.9",
        "int.min", differs, "2147483647"),
    CastCase("double", "uint", "aboveMax", "5e9", "705032704", agrees),
    CastCase("double", "uint", "negative", "-1.5", "4294967295", agrees),
    CastCase("double", "uint", "belowMin", "-3e9", "1294967296", agrees),
    CastCase("double", "uint", "nan", "double.nan", "0", agrees),
    CastCase("double", "uint", "hugeValue", "1e30", "0", agrees),
    CastCase("double", "long", "aboveMax", "1e19", "long.min", agrees),
    CastCase("double", "long", "belowMin", "-1e19", "long.min", agrees),
    CastCase("double", "long", "nan", "double.nan", "long.min", agrees),
    CastCase("real", "long", "aboveMax", "1e19L", "long.min", agrees),
    CastCase("double", "ulong", "aboveMax", "1.9e19", "0", agrees),
    CastCase("double", "ulong", "largeInRange", "1.8e19",
        "18000000000000000000", agrees),
    CastCase("real", "ulong", "largeInRange", "1.8e19L",
        "18000000000000000000", agrees),
    CastCase("double", "ulong", "negative", "-1.5", "ulong.max", agrees),
    CastCase("double", "ulong", "belowMin", "-1e30", "9223372036854775808",
        agrees),
    CastCase("double", "ulong", "nan", "double.nan", "0", agrees),
    CastCase("double", "ulong", "infinity", "double.infinity", "0", agrees),
    CastCase("double", "short", "wrapsThroughInt", "70000.0", "4464",
        agrees),
    CastCase("double", "short", "aboveIntMax", "3e9", "0", differs, "24064"),
    CastCase("double", "byte", "wrapsThroughInt", "300.5", "44", agrees),
    CastCase("double", "ubyte", "negative", "-1.5", "255", agrees),
    CastCase("double", "ubyte", "nan", "double.nan", "0", agrees),
    CastCase("double", "ushort", "negative", "-1.5", "65535", agrees),
    CastCase("double", "char", "wrapsThroughInt", "300.5", "44", agrees),
    CastCase("real", "int", "roundsToDoubleFirst", "0x1.fffffffffffffffep+0L",
        "2", agrees),
    CastCase("real", "int", "roundsUpToTwoToThe31",
        "2147483647.99999999999L", "int.min", agrees),
];

private string testName(in CastCase row) {
    return "cast.floatingToIntegral." ~ row.source ~ "." ~ row.dest ~ "."
        ~ row.name;
}

private string castCode(in CastCase row) {
    return row.source ~ " value() { return " ~ row.value ~ "; }\n"
        ~ row.dest ~ " converted() { return cast(" ~ row.dest
        ~ ") value(); }\n";
}

private template CtfeOmissions(CastCase.Outcome ctfe) {
    static if (ctfe == agrees)
        alias CtfeOmissions = AliasSeq!();
    else
        alias CtfeOmissions = AliasSeq!(DiffersInCtfe);
}

static foreach (row; castCases) {
    static foreach (backend; Matrix!(CtfeOmissions!(row.ctfe))) {
        @(row.testName ~ "." ~ backend.stringof)
        @Tags(backend.stringof)
        unittest {
            mixin(row.dest, "(", row.expected, ")").shouldBeRetOf!(
                backend, row.castCode, "converted");
        }
    }
}

// CTFE runs the cases it omits above and gives these values instead.
static foreach (row; castCases) {
    static if (row.ctfe == differs) {
        @(row.testName ~ ".Ctfe.diverges")
        @Tags("Ctfe")
        unittest {
            mixin(row.dest, "(", row.ctfeValue, ")").shouldBeRetOf!(
                Ctfe, row.castCode, "converted");
        }
    }
}
