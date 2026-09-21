module ut.backends.run.inlineasm;


import ut.backends;
import snakebite.frontend.compiler: parseSnippet, withCompilerLock;
import std.conv: text;
import std.file: mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path: buildPath;
import std.process: thisProcessID;


// The D language specification defines `D_InlineAsm_X86_64` to mean
// "inline assembler for X86-64 is implemented". Snakebite does not
// implement DMD-style inline assembler (issue #415), so it parses a root
// module as if this identifier were undefined
// (`snakebite.frontend.inlineasm.disableInlineAsmVersion`), unlike a real
// x86-64 build of `bin/ut` itself, which defines it unconditionally (dmd's
// `Target._init`). `Native` is the diverging case, pinned in the sibling
// test below instead of joining this Matrix: `Omit!(Native, ...)` is
// never allowed, because there is no native oracle here for these three
// backends to agree with - Native disagrees with all of them on purpose.
static foreach (backend; Backends) {
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
// `ConditionalDeclaration` a module-scope `version` block builds.
static foreach (backend; Backends) {
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

// The gate must also reach a `version (D_InlineAsm_X86_64)` inside a
// template's body, instantiated or not: `TemplateDeclaration.members`
// holds the syntax tree directly, and the gate walks it right after
// parsing, before any instantiation exists to walk instead.
static foreach (backend; Backends) {
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

// A root-owned function that still has an unguarded `asm` block must not
// reach any backend: `dmd.iasm.asmSemantic` (the shim `dmd:frontend` needs
// because the dub package does not ship `dmd.iasm`) sets
// `FuncDeclaration.hasInlineAsm` instead of erroring, on purpose, so that
// druntime modules with `asm` still pass semantic analysis. The walk added
// for issue #415 turns that flag into one load-time diagnostic, naming the
// function and the guard that would have made this compile out, the same
// way `version (D_InlineAsm_X86_64)` compiles it out under a compiler that
// does not implement inline assembler either (e.g. GDC on an unsupported
// target). This check lives in the frontend's single shared semantic path
// (`driveSharedSemantic`), so every load path - `loadProject`, the
// snippet/REPL path, and `bin/ut`'s own snippet parsing - fails the same
// way; one test per backend is enough to show every backend's load path
// reaches it, and `Native` never can, since a real x86-64 build implements
// inline assembler and `asmFunction` simply runs.
static foreach (backend; Backends) {
    @("inlineasm.loadDiagnostic.unguardedAsmFailsLoad." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const thrown = parseSnippet(q{
            void asmFunction() {
                asm { nop; }
            }
            unittest {
                asmFunction();
            }
        }).shouldThrow;

        "inline assembler is not supported in".should.be in thrown.msg;
        "asmFunction".should.be in thrown.msg;
        "version (D_InlineAsm_X86_64)".should.be in thrown.msg;
    }
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
// available up front, so the collector must walk it.
static foreach (backend; Backends) {
    @("inlineasm.loadDiagnostic.templateMixinFailsLoad." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const thrown = parseSnippet(q{
            mixin template WithAsm() {
                void unsupported() { asm { nop; } }
            }
            mixin WithAsm;
            unittest {
                unsupported();
            }
        }).shouldThrow;

        "inline assembler is not supported in".should.be in thrown.msg;
    }
}

// Known, accepted gap (docs/adr/0012): a `version (D_InlineAsm_X86_64)`
// written inside a string mixin is not part of the syntax tree
// `disableInlineAsmVersion` walks, because the mixin's own source text is
// not parsed until dmd expands it during semantic analysis, after the
// gate has already run. The fresh `VersionCondition` that expansion
// builds finds no cached value and falls back to `global.versionids`,
// which still carries the identifier (dependency modules keep it), so the
// mixed-in `asm` branch compiles in. Root ownership still catches it: the
// load-time scan for an unguarded `asm` block does not distinguish how a
// root-owned function came to have one, so it fails the load with the
// same diagnostic as an `asm` block written directly.
static foreach (backend; Backends) {
    @("inlineasm.versionIdentifier.mixinGapFailsLoad." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const thrown = parseSnippet(q{
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
        }).shouldThrow;

        "inline assembler is not supported in".should.be in thrown.msg;
    }
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
static foreach (backend; TestBackends) {
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
static foreach (backend; Backends) {
    @("inlineasm.loadDiagnostic.projectImportFailsLoad." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        import dmd.frontend: addImport;

        // dmd registers a parsed module process-globally by its module
        // identifier, not by file path, so the module name must be unique
        // to this backend: reusing one across the three variants below
        // would resolve later ones to whichever variant loaded it first.
        const moduleName = text("inlineasm_project_import_", backend.stringof);
        const directory = buildPath(
            tempDir,
            text("inlineasm_project_import_", backend.stringof, "_", thisProcessID),
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

        const thrown = parseSnippet(
            "import " ~ moduleName ~ ";",
            [directory],
        ).shouldThrow;

        "inline assembler is not supported in".should.be in thrown.msg;
    }
}
