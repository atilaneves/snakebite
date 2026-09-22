module ut.backends.run.inlineasm;


import ut.backends;
import snakebite.frontend.compiler: parseSnippet, withCompilerLock;
import std.conv: text;
import std.file: mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path: buildPath;
import std.process: thisProcessID;


// Snakebite parses a root module as if `D_InlineAsm_X86_64` were
// undefined (see docs/adr/0012). A real x86-64 build of `bin/ut` defines
// it unconditionally (dmd's `Target._init`), so `Native` diverges by
// design. The sibling test below pins that divergence instead of
// joining this Matrix.
static foreach (backend; Matrix!(
    Omit!(Native, Because.diverges,
        "a real x86-64 build of `bin/ut` defines `D_InlineAsm_X86_64` "
        ~ "unconditionally; the sibling `Native` unittest below pins "
        ~ "the value it actually gives"),
)) {
    @("inlineasm.versionIdentifier.notDefinedForGuestCode." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        false.shouldBeRetOf!(backend, q{
            version (D_InlineAsm_X86_64) enum hasAsm = true;
            else enum hasAsm = false;
            bool result() { return hasAsm; }
        }, "result");
    }
}

// Sibling pinning the divergence above: the same snippet, compiled as real
// D when `bin/ut` itself is built, sees `D_InlineAsm_X86_64` defined (dmd's
// `Target._init` adds it unconditionally on an x86-64 host), unlike every
// backend above.
@("inlineasm.versionIdentifier.definedNatively.Native")
@Tags(Native.stringof)
unittest {
    true.shouldBeRetOf!(Native, q{
        version (D_InlineAsm_X86_64) enum hasAsm = true;
        else enum hasAsm = false;
        bool result() { return hasAsm; }
    }, "result");
}

// The version gate must reach a `version (D_InlineAsm_X86_64)` inside a
// function body, not only at module scope: dmd represents it there as a
// `ConditionalStatement`, reached by walking into `FuncDeclaration.fbody`,
// which is a different code path in `InlineAsmVersionGate` than the
// `ConditionalDeclaration` a module-scope `version` block builds. `Native`
// takes the `return 1` branch (see the sibling below); the gate makes
// every backend take the `else` branch instead, so `Native` diverges by
// design.
static foreach (backend; Matrix!(
    Omit!(Native, Because.diverges,
        "a real x86-64 build of `bin/ut` sees `D_InlineAsm_X86_64` "
        ~ "defined and takes the `return 1` branch; the sibling "
        ~ "`Native` unittest below pins that value"),
)) {
    @("inlineasm.versionIdentifier.functionBody." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        2.shouldBeRetOf!(backend, q{
            int f() {
                version (D_InlineAsm_X86_64) return 1;
                else return 2;
            }
        }, "f");
    }
}

// Sibling pinning the divergence above: compiled natively, the same
// snippet sees `D_InlineAsm_X86_64` defined and takes the `return 1`
// branch, unlike every backend above.
@("inlineasm.versionIdentifier.functionBody.Native")
@Tags(Native.stringof)
unittest {
    1.shouldBeRetOf!(Native, q{
        int f() {
            version (D_InlineAsm_X86_64) return 1;
            else return 2;
        }
    }, "f");
}

// The gate must also reach a `version (D_InlineAsm_X86_64)` inside a
// template's body, instantiated or not: `TemplateDeclaration.members`
// holds the syntax tree directly, and the gate walks it right after
// parsing, before any instantiation exists to walk instead. `Native`
// takes the `return 1` branch (see the sibling below), so it diverges by
// design the same way the function-body pair above does.
static foreach (backend; Matrix!(
    Omit!(Native, Because.diverges,
        "a real x86-64 build of `bin/ut` sees `D_InlineAsm_X86_64` "
        ~ "defined and takes the `return 1` branch; the sibling "
        ~ "`Native` unittest below pins that value"),
)) {
    @("inlineasm.versionIdentifier.templateBody." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        2.shouldBeRetOf!(backend, q{
            int f(T)() {
                version (D_InlineAsm_X86_64) return 1;
                else return 2;
            }
            int g() { return f!int(); }
        }, "g");
    }
}

// Sibling pinning the divergence above: compiled natively, the template
// body sees `D_InlineAsm_X86_64` defined and takes the `return 1` branch,
// unlike every backend above.
@("inlineasm.versionIdentifier.templateBody.Native")
@Tags(Native.stringof)
unittest {
    1.shouldBeRetOf!(Native, q{
        int f(T)() {
            version (D_InlineAsm_X86_64) return 1;
            else return 2;
        }
        int g() { return f!int(); }
    }, "g");
}

// A root-owned function with an unguarded `asm` block must not reach any
// backend (see docs/adr/0012). The check runs inside `driveSharedSemantic`,
// which every load path shares - `loadProject`, the REPL, and
// `parseSnippet` itself - before any backend is chosen, so `parseSnippet`
// alone already pins the diagnostic; no backend runs here for a tag to
// name.
@("inlineasm.loadDiagnostic.unguardedAsmFailsLoad")
unittest {
    parseSnippet(q{
        void asmFunction() {
            asm { nop; }
        }
        unittest {
            asmFunction();
        }
    }).shouldThrow.msg.withoutSnippetCounter.should ==
        "inline assembler is not supported in `snippet_N.asmFunction`: "
        ~ "guard it with `version (D_InlineAsm_X86_64)`, which "
        ~ "snakebite does not define";
}

// A root-owned function template's `TemplateInstance` is reached twice by
// `InlineAsmCollector`: once through the module's own `members` (dmd's
// `appendToModuleMember` puts every instantiated template there), and
// again through the `ScopeExp` the call site builds inside the calling
// function's body (`SemanticTimeTransitiveVisitor.visit(ScopeExp)` walks
// into the `TemplateInstance` it holds). Calling `asmFunction!int()` from
// inside a `unittest` block's body takes both paths at once. Without the
// `_visited` guard keyed by `FuncDeclaration`, that would report the same
// `asm` block twice, joined by a newline (`diagnosticMessage`). The exact
// equality below pins a single line. This is the same load-time check as
// above, reached through `parseSnippet` alone, so one test is enough.
@("inlineasm.loadDiagnostic.templateInstanceReachedTwiceReportsOnce")
unittest {
    parseSnippet(q{
        void asmFunction(T)() {
            asm { nop; }
        }
        unittest {
            asmFunction!int();
        }
    }).shouldThrow.msg.withoutSnippetCounter.should ==
        "inline assembler is not supported in "
        ~ "`snippet_N.asmFunction!int.asmFunction`: guard it with "
        ~ "`version (D_InlineAsm_X86_64)`, which snakebite does not "
        ~ "define";
}

// `parseSnippet` names each root module `snippet_<N>`. One counter gives
// out `N` for every `parseSnippet` call in the whole `bin/ut` process, not
// only this file, and unit-threaded runs tests in parallel threads. So `N`
// is not stable across runs. This helper replaces it with a fixed
// placeholder, so the test can compare dmd's whole message instead of a
// few separate substrings.
private string withoutSnippetCounter(in string message) {
    import std.regex: regex, replaceFirst;

    return message.replaceFirst(regex(`snippet_\d+`), "snippet_N");
}

// `mixin WithAsm;` instantiates a `mixin template` as a `TemplateMixin`,
// not a plain `TemplateInstance`: `TemplateMixin : TemplateInstance` but
// overrides `accept` with its own `v.visit(this)`, so it dispatches to a
// dedicated `Visitor.visit(TemplateMixin)` overload instead of
// `InlineAsmCollector.visit(TemplateInstance)`.
// `SemanticTimeTransitiveVisitor`'s own default `visit(TemplateMixin)`
// walks only the mixin's type and template arguments, never its
// instantiated `members`, so a root-owned function inside a root-owned
// mixin template's own body was not walked and its unguarded `asm` block
// escaped the load diagnostic. Unlike the string-mixin gap above, this is
// not a documented, accepted gap: the mixin template's syntax tree is
// available up front, so the collector must walk it. This is the same
// load-time check pinned above, reached through `parseSnippet` alone, so
// one test is enough.
@("inlineasm.loadDiagnostic.templateMixinFailsLoad")
unittest {
    parseSnippet(q{
        mixin template WithAsm() {
            void unsupported() { asm { nop; } }
        }
        mixin WithAsm;
        unittest {
            unsupported();
        }
    }).shouldThrow.msg.withoutSnippetCounter.should ==
        "inline assembler is not supported in "
        ~ "`snippet_N.WithAsm!().unsupported`: guard it with "
        ~ "`version (D_InlineAsm_X86_64)`, which snakebite does not "
        ~ "define";
}

// Known, accepted gap (see docs/adr/0012): a `version (D_InlineAsm_X86_64)`
// inside a string mixin is not part of the syntax tree the gate walks.
// So the mixed-in `asm` branch compiles in. The load-time scan for an
// unguarded `asm` block still catches it: it does not care how a
// root-owned function came to have one. This is the same load-time check
// pinned above, reached through `parseSnippet` alone, so one test is
// enough.
@("inlineasm.versionIdentifier.mixinGapFailsLoad")
unittest {
    parseSnippet(q{
        mixin(`
            version (D_InlineAsm_X86_64) {
                int f() { asm { nop; } return 1; }
            } else {
                int f() { return 2; }
            }
        `);
        unittest {
            f();
        }
    }).shouldThrow.msg.withoutSnippetCounter.should ==
        "inline assembler is not supported in `snippet_N.f`: guard it "
        ~ "with `version (D_InlineAsm_X86_64)`, which snakebite does "
        ~ "not define";
}

// `InlineAsmCollector` had no visited set. `SemanticTimeTransitiveVisitor`'s
// own traversal (`dmd.visitor.transitive`) walks an `AliasDeclaration`'s
// `aliassym` unconditionally, and a local alias to its own enclosing
// function resolves `aliassym` right back to that function's own
// `FuncDeclaration`; the collector's `visit(FuncDeclaration)` walked into
// `fbody` again on every re-entry, an unbounded recursion that overflowed
// the stack during load, well before any backend ran the guest code. This
// snippet has no `asm` block anywhere and must load and run like any other
// valid D program, on every backend and natively.
static foreach (backend; Matrix!()) {
    @("inlineasm.loadDiagnostic.selfAliasDoesNotOverflowTheStack." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        1.shouldBeRetOf!(backend, q{
            void f() { alias self = f; }
            int result() { f(); return 1; }
        }, "result");
    }
}

// `driveSharedSemantic`'s own comment says `modules` is the root-owned set
// for every load path, but the REPL builds a wider one:
// `Program(interpretedModules(module_, importPaths))` in
// `snakebite.repl` also root-owns a project module a cell only reaches
// through `import`, resolved under an import path (`parseSnippet`'s own
// `rootImportPaths` here). dmd parses that module lazily, during
// `importAll`, so an unguarded `asm` block in it must still be scanned and
// reported at load time - the same failure `unguardedAsmFailsLoad` above
// pins for a snippet's own module, but reached through an import instead.
// This is still `parseSnippet` alone, so one test is enough.
@("inlineasm.loadDiagnostic.projectImportFailsLoad")
unittest {
    import dmd.frontend: addImport;

    const moduleName = "inlineasm_project_import";
    const directory = buildPath(
        tempDir,
        text("inlineasm_project_import_", thisProcessID),
    );
    mkdirRecurse(directory);
    scope(exit) rmdirRecurse(directory);

    write(
        buildPath(directory, moduleName ~ ".d"),
        "module " ~ moduleName ~ ";\n"
        ~ "void asmFunction() { asm { nop; } }\n",
    );

    // dmd looks up an import under `global.path`, a process-global
    // list `rootImportPaths` below does not itself populate; add it
    // the same way `snakebite.repl.Repl.this()` does for a real
    // session, but under the frontend's own lock. `Repl.this()` does
    // not take that lock around its own `addImport` call - a separate,
    // pre-existing thread-safety gap, not this finding.
    withCompilerLock({ addImport(directory); });

    parseSnippet(
        "import " ~ moduleName ~ ";",
        [directory],
    ).shouldThrowWithMessage(
        text(
            "inline assembler is not supported in `", moduleName,
            ".asmFunction`: guard it with "
            ~ "`version (D_InlineAsm_X86_64)`, which snakebite does "
            ~ "not define",
        ),
    );
}
