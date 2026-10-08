module ut.backends.call.shifts;


import ut.backends;


// A shift count at or above the operand's width has no answer in the
// language, so compiled D gives whatever the CPU does: x86-64 takes the
// count modulo 32 for every operand that promotes to `int` and modulo 64
// for `long`. `byte` and `short` promote, so for them the width that
// matters is 32, not the operand's own. The count comes from a call so
// dmd cannot fold or reject it. CTFE has no such run-time rule: it
// rejects the count, gives another value (pinned per case), or asserts.
private alias RejectedByCtfe = Omit!(Ctfe, Because.inexpressible,
    "CTFE rejects an out-of-range shift count at compile time");
private alias AssertsInCtfe = Omit!(Ctfe, Because.inexpressible,
    "dmd's CTFE asserts on a negative `>>=` or `>>>=` count");
private alias DiffersInCtfe = Omit!(Ctfe, Because.diverges,
    "CTFE gives another value for an out-of-range count, where the CPU " ~
    "masks it: pinned by the `.Ctfe.diverges` test of the same case");

// One shift of the operand `type` by `count`, a value of `countType`. The
// operand is -100 when signed and the type's maximum when unsigned, so every
// bit of the result tells which count the shift used. `expected` is what
// compiled D gives.
private struct ShiftCase {
    enum Form { expr, assign, assignLiteral }

    // What CTFE does with the case. `differs` carries the value it gives.
    enum Outcome { agrees, rejects, asserts, differs }

    string type;
    string op;
    Form form;
    string name;
    string countType;
    string count;
    string expected;
    Outcome ctfe;
    string ctfeValue;
}

private enum expr = ShiftCase.Form.expr;
private enum assign = ShiftCase.Form.assign;
private enum assignLiteral = ShiftCase.Form.assignLiteral;
private enum agrees = ShiftCase.Outcome.agrees;
private enum rejects = ShiftCase.Outcome.rejects;
private enum asserts = ShiftCase.Outcome.asserts;
private enum differs = ShiftCase.Outcome.differs;

// int and long check a masked count of zero at both execution widths.
// Every type checks counts above the width and negative counts; narrow
// types also check counts at their own width before integer promotion.
private enum shiftCases = [
    ShiftCase("int", "<<", expr, "countEqualsWidth",
        "int", "32", "-100", rejects),
    ShiftCase("int", ">>", expr, "countEqualsWidth",
        "int", "32", "-100", rejects),
    ShiftCase("int", ">>>", expr, "countEqualsWidth",
        "int", "32", "-100", rejects),
    ShiftCase("int", "<<", assign, "countEqualsWidth",
        "int", "32", "-100", differs, "0"),
    ShiftCase("int", ">>", assign, "countEqualsWidth",
        "int", "32", "-100", agrees),
    ShiftCase("int", ">>>", assign, "countEqualsWidth",
        "int", "32", "-100", differs, "0"),
    ShiftCase("int", "<<", expr, "countAboveWidth",
        "int", "33", "-200", rejects),
    ShiftCase("int", ">>", expr, "countAboveWidth",
        "int", "33", "-50", rejects),
    ShiftCase("int", ">>>", expr, "countAboveWidth",
        "int", "33", "2147483598", rejects),
    ShiftCase("int", "<<", assign, "countAboveWidth",
        "int", "33", "-200", differs, "0"),
    ShiftCase("int", ">>", assign, "countAboveWidth",
        "int", "33", "-50", agrees),
    ShiftCase("int", ">>>", assign, "countAboveWidth",
        "int", "33", "2147483598", differs, "0"),
    ShiftCase("int", "<<", expr, "countNegative",
        "int", "-1", "0", rejects),
    ShiftCase("int", ">>", expr, "countNegative",
        "int", "-1", "-1", rejects),
    ShiftCase("int", ">>>", expr, "countNegative",
        "int", "-1", "1", rejects),
    ShiftCase("int", "<<", assign, "countNegative",
        "int", "-1", "0", agrees),
    ShiftCase("int", ">>", assign, "countNegative",
        "int", "-1", "-1", asserts),
    ShiftCase("int", ">>>", assign, "countNegative",
        "int", "-1", "1", asserts),
    ShiftCase("uint", "<<", expr, "countAboveWidth",
        "int", "33", "4294967294", rejects),
    ShiftCase("uint", ">>", expr, "countAboveWidth",
        "int", "33", "2147483647", rejects),
    ShiftCase("uint", ">>>", expr, "countAboveWidth",
        "int", "33", "2147483647", rejects),
    ShiftCase("uint", "<<", assign, "countAboveWidth",
        "int", "33", "4294967294", differs, "0"),
    ShiftCase("uint", ">>", assign, "countAboveWidth",
        "int", "33", "2147483647", agrees),
    ShiftCase("uint", ">>>", assign, "countAboveWidth",
        "int", "33", "2147483647", differs, "0"),
    ShiftCase("uint", "<<", expr, "countNegative",
        "int", "-1", "2147483648", rejects),
    ShiftCase("uint", ">>", expr, "countNegative",
        "int", "-1", "1", rejects),
    ShiftCase("uint", ">>>", expr, "countNegative",
        "int", "-1", "1", rejects),
    ShiftCase("uint", "<<", assign, "countNegative",
        "int", "-1", "2147483648", differs, "0"),
    ShiftCase("uint", ">>", assign, "countNegative",
        "int", "-1", "1", asserts),
    ShiftCase("uint", ">>>", assign, "countNegative",
        "int", "-1", "1", asserts),
    ShiftCase("long", "<<", expr, "countEqualsWidth",
        "int", "64", "-100", rejects),
    ShiftCase("long", ">>", expr, "countEqualsWidth",
        "int", "64", "-100", rejects),
    ShiftCase("long", ">>>", expr, "countEqualsWidth",
        "int", "64", "-100", rejects),
    ShiftCase("long", "<<", assign, "countEqualsWidth",
        "int", "64", "-100", agrees),
    ShiftCase("long", ">>", assign, "countEqualsWidth",
        "int", "64", "-100", agrees),
    ShiftCase("long", ">>>", assign, "countEqualsWidth",
        "int", "64", "-100", agrees),
    ShiftCase("long", "<<", expr, "countAboveWidth",
        "int", "65", "-200", rejects),
    ShiftCase("long", ">>", expr, "countAboveWidth",
        "int", "65", "-50", rejects),
    ShiftCase("long", ">>>", expr, "countAboveWidth",
        "int", "65", "9223372036854775758", rejects),
    ShiftCase("long", "<<", assign, "countAboveWidth",
        "int", "65", "-200", agrees),
    ShiftCase("long", ">>", assign, "countAboveWidth",
        "int", "65", "-50", agrees),
    ShiftCase("long", ">>>", assign, "countAboveWidth",
        "int", "65", "9223372036854775758", agrees),
    ShiftCase("long", "<<", expr, "countNegative",
        "int", "-1", "0", rejects),
    ShiftCase("long", ">>", expr, "countNegative",
        "int", "-1", "-1", rejects),
    ShiftCase("long", ">>>", expr, "countNegative",
        "int", "-1", "1", rejects),
    ShiftCase("long", "<<", assign, "countNegative",
        "int", "-1", "0", agrees),
    ShiftCase("long", ">>", assign, "countNegative",
        "int", "-1", "-1", asserts),
    ShiftCase("long", ">>>", assign, "countNegative",
        "int", "-1", "1", asserts),
    ShiftCase("ulong", "<<", expr, "countAboveWidth",
        "int", "65", "18446744073709551614", rejects),
    ShiftCase("ulong", ">>", expr, "countAboveWidth",
        "int", "65", "9223372036854775807", rejects),
    ShiftCase("ulong", ">>>", expr, "countAboveWidth",
        "int", "65", "9223372036854775807", rejects),
    ShiftCase("ulong", "<<", assign, "countAboveWidth",
        "int", "65", "18446744073709551614", agrees),
    ShiftCase("ulong", ">>", assign, "countAboveWidth",
        "int", "65", "9223372036854775807", agrees),
    ShiftCase("ulong", ">>>", assign, "countAboveWidth",
        "int", "65", "9223372036854775807", agrees),
    ShiftCase("ulong", "<<", expr, "countNegative",
        "int", "-1", "9223372036854775808", rejects),
    ShiftCase("ulong", ">>", expr, "countNegative",
        "int", "-1", "1", rejects),
    ShiftCase("ulong", ">>>", expr, "countNegative",
        "int", "-1", "1", rejects),
    ShiftCase("ulong", "<<", assign, "countNegative",
        "int", "-1", "9223372036854775808", agrees),
    ShiftCase("ulong", ">>", assign, "countNegative",
        "int", "-1", "1", asserts),
    ShiftCase("ulong", ">>>", assign, "countNegative",
        "int", "-1", "1", asserts),
    ShiftCase("byte", "<<", expr, "countAboveWidth",
        "int", "33", "56", rejects),
    ShiftCase("byte", ">>", expr, "countAboveWidth",
        "int", "33", "-50", rejects),
    ShiftCase("byte", ">>>", expr, "countAboveWidth",
        "int", "33", "-50", rejects),
    ShiftCase("byte", "<<", assign, "countAboveWidth",
        "int", "33", "56", differs, "0"),
    ShiftCase("byte", ">>", assign, "countAboveWidth",
        "int", "33", "-50", agrees),
    ShiftCase("byte", ">>>", assign, "countAboveWidth",
        "int", "33", "78", differs, "0"),
    ShiftCase("byte", "<<", expr, "countNegative",
        "int", "-1", "0", rejects),
    ShiftCase("byte", ">>", expr, "countNegative",
        "int", "-1", "-1", rejects),
    ShiftCase("byte", ">>>", expr, "countNegative",
        "int", "-1", "1", rejects),
    ShiftCase("byte", "<<", assign, "countNegative",
        "int", "-1", "0", agrees),
    ShiftCase("byte", ">>", assign, "countNegative",
        "int", "-1", "-1", asserts),
    ShiftCase("byte", ">>>", assign, "countNegative",
        "int", "-1", "0", asserts),
    ShiftCase("byte", "<<", expr, "countEqualsOperandWidth",
        "int", "8", "0", agrees),
    ShiftCase("byte", ">>", expr, "countEqualsOperandWidth",
        "int", "8", "-1", agrees),
    ShiftCase("byte", ">>>", expr, "countEqualsOperandWidth",
        "int", "8", "-1", agrees),
    ShiftCase("byte", "<<", assign, "countEqualsOperandWidth",
        "int", "8", "0", agrees),
    ShiftCase("byte", ">>", assign, "countEqualsOperandWidth",
        "int", "8", "-1", agrees),
    ShiftCase("byte", ">>>", assign, "countEqualsOperandWidth",
        "int", "8", "0", agrees),
    ShiftCase("short", "<<", expr, "countAboveWidth",
        "int", "33", "-200", rejects),
    ShiftCase("short", ">>", expr, "countAboveWidth",
        "int", "33", "-50", rejects),
    ShiftCase("short", ">>>", expr, "countAboveWidth",
        "int", "33", "-50", rejects),
    ShiftCase("short", "<<", assign, "countAboveWidth",
        "int", "33", "-200", differs, "0"),
    ShiftCase("short", ">>", assign, "countAboveWidth",
        "int", "33", "-50", agrees),
    ShiftCase("short", ">>>", assign, "countAboveWidth",
        "int", "33", "32718", differs, "0"),
    ShiftCase("short", "<<", expr, "countNegative",
        "int", "-1", "0", rejects),
    ShiftCase("short", ">>", expr, "countNegative",
        "int", "-1", "-1", rejects),
    ShiftCase("short", ">>>", expr, "countNegative",
        "int", "-1", "1", rejects),
    ShiftCase("short", "<<", assign, "countNegative",
        "int", "-1", "0", agrees),
    ShiftCase("short", ">>", assign, "countNegative",
        "int", "-1", "-1", asserts),
    ShiftCase("short", ">>>", assign, "countNegative",
        "int", "-1", "0", asserts),
    ShiftCase("short", "<<", expr, "countEqualsOperandWidth",
        "int", "16", "0", agrees),
    ShiftCase("short", ">>", expr, "countEqualsOperandWidth",
        "int", "16", "-1", agrees),
    ShiftCase("short", ">>>", expr, "countEqualsOperandWidth",
        "int", "16", "-1", agrees),
    ShiftCase("short", "<<", assign, "countEqualsOperandWidth",
        "int", "16", "0", agrees),
    ShiftCase("short", ">>", assign, "countEqualsOperandWidth",
        "int", "16", "-1", agrees),
    ShiftCase("short", ">>>", assign, "countEqualsOperandWidth",
        "int", "16", "0", agrees),
    ShiftCase("ubyte", "<<", expr, "countAboveWidth",
        "int", "33", "254", rejects),
    ShiftCase("ubyte", ">>", expr, "countAboveWidth",
        "int", "33", "127", rejects),
    ShiftCase("ubyte", ">>>", expr, "countAboveWidth",
        "int", "33", "127", rejects),
    ShiftCase("ubyte", "<<", expr, "countNegative",
        "int", "-1", "0", rejects),
    ShiftCase("ubyte", ">>", expr, "countNegative",
        "int", "-1", "0", rejects),
    ShiftCase("ubyte", ">>>", expr, "countNegative",
        "int", "-1", "0", rejects),
    ShiftCase("ubyte", "<<", expr, "countEqualsOperandWidth",
        "int", "8", "0", agrees),
    ShiftCase("ubyte", ">>", expr, "countEqualsOperandWidth",
        "int", "8", "0", agrees),
    ShiftCase("ubyte", ">>>", expr, "countEqualsOperandWidth",
        "int", "8", "0", agrees),
    ShiftCase("ushort", "<<", expr, "countAboveWidth",
        "int", "33", "65534", rejects),
    ShiftCase("ushort", ">>", expr, "countAboveWidth",
        "int", "33", "32767", rejects),
    ShiftCase("ushort", ">>>", expr, "countAboveWidth",
        "int", "33", "32767", rejects),
    ShiftCase("ushort", "<<", expr, "countNegative",
        "int", "-1", "0", rejects),
    ShiftCase("ushort", ">>", expr, "countNegative",
        "int", "-1", "0", rejects),
    ShiftCase("ushort", ">>>", expr, "countNegative",
        "int", "-1", "0", rejects),
    ShiftCase("ushort", "<<", expr, "countEqualsOperandWidth",
        "int", "16", "0", agrees),
    ShiftCase("ushort", ">>", expr, "countEqualsOperandWidth",
        "int", "16", "0", agrees),
    ShiftCase("ushort", ">>>", expr, "countEqualsOperandWidth",
        "int", "16", "0", agrees),
    ShiftCase("ubyte", "<<", assign, "countAboveWidth",
        "int", "33", "254", differs, "0"),
    ShiftCase("ubyte", ">>", assign, "countAboveWidth",
        "int", "33", "127", agrees),
    ShiftCase("ubyte", ">>>", assign, "countAboveWidth",
        "int", "33", "127", differs, "0"),
    ShiftCase("ubyte", "<<", assign, "countNegative",
        "int", "-1", "0", agrees),
    ShiftCase("ubyte", ">>", assign, "countNegative",
        "int", "-1", "0", asserts),
    ShiftCase("ubyte", ">>>", assign, "countNegative",
        "int", "-1", "0", asserts),
    ShiftCase("ubyte", "<<", assign, "countEqualsOperandWidth",
        "int", "8", "0", agrees),
    ShiftCase("ubyte", ">>", assign, "countEqualsOperandWidth",
        "int", "8", "0", agrees),
    ShiftCase("ubyte", ">>>", assign, "countEqualsOperandWidth",
        "int", "8", "0", agrees),
    ShiftCase("ushort", "<<", assign, "countAboveWidth",
        "int", "33", "65534", differs, "0"),
    ShiftCase("ushort", ">>", assign, "countAboveWidth",
        "int", "33", "32767", agrees),
    ShiftCase("ushort", ">>>", assign, "countAboveWidth",
        "int", "33", "32767", differs, "0"),
    ShiftCase("ushort", "<<", assign, "countNegative",
        "int", "-1", "0", agrees),
    ShiftCase("ushort", ">>", assign, "countNegative",
        "int", "-1", "0", asserts),
    ShiftCase("ushort", ">>>", assign, "countNegative",
        "int", "-1", "0", asserts),
    ShiftCase("ushort", "<<", assign, "countEqualsOperandWidth",
        "int", "16", "0", agrees),
    ShiftCase("ushort", ">>", assign, "countEqualsOperandWidth",
        "int", "16", "0", agrees),
    ShiftCase("ushort", ">>>", assign, "countEqualsOperandWidth",
        "int", "16", "0", agrees),
    ShiftCase("int", "<<", assign, "longCountAboveWidth",
        "long", "33", "0", agrees),
    ShiftCase("int", ">>", assign, "longCountAboveWidth",
        "long", "33", "-1", differs, "-50"),
    ShiftCase("uint", "<<", assign, "ulongCountEqualsWidth",
        "ulong", "32", "0", agrees),
    ShiftCase("byte", ">>", assign, "longCountEqualsOperandWidth",
        "long", "8", "-1", agrees),
    ShiftCase("short", ">>", assign, "uintCountEqualsOperandWidth",
        "uint", "16", "-1", agrees),
    ShiftCase("byte", ">>>", assign, "longCountEqualsOperandWidth",
        "long", "8", "-1", differs, "0"),
    ShiftCase("int", ">>>", assign, "longCountAboveWidth",
        "long", "33", "int.max", differs, "0"),
    ShiftCase("byte", ">>>", assign, "longCountInRange",
        "long", "1", "-50", differs, "78"),
    ShiftCase("int", ">>>", assign, "longCountInRange",
        "long", "1", "-50", differs, "2147483598"),
    ShiftCase("int", ">>", assign, "uintCountInRange",
        "uint", "1", "-50", agrees),
    ShiftCase("long", ">>", assign, "ulongCountInRange",
        "ulong", "1", "-50", agrees),
    ShiftCase("uint", ">>", assign, "longCountEqualsWidth",
        "long", "32", "0", differs, "4294967295"),
    ShiftCase("long", "<<", assignLiteral, "intCountInRange",
        "int", "1", "-200", agrees),
    ShiftCase("long", ">>", assignLiteral, "intCountInRange",
        "int", "1", "-50", agrees),
    ShiftCase("long", ">>>", assignLiteral, "intCountInRange",
        "int", "1", "long.max - 49", agrees),
    ShiftCase("ulong", ">>", assignLiteral, "intCountInRange",
        "int", "1", "long.max", agrees),
];

private string testName(in ShiftCase row) {
    const opName = row.op == "<<" ? "shl" : row.op == ">>" ? "shr" : "ushr";

    return "shift." ~ row.type ~ "." ~ opName
        ~ (row.form == expr ? "." : row.form == assign
            ? "Assign." : "AssignLiteral.") ~ row.name;
}

private string shiftCode(in ShiftCase row) {
    const value = row.type[0] == 'u' ? row.type ~ ".max" : "-100";
    const shifted = row.form == expr
        ? "return cast(" ~ row.type ~ ")(value() " ~ row.op ~ " count());"
        : row.type ~ " v = value();\n    v " ~ row.op ~ "= "
            ~ (row.form == assign ? "count()" : row.count)
            ~ ";\n    return v;";

    return row.type ~ " value() { return " ~ value ~ "; }\n"
        ~ row.countType ~ " count() { return " ~ row.count ~ "; }\n"
        ~ row.type ~ " shifted() {\n    " ~ shifted ~ "\n}\n";
}

private template CtfeOmissions(ShiftCase.Outcome ctfe) {
    static if (ctfe == agrees)
        alias CtfeOmissions = AliasSeq!();
    else static if (ctfe == rejects)
        alias CtfeOmissions = AliasSeq!(RejectedByCtfe);
    else static if (ctfe == asserts)
        alias CtfeOmissions = AliasSeq!(AssertsInCtfe);
    else
        alias CtfeOmissions = AliasSeq!(DiffersInCtfe);
}

static foreach (row; shiftCases) {
    static foreach (backend; Matrix!(CtfeOmissions!(row.ctfe))) {
        @(row.testName ~ "." ~ backend.stringof)
        @Tags(backend.stringof)
        unittest {
            mixin(row.type, "(", row.expected, ")").shouldBeRetOf!(
                backend, row.shiftCode, "shifted");
        }
    }
}

// CTFE runs the cases it omits above and gives these values instead.
static foreach (row; shiftCases) {
    static if (row.ctfe == differs) {
        @(row.testName ~ ".Ctfe.diverges")
        @Tags("Ctfe")
        unittest {
            mixin(row.type, "(", row.ctfeValue, ")").shouldBeRetOf!(
                Ctfe, row.shiftCode, "shifted");
        }
    }
}

// A `long` count promotes a `byte` target twice (`cast(long)cast(int)`),
// and the shift runs at 64 bits on the sign-extended target. The store
// must go to the array element under both casts and leave the adjacent
// elements as they were.
private enum elementLongCountCode = q{
    long count() { return 8; }
    int shifted() {
        byte[] a = [-100, -100, -100];
        a[1] >>>= count();
        return a[0] * 10_000 + a[1] * 100 + a[2];
    }
};

static foreach (backend; Matrix!(DiffersInCtfe)) {
    @("shift.byte.ushrAssign.element.longCount." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        (-1_000_200).shouldBeRetOf!(backend, elementLongCountCode, "shifted");
    }
}

@("shift.byte.ushrAssign.element.longCount.Ctfe.diverges")
@Tags("Ctfe")
unittest {
    (-1_000_100).shouldBeRetOf!(Ctfe, elementLongCountCode, "shifted");
}

// The same double promotion with a struct field as the target: the store
// must go to the field under both casts and leave the adjacent fields as
// they were.
private enum fieldLongCountCode = q{
    struct S { byte before = -100; byte f = -100; byte after = -100; }
    long count() { return 8; }
    int shifted() {
        S s;
        s.f >>>= count();
        return s.before * 10_000 + s.f * 100 + s.after;
    }
};

static foreach (backend; Matrix!(DiffersInCtfe)) {
    @("shift.byte.ushrAssign.field.longCount." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        (-1_000_200).shouldBeRetOf!(backend, fieldLongCountCode, "shifted");
    }
}

@("shift.byte.ushrAssign.field.longCount.Ctfe.diverges")
@Tags("Ctfe")
unittest {
    (-1_000_100).shouldBeRetOf!(Ctfe, fieldLongCountCode, "shifted");
}
