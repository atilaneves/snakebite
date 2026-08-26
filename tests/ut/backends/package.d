module ut.backends;

public import ut;
public import snakebite.backends.ctfe: Ctfe;
public import snakebite.backends.interpreter: Interpreter;
public import std.meta: AliasSeq;

import core.sync.mutex: Mutex;
import dmd.dmodule: Module;
import dmd.func: FuncDeclaration;
import snakebite.frontend.compiler: parseSnippet, parseSnippets;
import snakebite.frontend.dmd.functions: findFunction, findStruct;
import std.conv: text;
import std.meta: Filter, staticIndexOf;
import std.traits: isInstanceOf, moduleName;


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


// Opt-in for a test module: `mixin SnippetTests;` at the top gives it `eval`.
//
// `code` is regular compiled D: dmd mixes it in when building `bin/ut`, and
// the native rendering of the value is the expectation. The same snippet,
// wrapped in a `string`-returning function that renders the value in the
// guest, is handed to the backend, which must agree with the native result.
//
// All of a module's snippets are parsed and semantically analysed together,
// as one guest module, the first time any of them is evaluated. dmd
// serialises that work; the tests themselves then only run the backend.
public mixin template SnippetTests() {
    private struct SnippetTestsTag {}
    private enum snippetModule = imported!"std.traits".moduleName!SnippetTestsTag;

    string eval(BackendType, string code)(
        in string file = __FILE__,
        in size_t line = __LINE__,
    ) {
        return eval!(BackendType, "", code)(file, line);
    }

    // As above, with `declarations` in scope for `code`. Natively they are
    // nested in the function that mixes them in; in the guest they are
    // static members of the snippet's struct. DMD constant-folds
    // literal-only expressions during semantic analysis, so a test that
    // wants a backend to do the arithmetic itself keeps an operand behind a
    // function declared here.
    string eval(BackendType, string declarations, string code)(
        in string file = __FILE__,
        in size_t line = __LINE__,
    ) {
        return imported!"ut.backends".evaluate!(
            snippetModule, BackendType, declarations, code,
        )(file, line);
    }
}

// Parse `code` as a whole guest program and run it on the backend the way
// compiled D would run it, returning the exit status.
//
// `code` is registered under the caller's module (`__MODULE__`, resolved at
// the call site as a template default, the same trick `__FILE__`/`__LINE__`
// already rely on below) the same way `eval` snippets register through
// `SnippetTests`. The first `run`/`shouldBeRetOf` call from a given test
// module parses every program that module registered in one batch, so dmd's
// per-batch setup cost is paid once per module, not once per test.
public int run(BackendType, string code, string module_ = __MODULE__)() {
    import snakebite.backends.backend: Program, run;

    enum program_ = RegisterProgram!(module_, code).program;
    auto program = Program([parsedProgram(program_)]);
    return run(new BackendType, program);
}

// UFCS assertion: `42.shouldBeRetOf!(backend, code, "answer")` invokes one
// guest function through the backend's `call` and checks its result against
// `expected`, whose type states the guest function's return type. The
// guest's actual return type must match it in size, so a lying test fails
// loudly instead of reading garbage bytes.
//
// `code` is registered and batch-parsed the same way `run`'s is; see there.
public void shouldBeRetOf(
    BackendType, string code, string functionName, T,
    string module_ = __MODULE__,
)(
    in T expected,
    in string file = __FILE__,
    in size_t line = __LINE__,
) {
    import dmd.typesem: size;
    import snakebite.backends.backend: Program;

    enum program_ = RegisterProgram!(module_, code).program;
    auto program = Program([parsedProgram(program_)]);
    auto function_ = findFunction(program.rootModules[0], functionName);
    assert(function_ !is null,
        "No function `" ~ functionName ~ "` in the guest program");

    auto returnType = function_.type.nextOf;
    assert(T.sizeof == returnType.size,
        text("`", T.stringof, "` (", T.sizeof, " bytes) does not match the ",
             "guest return type (", returnType.size, " bytes)"));

    T result;
    (new BackendType).call(function_, &result, []);
    result.shouldEqual(expected, file, line);
}

public string evaluate(
    string module_,
    BackendType,
    string declarations,
    string code,
)(
    in string file,
    in size_t line,
) {
    // Instantiating the struct runs its static constructor at startup, which
    // is how the snippet gets registered without any extra syntax in tests.
    enum snippet = Register!(module_, declarations, code).snippet;

    const native = () {
        mixin(declarations);
        return text(mixin(code));
    }();

    const guest = (new BackendType).eval(parsedFunction(snippet));
    guest.shouldEqual(native, file, line);

    return native;
}


private struct Snippet {
    string module_;
    string declarations;
    string code;
}

private struct Register(string module_, string declarations, string code) {
    enum snippet = Snippet(module_, declarations, code);

    shared static this() {
        _registered[module_] ~= snippet;
    }
}

// Every snippet each test module will evaluate, filled in before `main`.
private __gshared Snippet[][string] _registered;
// Filled in one module at a time by `parsedFunction`.
private __gshared FuncDeclaration[Snippet] _parsed;
private __gshared bool[string] _parsedModules;
private __gshared Mutex _mutex;

shared static this() {
    _mutex = new Mutex;
}

private FuncDeclaration parsedFunction(in Snippet snippet) {
    _mutex.lock;
    scope(exit) _mutex.unlock;

    if (snippet.module_ !in _parsedModules)
        parseModuleSnippets(snippet.module_);

    // The map keys by value, and `in` makes the lookup key const.
    auto found = cast(Snippet) snippet in _parsed;
    assert(found !is null, text("Snippet was not registered: ", snippet));
    return *found;
}

private void parseModuleSnippets(in string module_) {
    const snippets = _registered[module_];
    auto guestModule = parseSnippet(batchSource(snippets));
    foreach (index, snippet; snippets)
        _parsed[cast(Snippet) snippet] = findFunction(
            findStruct(guestModule, snippetStructName(index)),
            "__eval",
        );
    _parsedModules[module_] = true;
}

// Each snippet is a struct with static members so that declarations from
// different snippets cannot collide.
private string batchSource(in Snippet[] snippets) {
    string source;
    foreach (index, snippet; snippets)
        source ~= text(
            "struct ", snippetStructName(index), " {\n",
            "    static:\n",
            snippet.declarations, "\n",
            "    string __eval() {\n",
            "        import std.conv: text;\n",
            "        return text(", snippet.code, ");\n",
            "    }\n",
            "}\n",
        );
    return source;
}

private string snippetStructName(in size_t index) {
    return text("__snippet_", index);
}


// A whole guest program registered by `run`/`shouldBeRetOf`, keyed by the
// test module that declared it (unlike `Snippet`, there is no
// `declarations`/`code` split: the program is already a complete module).
private struct GuestProgram {
    string module_;
    string code;
}

private struct RegisterProgram(string module_, string code) {
    enum program = GuestProgram(module_, code);

    shared static this() {
        _registeredPrograms[module_] ~= program;
    }
}

// Every program each test module will run or call, filled in before `main`.
private __gshared GuestProgram[][string] _registeredPrograms;
// Filled in one module at a time by `parsedProgram`.
private __gshared Module[GuestProgram] _parsedPrograms;
private __gshared bool[string] _parsedProgramModules;

private Module parsedProgram(in GuestProgram program) {
    _mutex.lock;
    scope(exit) _mutex.unlock;

    if (program.module_ !in _parsedProgramModules)
        parseModulePrograms(program.module_);

    // The map keys by value, and `in` makes the lookup key const.
    auto found = cast(GuestProgram) program in _parsedPrograms;
    assert(found !is null, text("Program was not registered: ", program));
    return *found;
}

private void parseModulePrograms(in string module_) {
    import std.algorithm.iteration: map;
    import std.array: array;

    const programs = _registeredPrograms[module_];
    const sources = programs.map!(program => program.code).array;
    auto guestModules = parseSnippets(sources);
    foreach (index, program; programs)
        _parsedPrograms[cast(GuestProgram) program] = guestModules[index];
    _parsedProgramModules[module_] = true;
}
