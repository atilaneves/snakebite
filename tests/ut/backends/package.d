module ut.backends;

public import ut;
public import snakebite.backends.bytecode: Bytecode;
public import snakebite.backends.ctfe: Ctfe;
public import snakebite.backends.interpreter: Interpreter;
public import std.meta: AliasSeq;

import core.sync.mutex: Mutex;
import dmd.dmodule: Module;
import dmd.func: FuncDeclaration;
import snakebite.backends.backend: Program, run;
import snakebite.frontend.compiler: parseSnippet, parseSnippets;
import snakebite.frontend.dmd.functions: findFunction, findStruct;
import std.conv: text;
import std.meta: Filter, staticIndexOf;
import std.traits: isInstanceOf;


// The native oracle, as a matrix entry. Not a snakebite backend: `code` is
// mixed in and compiled by dmd when `bin/ut` itself is built, so this runs
// regular compiled D and is the expectation every real backend must agree
// with. It sits in the matrix so the oracle runs as its own named, tagged
// test - a snippet that is wrong natively then fails as `Native`, instead
// of being recomputed inside every backend's test and reported against
// whichever backend happened to run first.
public struct Native {}

// Every implementation a guest program can run on in a test: the native
// oracle plus every real backend.
public alias TestBackends = AliasSeq!(Native, Backends);

// Why a backend is missing from a test's `Matrix!(...)`. Every `Omit!(...)`
// names one of these so the omission is documentation, not silence.
public enum Because {
    inexpressible, // the backend can never run the construct (note required)
    diverges,      // pinned in a sibling test that asserts the actual
                   // behaviour (note required)
    unconfirmed,   // never tried, or deliberately not implemented yet
                   // (note optional)
}

// Removes `B` from a test's `Matrix!(...)`, with a reason. `B` must be one of
// `Backends`, otherwise it is a typo since it could never have been in the
// matrix to begin with.
public struct Omit(B, Because why, string note = "") {
    static assert(staticIndexOf!(B, TestBackends) != -1,
        "Omit!(" ~ B.stringof ~ ", ...): `" ~ B.stringof ~
        "` is not in `TestBackends` - typo?");
    // The oracle states what the snippet means; a backend is only ever
    // right or wrong relative to it. A test that omitted it would assert
    // an expectation nothing independently checks, so every snippet a
    // test writes must run natively.
    static assert(!is(B == Native),
        "Omit!(Native, ...): the native oracle is never omitted - every " ~
        "test snippet must run as compiled D");
    static assert(note.length > 0 || why == Because.unconfirmed,
        "Omit!(" ~ B.stringof ~ ", Because." ~ text(why) ~
        ", ...): a non-empty `note` is required for this reason");

    public alias Backend = B;
    public enum reason = why;
    public enum note_ = note;
}

public alias BytecodeUnconfirmed = Omit!(Bytecode, Because.unconfirmed);

// The backends a test runs on: `TestBackends` minus every `Omit!(...)`.
// Usable directly as `static foreach (backend; Matrix!(...))`.
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

    public alias Matrix = Filter!(notOmitted, TestBackends);
}


// An `Interpreter` whose program owns exactly `module_`, for tests that
// call one parsed guest function directly rather than running a whole
// program.
public Interpreter interpreter(Module module_) {
    return new Interpreter(Program([module_]));
}


// Renders one expression on one matrix entry and returns the result, for
// the test to assert on: `eval!(backend, "2 + 3").should == "5"`.
//
// On `Native` the expression is regular compiled D, mixed in when `bin/ut`
// itself is built. On a backend it is parsed as a guest snippet, wrapped in
// a `string`-returning function that renders the value in the guest, and
// handed to that backend. Neither arm knows about the other: each returns
// what it computed, so a disagreement fails as whichever entry was wrong.
//
// The optional middle argument is `declarations` in scope for `code`.
// Natively they nest in the delegate below; in the guest they are static
// members of the snippet's struct. dmd constant-folds literal-only
// expressions during semantic analysis, so a test that wants a backend to
// do the arithmetic itself keeps an operand behind a function declared
// there. One template rather than a two- and a three-argument overload:
// with `module_` defaulted, `eval!(backend, a, b)` would match both.
public string eval(
    BackendType,
    string first,
    string second = null,
    string module_ = __MODULE__,
)(
    in string file = __FILE__,
    in size_t line = __LINE__,
) {
    enum declarations = second is null ? "" : first;
    enum code = second is null ? first : second;

    return evaluate!(module_, BackendType, declarations, code)(file, line);
}

// UFCS assertion: `42.shouldBeStatusOf!(backend, code)` parses `code` as a
// whole guest program, runs it on the backend the way compiled D would run
// it, and checks the exit status against `expected`.
//
// `code` is registered under the caller's module (`__MODULE__`, resolved at
// the call site as a template default, the same trick `__FILE__`/`__LINE__`
// already rely on below) the same way `eval` snippets register through
// `SnippetTests`. The first `shouldBeStatusOf`/`shouldBeRetOf` call from a
// given test module parses every program that module registered in one
// batch, so dmd's per-batch setup cost is paid once per module, not once
// per test.
public void shouldBeStatusOf(
    BackendType, string code, string module_ = __MODULE__,
)(
    in int expected,
    in string file = __FILE__,
    in size_t line = __LINE__,
) {
    static if (is(BackendType == Native))
        nativeMainStatus!code.shouldEqual(expected, file, line);
    else {
        enum program_ = RegisterProgram!(module_, code).program;
        auto program = Program([parsedProgram(program_)]);
        asTestFailure(run(new BackendType(program), program), file, line)
            .shouldEqual(expected, file, line);
    }
}

// `main`'s exit status, run natively, mirroring the backend-side semantics
// documented on `snakebite.backends.backend.run`: `void main` is status 0,
// an escaping `Throwable` is status 1, and no `main` at all is status 0.
//
// `code` is mixed into a struct, the same isolation `batchSource` gives the
// guest side, so `hasMember` only ever finds a `main` `code` itself declared
// - an unqualified lookup would instead walk out to this module's public
// imports and could silently resolve to an unrelated `main`.
private int nativeMainStatus(string code)() {
    struct Guest {
        static:
        mixin(code);
    }

    static if (!__traits(hasMember, Guest, "main"))
        return 0;
    else {
        static assert(__traits(compiles, Guest.main()),
            "nativeMainStatus only supports a zero-argument main");

        try {
            static if (is(typeof(Guest.main()) == void)) {
                Guest.main();
                return 0;
            } else
                return Guest.main();
        } catch (Throwable) {
            return 1;
        }
    }
}

// UFCS assertion: `42.shouldBeRetOf!(backend, code, "answer")` invokes one
// guest function through the backend's `call` and checks its result against
// `expected`, whose type states the guest function's return type. Further
// template arguments are passed to that guest function. The guest's actual
// return type must match it in size, so a lying test fails loudly instead of
// reading garbage bytes.
//
// `code` is registered and batch-parsed the same way `shouldBeStatusOf`'s
// is; see there.
public template shouldBeRetOf(
    BackendType, string code, string functionName, Args...,
) {
    public void shouldBeRetOf(T)(
        in T expected,
        in string file = __FILE__,
        in size_t line = __LINE__,
    ) {
        import dmd.typesem: nextOf, size;

        enum call = callExpression!(functionName, Args);

        static if (is(BackendType == Native)) {
            const native = () {
                mixin(code);
                return mixin(call);
            }();
            native.shouldEqual(expected, file, line);
        } else {
            enum entryPoint = "__snakebite_test_entry";
            enum programCode = Args.length == 0
                ? code ~ "\n"
                    ~ "auto " ~ entryPoint ~ "() { return " ~ call
                    ~ "; }\n"
                : "auto " ~ entryPoint ~ "() {\n"
                    ~ code ~ "\nreturn " ~ call ~ ";\n}\n";
            enum program_ = RegisterProgram!(__MODULE__, programCode).program;
            auto program = Program([parsedProgram(program_)]);
            auto function_ = findFunction(program.rootModules[0], entryPoint);
            if (function_ is null)
                throw new UnitTestException(
                    text("No function `", entryPoint,
                        "` in the guest program"),
                    file, line,
                );

            // The expectation's own type states what the guest returns, and
            // `call` writes that many bytes into `&result`, so a mismatch
            // would scribble past it or read bytes the guest never wrote.
            // Caught here, naming both types, rather than as a corrupt-looking
            // value later.
            auto returnType = function_.type.nextOf;
            if (T.sizeof != returnType.size)
                throw new UnitTestException(
                    text("`", functionName, "` returns `",
                        returnType.toString,
                        "` (", returnType.size,
                        " bytes), but the expected value",
                        " is `", T.stringof, "` (", T.sizeof, " bytes)"),
                    file, line,
                );

            T result;
            asTestFailure(
                (new BackendType(program)).call(function_, &result, []),
                file, line,
            );
            result.shouldEqual(expected, file, line);
        }
    }
}

private string callExpression(string functionName, Args...)() {
    string result = functionName ~ "(";
    foreach (index, argument; Args) {
        if (index != 0)
            result ~= ", ";
        result ~= argument.stringof;
    }
    return result ~ ")";
}

// Reports a backend's own failure as the test failure it is, at the test's
// own file and line.
//
// unit-threaded prints a full stack trace for any throwable that is not a
// `UnitTestException`. For a backend refusing a guest construct, every
// frame in that trace is the backend's own visitor recursion, which says
// nothing the message does not already say and buries it. The refusal is a
// result about the guest program, not a crash in the host.
//
// Only an `Exception` is converted. An `Error` means the host itself is
// broken, and there the trace is the whole point, so it propagates
// untouched.
private T asTestFailure(T)(
    lazy T expression,
    in string file,
    in size_t line,
) {
    import std.string: strip;

    try
        return expression;
    catch (Exception exception)
        // dmd renders a statement with its trailing newline, so a message
        // quoting one would otherwise break the failure across lines.
        throw new UnitTestException(exception.msg.strip, file, line);
}

private string evaluate(
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

    // Each matrix entry renders the snippet its own way and hands the result
    // straight back for the test to assert on, so a wrong expectation fails
    // as the entry that produced it. The native oracle is one such entry
    // rather than an extra comparison every backend re-runs.
    static if (is(BackendType == Native)) {
        mixin(declarations);
        return text(mixin(code));
    } else {
        auto function_ = parsedFunction(snippet);
        auto program = Program([function_.getModule]);
        return asTestFailure(
            (new BackendType(program)).eval(function_), file, line);
    }
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
