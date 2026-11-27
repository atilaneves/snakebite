module snakebite.language.definition;


private:


// Where a declaration is defined, as the linker of a native build sees it
// (ADR-0009). The compile of the root modules is the one that defines what is
// "defined here".
public enum Definition {
    // Only the root modules define it, and a backend executes it: a
    // **root-owned** declaration with a body and no `extern` storage.
    rootOwned,
    // The root modules define it, and another object can define it too: what
    // a template instance holds, because a native build emits an instance
    // into each object that uses it. One copy is kept. A function literal,
    // and what is nested in a root function but declared by a dependency,
    // are the same.
    rootOrElsewhere,
    // Another object defines it, as the glossary says: a declaration with
    // no body or an `extern` one, and each declaration of a dependency
    // module that its archive defines. A missing symbol for it is a link
    // error, never a reason to use the body.
    definedElsewhere,
}


// How a compile to an SBC file defines the symbol of a declaration that is
// defined as `where` says: a strong definition (`No.weak`) for `rootOwned`, a
// weak one (`Yes.weak`) for `rootOrElsewhere`, as the glossary says, and none
// (null) for `definedElsewhere`.
public imported!"std.typecons".Nullable!(imported!"std.typecons".Flag!"weak")
definitionInFile(in Definition where) @safe pure nothrow @nogc {
    import std.typecons: Flag, No, Nullable, Yes;

    alias Defined = Nullable!(Flag!"weak");
    final switch (where) with (Definition) {
        case rootOwned:
            return Defined(No.weak);
        case rootOrElsewhere:
            return Defined(Yes.weak);
        case definedElsewhere:
            return Defined.init;
    }
}
