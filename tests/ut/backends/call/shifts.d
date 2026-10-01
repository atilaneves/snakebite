module ut.backends.call.shifts;


import ut.backends;


// A shift count at or above the operand's width has no answer in the
// language, so compiled D gives whatever the CPU does: x86-64 takes the
// count modulo 32 for every operand that promotes to `int` and modulo 64
// for `long`. `byte` and `short` promote, so for them the width that
// matters is 32, not the operand's own. The count comes from a call so
// dmd cannot fold or reject it. CTFE has no such run-time rule: it
// rejects the count, answers 0 for `<<=` and `>>>=`, or asserts.
private alias RejectedByCtfe = Omit!(Ctfe, Because.inexpressible,
    "CTFE rejects an out-of-range shift count at compile time");
private alias WrongInCtfe = Omit!(Ctfe, Because.inexpressible,
    "CTFE gives 0 for `<<=` and `>>>=` with an out-of-range count, " ~
    "where the CPU masks the count");

private alias AssertsInCtfe = Omit!(Ctfe, Because.inexpressible,
    "dmd's CTFE asserts on a negative `>>=` or `>>>=` count");

// The signed operand is -100 and the unsigned one is its type's maximum,
// so every bit of the result tells which count the shift used.
private string shiftCode(
    string type, string op, string form, string count,
) {
    const value = type[0] == 'u' ? type ~ ".max" : "-100";
    const shifted = form == "expr"
        ? "return cast(" ~ type ~ ")(value() " ~ op ~ " count());"
        : type ~ " v = value();\n    v " ~ op ~ "= count();\n    return v;";

    return type ~ " value() { return " ~ value ~ "; }\n"
        ~ "int count() { return " ~ count ~ "; }\n"
        ~ type ~ " shifted() {\n    " ~ shifted ~ "\n}\n";
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.int.shl.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        int(-100).shouldBeRetOf!(
            backend, shiftCode("int", "<<", "expr", "32"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.int.shr.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        int(-100).shouldBeRetOf!(
            backend, shiftCode("int", ">>", "expr", "32"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.int.ushr.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        int(-100).shouldBeRetOf!(
            backend, shiftCode("int", ">>>", "expr", "32"), "shifted");
    }
}

static foreach (backend; Matrix!(WrongInCtfe)) {
    @("shift.int.shlAssign.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        int(-100).shouldBeRetOf!(
            backend, shiftCode("int", "<<", "assign", "32"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.int.shrAssign.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        int(-100).shouldBeRetOf!(
            backend, shiftCode("int", ">>", "assign", "32"), "shifted");
    }
}

static foreach (backend; Matrix!(WrongInCtfe)) {
    @("shift.int.ushrAssign.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        int(-100).shouldBeRetOf!(
            backend, shiftCode("int", ">>>", "assign", "32"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.int.shl.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        int(-200).shouldBeRetOf!(
            backend, shiftCode("int", "<<", "expr", "33"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.int.shr.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        int(-50).shouldBeRetOf!(
            backend, shiftCode("int", ">>", "expr", "33"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.int.ushr.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        int(2147483598).shouldBeRetOf!(
            backend, shiftCode("int", ">>>", "expr", "33"), "shifted");
    }
}

static foreach (backend; Matrix!(WrongInCtfe)) {
    @("shift.int.shlAssign.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        int(-200).shouldBeRetOf!(
            backend, shiftCode("int", "<<", "assign", "33"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.int.shrAssign.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        int(-50).shouldBeRetOf!(
            backend, shiftCode("int", ">>", "assign", "33"), "shifted");
    }
}

static foreach (backend; Matrix!(WrongInCtfe)) {
    @("shift.int.ushrAssign.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        int(2147483598).shouldBeRetOf!(
            backend, shiftCode("int", ">>>", "assign", "33"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.int.shl.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        int(0).shouldBeRetOf!(
            backend, shiftCode("int", "<<", "expr", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.int.shr.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        int(-1).shouldBeRetOf!(
            backend, shiftCode("int", ">>", "expr", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.int.ushr.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        int(1).shouldBeRetOf!(
            backend, shiftCode("int", ">>>", "expr", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.int.shlAssign.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        int(0).shouldBeRetOf!(
            backend, shiftCode("int", "<<", "assign", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(AssertsInCtfe)) {
    @("shift.int.shrAssign.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        int(-1).shouldBeRetOf!(
            backend, shiftCode("int", ">>", "assign", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(AssertsInCtfe)) {
    @("shift.int.ushrAssign.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        int(1).shouldBeRetOf!(
            backend, shiftCode("int", ">>>", "assign", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.uint.shl.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        uint(4294967295).shouldBeRetOf!(
            backend, shiftCode("uint", "<<", "expr", "32"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.uint.shr.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        uint(4294967295).shouldBeRetOf!(
            backend, shiftCode("uint", ">>", "expr", "32"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.uint.ushr.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        uint(4294967295).shouldBeRetOf!(
            backend, shiftCode("uint", ">>>", "expr", "32"), "shifted");
    }
}

static foreach (backend; Matrix!(WrongInCtfe)) {
    @("shift.uint.shlAssign.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        uint(4294967295).shouldBeRetOf!(
            backend, shiftCode("uint", "<<", "assign", "32"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.uint.shrAssign.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        uint(4294967295).shouldBeRetOf!(
            backend, shiftCode("uint", ">>", "assign", "32"), "shifted");
    }
}

static foreach (backend; Matrix!(WrongInCtfe)) {
    @("shift.uint.ushrAssign.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        uint(4294967295).shouldBeRetOf!(
            backend, shiftCode("uint", ">>>", "assign", "32"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.uint.shl.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        uint(4294967294).shouldBeRetOf!(
            backend, shiftCode("uint", "<<", "expr", "33"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.uint.shr.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        uint(2147483647).shouldBeRetOf!(
            backend, shiftCode("uint", ">>", "expr", "33"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.uint.ushr.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        uint(2147483647).shouldBeRetOf!(
            backend, shiftCode("uint", ">>>", "expr", "33"), "shifted");
    }
}

static foreach (backend; Matrix!(WrongInCtfe)) {
    @("shift.uint.shlAssign.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        uint(4294967294).shouldBeRetOf!(
            backend, shiftCode("uint", "<<", "assign", "33"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.uint.shrAssign.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        uint(2147483647).shouldBeRetOf!(
            backend, shiftCode("uint", ">>", "assign", "33"), "shifted");
    }
}

static foreach (backend; Matrix!(WrongInCtfe)) {
    @("shift.uint.ushrAssign.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        uint(2147483647).shouldBeRetOf!(
            backend, shiftCode("uint", ">>>", "assign", "33"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.uint.shl.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        uint(2147483648).shouldBeRetOf!(
            backend, shiftCode("uint", "<<", "expr", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.uint.shr.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        uint(1).shouldBeRetOf!(
            backend, shiftCode("uint", ">>", "expr", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.uint.ushr.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        uint(1).shouldBeRetOf!(
            backend, shiftCode("uint", ">>>", "expr", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(WrongInCtfe)) {
    @("shift.uint.shlAssign.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        uint(2147483648).shouldBeRetOf!(
            backend, shiftCode("uint", "<<", "assign", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(AssertsInCtfe)) {
    @("shift.uint.shrAssign.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        uint(1).shouldBeRetOf!(
            backend, shiftCode("uint", ">>", "assign", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(AssertsInCtfe)) {
    @("shift.uint.ushrAssign.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        uint(1).shouldBeRetOf!(
            backend, shiftCode("uint", ">>>", "assign", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.long.shl.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        long(-100).shouldBeRetOf!(
            backend, shiftCode("long", "<<", "expr", "64"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.long.shr.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        long(-100).shouldBeRetOf!(
            backend, shiftCode("long", ">>", "expr", "64"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.long.ushr.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        long(-100).shouldBeRetOf!(
            backend, shiftCode("long", ">>>", "expr", "64"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.long.shlAssign.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        long(-100).shouldBeRetOf!(
            backend, shiftCode("long", "<<", "assign", "64"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.long.shrAssign.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        long(-100).shouldBeRetOf!(
            backend, shiftCode("long", ">>", "assign", "64"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.long.ushrAssign.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        long(-100).shouldBeRetOf!(
            backend, shiftCode("long", ">>>", "assign", "64"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.long.shl.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        long(-200).shouldBeRetOf!(
            backend, shiftCode("long", "<<", "expr", "65"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.long.shr.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        long(-50).shouldBeRetOf!(
            backend, shiftCode("long", ">>", "expr", "65"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.long.ushr.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        long(9223372036854775758).shouldBeRetOf!(
            backend, shiftCode("long", ">>>", "expr", "65"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.long.shlAssign.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        long(-200).shouldBeRetOf!(
            backend, shiftCode("long", "<<", "assign", "65"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.long.shrAssign.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        long(-50).shouldBeRetOf!(
            backend, shiftCode("long", ">>", "assign", "65"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.long.ushrAssign.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        long(9223372036854775758).shouldBeRetOf!(
            backend, shiftCode("long", ">>>", "assign", "65"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.long.shl.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        long(0).shouldBeRetOf!(
            backend, shiftCode("long", "<<", "expr", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.long.shr.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        long(-1).shouldBeRetOf!(
            backend, shiftCode("long", ">>", "expr", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.long.ushr.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        long(1).shouldBeRetOf!(
            backend, shiftCode("long", ">>>", "expr", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.long.shlAssign.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        long(0).shouldBeRetOf!(
            backend, shiftCode("long", "<<", "assign", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(AssertsInCtfe)) {
    @("shift.long.shrAssign.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        long(-1).shouldBeRetOf!(
            backend, shiftCode("long", ">>", "assign", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(AssertsInCtfe)) {
    @("shift.long.ushrAssign.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        long(1).shouldBeRetOf!(
            backend, shiftCode("long", ">>>", "assign", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.ulong.shl.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        ulong(18446744073709551615).shouldBeRetOf!(
            backend, shiftCode("ulong", "<<", "expr", "64"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.ulong.shr.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        ulong(18446744073709551615).shouldBeRetOf!(
            backend, shiftCode("ulong", ">>", "expr", "64"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.ulong.ushr.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        ulong(18446744073709551615).shouldBeRetOf!(
            backend, shiftCode("ulong", ">>>", "expr", "64"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.ulong.shlAssign.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        ulong(18446744073709551615).shouldBeRetOf!(
            backend, shiftCode("ulong", "<<", "assign", "64"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.ulong.shrAssign.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        ulong(18446744073709551615).shouldBeRetOf!(
            backend, shiftCode("ulong", ">>", "assign", "64"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.ulong.ushrAssign.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        ulong(18446744073709551615).shouldBeRetOf!(
            backend, shiftCode("ulong", ">>>", "assign", "64"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.ulong.shl.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        ulong(18446744073709551614).shouldBeRetOf!(
            backend, shiftCode("ulong", "<<", "expr", "65"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.ulong.shr.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        ulong(9223372036854775807).shouldBeRetOf!(
            backend, shiftCode("ulong", ">>", "expr", "65"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.ulong.ushr.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        ulong(9223372036854775807).shouldBeRetOf!(
            backend, shiftCode("ulong", ">>>", "expr", "65"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.ulong.shlAssign.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        ulong(18446744073709551614).shouldBeRetOf!(
            backend, shiftCode("ulong", "<<", "assign", "65"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.ulong.shrAssign.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        ulong(9223372036854775807).shouldBeRetOf!(
            backend, shiftCode("ulong", ">>", "assign", "65"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.ulong.ushrAssign.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        ulong(9223372036854775807).shouldBeRetOf!(
            backend, shiftCode("ulong", ">>>", "assign", "65"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.ulong.shl.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        ulong(9223372036854775808).shouldBeRetOf!(
            backend, shiftCode("ulong", "<<", "expr", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.ulong.shr.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        ulong(1).shouldBeRetOf!(
            backend, shiftCode("ulong", ">>", "expr", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.ulong.ushr.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        ulong(1).shouldBeRetOf!(
            backend, shiftCode("ulong", ">>>", "expr", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.ulong.shlAssign.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        ulong(9223372036854775808).shouldBeRetOf!(
            backend, shiftCode("ulong", "<<", "assign", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(AssertsInCtfe)) {
    @("shift.ulong.shrAssign.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        ulong(1).shouldBeRetOf!(
            backend, shiftCode("ulong", ">>", "assign", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(AssertsInCtfe)) {
    @("shift.ulong.ushrAssign.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        ulong(1).shouldBeRetOf!(
            backend, shiftCode("ulong", ">>>", "assign", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.byte.shl.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        byte(-100).shouldBeRetOf!(
            backend, shiftCode("byte", "<<", "expr", "32"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.byte.shr.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        byte(-100).shouldBeRetOf!(
            backend, shiftCode("byte", ">>", "expr", "32"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.byte.ushr.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        byte(-100).shouldBeRetOf!(
            backend, shiftCode("byte", ">>>", "expr", "32"), "shifted");
    }
}

static foreach (backend; Matrix!(WrongInCtfe)) {
    @("shift.byte.shlAssign.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        byte(-100).shouldBeRetOf!(
            backend, shiftCode("byte", "<<", "assign", "32"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.byte.shrAssign.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        byte(-100).shouldBeRetOf!(
            backend, shiftCode("byte", ">>", "assign", "32"), "shifted");
    }
}

static foreach (backend; Matrix!(WrongInCtfe)) {
    @("shift.byte.ushrAssign.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        byte(-100).shouldBeRetOf!(
            backend, shiftCode("byte", ">>>", "assign", "32"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.byte.shl.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        byte(56).shouldBeRetOf!(
            backend, shiftCode("byte", "<<", "expr", "33"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.byte.shr.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        byte(-50).shouldBeRetOf!(
            backend, shiftCode("byte", ">>", "expr", "33"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.byte.ushr.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        byte(-50).shouldBeRetOf!(
            backend, shiftCode("byte", ">>>", "expr", "33"), "shifted");
    }
}

static foreach (backend; Matrix!(WrongInCtfe)) {
    @("shift.byte.shlAssign.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        byte(56).shouldBeRetOf!(
            backend, shiftCode("byte", "<<", "assign", "33"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.byte.shrAssign.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        byte(-50).shouldBeRetOf!(
            backend, shiftCode("byte", ">>", "assign", "33"), "shifted");
    }
}

static foreach (backend; Matrix!(WrongInCtfe)) {
    @("shift.byte.ushrAssign.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        byte(78).shouldBeRetOf!(
            backend, shiftCode("byte", ">>>", "assign", "33"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.byte.shl.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        byte(0).shouldBeRetOf!(
            backend, shiftCode("byte", "<<", "expr", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.byte.shr.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        byte(-1).shouldBeRetOf!(
            backend, shiftCode("byte", ">>", "expr", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.byte.ushr.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        byte(1).shouldBeRetOf!(
            backend, shiftCode("byte", ">>>", "expr", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.byte.shlAssign.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        byte(0).shouldBeRetOf!(
            backend, shiftCode("byte", "<<", "assign", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(AssertsInCtfe)) {
    @("shift.byte.shrAssign.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        byte(-1).shouldBeRetOf!(
            backend, shiftCode("byte", ">>", "assign", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(AssertsInCtfe)) {
    @("shift.byte.ushrAssign.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        byte(0).shouldBeRetOf!(
            backend, shiftCode("byte", ">>>", "assign", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.byte.shl.countEqualsOperandWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        byte(0).shouldBeRetOf!(
            backend, shiftCode("byte", "<<", "expr", "8"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.byte.shr.countEqualsOperandWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        byte(-1).shouldBeRetOf!(
            backend, shiftCode("byte", ">>", "expr", "8"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.byte.ushr.countEqualsOperandWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        byte(-1).shouldBeRetOf!(
            backend, shiftCode("byte", ">>>", "expr", "8"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.byte.shlAssign.countEqualsOperandWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        byte(0).shouldBeRetOf!(
            backend, shiftCode("byte", "<<", "assign", "8"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.byte.shrAssign.countEqualsOperandWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        byte(-1).shouldBeRetOf!(
            backend, shiftCode("byte", ">>", "assign", "8"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.byte.ushrAssign.countEqualsOperandWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        byte(0).shouldBeRetOf!(
            backend, shiftCode("byte", ">>>", "assign", "8"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.short.shl.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        short(-100).shouldBeRetOf!(
            backend, shiftCode("short", "<<", "expr", "32"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.short.shr.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        short(-100).shouldBeRetOf!(
            backend, shiftCode("short", ">>", "expr", "32"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.short.ushr.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        short(-100).shouldBeRetOf!(
            backend, shiftCode("short", ">>>", "expr", "32"), "shifted");
    }
}

static foreach (backend; Matrix!(WrongInCtfe)) {
    @("shift.short.shlAssign.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        short(-100).shouldBeRetOf!(
            backend, shiftCode("short", "<<", "assign", "32"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.short.shrAssign.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        short(-100).shouldBeRetOf!(
            backend, shiftCode("short", ">>", "assign", "32"), "shifted");
    }
}

static foreach (backend; Matrix!(WrongInCtfe)) {
    @("shift.short.ushrAssign.countEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        short(-100).shouldBeRetOf!(
            backend, shiftCode("short", ">>>", "assign", "32"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.short.shl.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        short(-200).shouldBeRetOf!(
            backend, shiftCode("short", "<<", "expr", "33"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.short.shr.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        short(-50).shouldBeRetOf!(
            backend, shiftCode("short", ">>", "expr", "33"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.short.ushr.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        short(-50).shouldBeRetOf!(
            backend, shiftCode("short", ">>>", "expr", "33"), "shifted");
    }
}

static foreach (backend; Matrix!(WrongInCtfe)) {
    @("shift.short.shlAssign.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        short(-200).shouldBeRetOf!(
            backend, shiftCode("short", "<<", "assign", "33"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.short.shrAssign.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        short(-50).shouldBeRetOf!(
            backend, shiftCode("short", ">>", "assign", "33"), "shifted");
    }
}

static foreach (backend; Matrix!(WrongInCtfe)) {
    @("shift.short.ushrAssign.countAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        short(32718).shouldBeRetOf!(
            backend, shiftCode("short", ">>>", "assign", "33"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.short.shl.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        short(0).shouldBeRetOf!(
            backend, shiftCode("short", "<<", "expr", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.short.shr.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        short(-1).shouldBeRetOf!(
            backend, shiftCode("short", ">>", "expr", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(RejectedByCtfe)) {
    @("shift.short.ushr.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        short(1).shouldBeRetOf!(
            backend, shiftCode("short", ">>>", "expr", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.short.shlAssign.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        short(0).shouldBeRetOf!(
            backend, shiftCode("short", "<<", "assign", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(AssertsInCtfe)) {
    @("shift.short.shrAssign.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        short(-1).shouldBeRetOf!(
            backend, shiftCode("short", ">>", "assign", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!(AssertsInCtfe)) {
    @("shift.short.ushrAssign.countNegative." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        short(0).shouldBeRetOf!(
            backend, shiftCode("short", ">>>", "assign", "-1"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.short.shl.countEqualsOperandWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        short(0).shouldBeRetOf!(
            backend, shiftCode("short", "<<", "expr", "16"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.short.shr.countEqualsOperandWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        short(-1).shouldBeRetOf!(
            backend, shiftCode("short", ">>", "expr", "16"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.short.ushr.countEqualsOperandWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        short(-1).shouldBeRetOf!(
            backend, shiftCode("short", ">>>", "expr", "16"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.short.shlAssign.countEqualsOperandWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        short(0).shouldBeRetOf!(
            backend, shiftCode("short", "<<", "assign", "16"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.short.shrAssign.countEqualsOperandWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        short(-1).shouldBeRetOf!(
            backend, shiftCode("short", ">>", "assign", "16"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.short.ushrAssign.countEqualsOperandWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        short(0).shouldBeRetOf!(
            backend, shiftCode("short", ">>>", "assign", "16"), "shifted");
    }
}

static foreach (backend; Matrix!()) {
    @("shift.int.shlAssign.longCountAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        int(0).shouldBeRetOf!(
            backend,
            q{
                int value() { return -100; }
                long count() { return 33; }
                int shifted() {
                    int v = value();
                    v <<= count();
                    return v;
                }
            },
            "shifted",
        );
    }
}

static foreach (backend; Matrix!(WrongInCtfe)) {
    @("shift.int.shrAssign.longCountAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        int(-1).shouldBeRetOf!(
            backend,
            q{
                int value() { return -100; }
                long count() { return 33; }
                int shifted() {
                    int v = value();
                    v >>= count();
                    return v;
                }
            },
            "shifted",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("shift.uint.shlAssign.ulongCountEqualsWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        uint(0).shouldBeRetOf!(
            backend,
            q{
                uint value() { return uint.max; }
                ulong count() { return 32; }
                uint shifted() {
                    uint v = value();
                    v <<= count();
                    return v;
                }
            },
            "shifted",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("shift.byte.shrAssign.longCountEqualsOperandWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        byte(-1).shouldBeRetOf!(
            backend,
            q{
                byte value() { return -100; }
                long count() { return 8; }
                byte shifted() {
                    byte v = value();
                    v >>= count();
                    return v;
                }
            },
            "shifted",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("shift.short.shrAssign.uintCountEqualsOperandWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        short(-1).shouldBeRetOf!(
            backend,
            q{
                short value() { return -100; }
                uint count() { return 16; }
                short shifted() {
                    short v = value();
                    v >>= count();
                    return v;
                }
            },
            "shifted",
        );
    }
}

static foreach (backend; Matrix!(WrongInCtfe)) {
    @("shift.byte.ushrAssign.longCountEqualsOperandWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        byte(-1).shouldBeRetOf!(
            backend,
            q{
                byte value() { return -100; }
                long count() { return 8; }
                byte shifted() {
                    byte v = value();
                    v >>>= count();
                    return v;
                }
            },
            "shifted",
        );
    }
}

static foreach (backend; Matrix!(WrongInCtfe)) {
    @("shift.int.ushrAssign.longCountAboveWidth." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        int(int.max).shouldBeRetOf!(
            backend,
            q{
                int value() { return -100; }
                long count() { return 33; }
                int shifted() {
                    int v = value();
                    v >>>= count();
                    return v;
                }
            },
            "shifted",
        );
    }
}

static foreach (backend; Matrix!(WrongInCtfe)) {
    @("shift.byte.ushrAssign.longCountInRange." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        byte(-50).shouldBeRetOf!(
            backend,
            q{
                byte value() { return -100; }
                long count() { return 1; }
                byte shifted() {
                    byte v = value();
                    v >>>= count();
                    return v;
                }
            },
            "shifted",
        );
    }
}

static foreach (backend; Matrix!(WrongInCtfe)) {
    @("shift.int.ushrAssign.longCountInRange." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        int(-50).shouldBeRetOf!(
            backend,
            q{
                int value() { return -100; }
                long count() { return 1; }
                int shifted() {
                    int v = value();
                    v >>>= count();
                    return v;
                }
            },
            "shifted",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("shift.int.shrAssign.uintCountInRange." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        int(-50).shouldBeRetOf!(
            backend,
            q{
                int value() { return -100; }
                uint count() { return 1; }
                int shifted() {
                    int v = value();
                    v >>= count();
                    return v;
                }
            },
            "shifted",
        );
    }
}

static foreach (backend; Matrix!()) {
    @("shift.long.shrAssign.ulongCountInRange." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        long(-50).shouldBeRetOf!(
            backend,
            q{
                long value() { return -100; }
                ulong count() { return 1; }
                long shifted() {
                    long v = value();
                    v >>= count();
                    return v;
                }
            },
            "shifted",
        );
    }
}
