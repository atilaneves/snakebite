module ut.backends;

public import ut;
public import snakebite.backends.ctfe: Ctfe;
public import std.meta: AliasSeq;

import snakebite.frontend.compiler: parseSnippet;
import snakebite.frontend.dmd.functions: findFunction;
import std.conv: text;
import std.meta: Filter, staticIndexOf;
import std.traits: isInstanceOf;


// Why a backend is missing from a test's `Matrix!(...)`. Every `Omit!(...)`
// names one of these so the omission is documentation, not silence.
public enum Because {
    inexpressible, // the backend can never run the construct (note required)
    diverges,      // pinned in a sibling test that asserts the actual
                   // behaviour (note required)
    unconfirmed,   // never tried (note optional)
}

// Removes `B` from a test's `Matrix!(...)`, with a reason. `B` must be one of
// `Backends`, otherwise it is a typo since it could never have been in the
// matrix to begin with.
public struct Omit(B, Because why, string note = "") {
    static assert(staticIndexOf!(B, Backends) != -1,
        "Omit!(" ~ B.stringof ~ ", ...): `" ~ B.stringof ~
        "` is not in `Backends` - typo?");
    static assert(note.length > 0 || why == Because.unconfirmed,
        "Omit!(" ~ B.stringof ~ ", Because." ~ text(why) ~
        ", ...): a non-empty `note` is required for this reason");

    public alias Backend = B;
    public enum reason = why;
    public enum note_ = note;
}

// The backends a test runs on: `Backends` minus every `Omit!(...)`. Usable
// directly as `static foreach (backend; Matrix!(...))`.
public template Matrix(specs...) {
    static foreach (spec; specs)
        static assert(isInstanceOf!(Omit, spec),
            "Matrix!(...): `" ~ spec.stringof ~ "` is not an `Omit!(...)`");

    private template Omitted(specs...) {
        static if (specs.length == 0)
            alias Omitted = AliasSeq!();
        else
            alias Omitted = AliasSeq!(specs[0].Backend, Omitted!(specs[1 .. $]));
    }

    private enum bool notOmitted(B) = staticIndexOf!(B, Omitted!specs) == -1;

    public alias Matrix = Filter!(notOmitted, Backends);
}


// `code` is regular compiled D: dmd mixes it in when building `bin/ut`, and
// the native rendering of the value is the expectation. The same snippet,
// wrapped in a `string`-returning function that renders the value in the
// guest, is parsed and semantically analysed and then handed to the backend,
// which must agree with the native result.
string eval(BackendType, string code)(
    in string file = __FILE__,
    in size_t line = __LINE__,
) {
    return eval!(BackendType, "", code)(file, line);
}

// As above, with `declarations` in scope for `code`. Natively they are nested
// in the function that mixes them in; in the guest they are module-level.
// DMD constant-folds literal-only expressions during semantic analysis, so a
// test that wants a backend to do the arithmetic itself keeps an operand
// behind a function declared here.
string eval(BackendType, string declarations, string code)(
    in string file = __FILE__,
    in size_t line = __LINE__,
) {
    const native = () {
        mixin(declarations);
        return text(mixin(code));
    }();

    auto module_ = parseSnippet(evalSource(declarations, code)).module_;
    auto function_ = findFunction(module_, "__eval");

    const guest = (new BackendType).eval(function_);
    guest.shouldEqual(native, file, line);

    return native;
}

private string evalSource(in string declarations, in string code) {
    return declarations ~
        "\nstring __eval() { import std.conv: text; return text(" ~
        code ~ "); }";
}
