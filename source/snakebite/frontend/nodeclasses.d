module snakebite.frontend.nodeclasses;

private:

import std.meta: AliasSeq;


// Each class that dmd declares in `dmd.expression` and in `dmd.statement`, for
// checks that each node class has a policy. Code outside the frontend package
// imports no dmd module (`snakebite.frontend.ast`), so it cannot list the
// members of one.
public alias ExpressionClasses = classesIn!(imported!"dmd.expression",
    imported!"dmd.expression".Expression);

/// Ditto
public alias StatementClasses = classesIn!(imported!"dmd.statement",
    imported!"dmd.statement".Statement);

private template classesIn(alias module_, Base) {
    alias classesIn = AliasSeq!();
    static foreach (name; __traits(allMembers, module_)) {
        static if (__traits(compiles, __traits(getMember, module_, name))
                && is(__traits(getMember, module_, name) == class)
                && is(__traits(getMember, module_, name) : Base))
            classesIn = AliasSeq!(classesIn, __traits(getMember, module_, name));
    }
}
