module ut.backends.run.inlineasm;


import ut.backends;
import snakebite.frontend.compiler:
    FrontendFlags, newInFrontend, parseRootModules, parseSnippet;
import std.conv: text;
import std.file: mkdirRecurse, rmdirRecurse, tempDir, write;
import std.path: buildPath;
import std.process: thisProcessID;
import snakebite.dependencyimage: Optimise;
import snakebite.execution: prepareProject;


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
    // session.
    newInFrontend!addImport(directory);

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


// Guest code that refers to C `setjmp`/`longjmp` is a stated exception,
// like inline assembler (see docs/adr/0014). The check runs in the same
// load-time walk as the `asm` check above, before any backend is chosen,
// so `parseSnippet` alone pins the diagnostic for every backend.
private enum jumpError(string name) =
    "`" ~ name ~ "` is not supported in guest code: a backend cannot "
    ~ "jump back to a stack frame it has already left";

@("setjmp.loadDiagnostic.directCallFailsLoad")
unittest {
    parseSnippet(q{
        import core.sys.posix.setjmp: jmp_buf, longjmp, setjmp;
        int jumper() {
            jmp_buf buffer;
            if (setjmp(buffer) == 0)
                longjmp(buffer, 1);
            return 0;
        }
    }).shouldThrowWithMessage(
        jumpError!"setjmp" ~ "\n" ~ jumpError!"longjmp",
    );
}

@("setjmp.loadDiagnostic.functionPointerFailsLoad")
unittest {
    parseSnippet(q{
        import core.sys.posix.setjmp: jmp_buf, longjmp;
        void jumper(ref jmp_buf buffer) {
            auto pointer = &longjmp;
            pointer(buffer, 1);
        }
    }).shouldThrowWithMessage(jumpError!"longjmp");
}

// A function pointer stored at module scope is called from any function
// later, so the initializer itself is the use.
@("setjmp.loadDiagnostic.moduleScopeInitializerFailsLoad")
unittest {
    parseSnippet(q{
        import core.sys.posix.setjmp: jmp_buf, longjmp;
        alias Jump = extern(C) void function(ref jmp_buf, int) nothrow @nogc;
        __gshared Jump jump = &longjmp;
        void jumper(ref jmp_buf buffer) { jump(buffer, 1); }
    }).shouldThrowWithMessage(jumpError!"longjmp");
}

// `sigsetjmp` is `__sigsetjmp` in glibc; the error names what the guest
// wrote.
@("setjmp.loadDiagnostic.sigsetjmpNamesTheLibcFunction")
unittest {
    parseSnippet(q{
        import core.sys.posix.setjmp: sigjmp_buf, sigsetjmp;
        int jumper(ref sigjmp_buf buffer) { return sigsetjmp(buffer, 1); }
    }).shouldThrowWithMessage(jumpError!"sigsetjmp");
}

// `pragma(mangle)` decides the name the linker sees, so the function
// below is `longjmp` whatever it is called in D.
@("setjmp.loadDiagnostic.mangledNameFailsLoad")
unittest {
    parseSnippet(q{
        import core.sys.posix.setjmp: jmp_buf;
        pragma(mangle, "longjmp") extern(C) void leave(ref jmp_buf, int);
        void jumper(ref jmp_buf buffer) { leave(buffer, 1); }
    }).shouldThrowWithMessage(jumpError!"longjmp");
}

// A template body is walked once for each instance, at one location.
@("setjmp.loadDiagnostic.templateInstancesReportOnce")
unittest {
    parseSnippet(q{
        import core.sys.posix.setjmp: jmp_buf, longjmp;
        void jumper(T)(ref jmp_buf buffer, T value) { longjmp(buffer, 1); }
        unittest {
            jmp_buf buffer;
            jumper(buffer, 1);
            jumper(buffer, "a");
        }
    }).shouldThrowWithMessage(jumpError!"longjmp");
}

// The guest defines a function that is not the libc one, so there is
// no saved stack context to jump back to.
@("setjmp.loadDiagnostic.guestDefinitionWithTheSameNameLoads")
unittest {
    parseSnippet(q{
        extern(C) int siglongjmp(int x) { return x + 1; }
        int result() { return siglongjmp(1); }
    });
}

// Only the C linkage name is the libc function.
@("setjmp.loadDiagnostic.dLinkageNameLoads")
unittest {
    parseSnippet(q{
        int setjmp(int x);
        int result() { return setjmp(1); }
    });
}

// A reported error names the guest file, line and column of the use.
@("setjmp.loadDiagnostic.reportsTheLocationOfTheUse")
unittest {
    const directory = buildPath(
        tempDir, text("setjmp_location_", thisProcessID),
    );
    mkdirRecurse(directory);
    scope(exit) rmdirRecurse(directory);
    const path = buildPath(directory, "jumper.d");
    write(
        path,
        "module jumper;\n"
        ~ "import core.sys.posix.setjmp: jmp_buf, longjmp;\n"
        ~ "void jumper(ref jmp_buf buffer) {\n"
        ~ "    longjmp(buffer, 1);\n"
        ~ "}\n",
    );

    parseRootModules([path], [], FrontendFlags())
        .shouldThrowWithMessage(
            text(path, "(4,5): ", jumpError!"longjmp"),
        );
}


// LDC's LLVM inline IR and inline assembler are inline assembler for a
// backend: nothing runs them (docs/adr/0012). Only code that LDC compiled
// into the host or the dependency image can use them. Like an `asm` block,
// a call in root-owned code fails the load and names the construct.
version (LDC) {
    @("inlineasm.loadDiagnostic.llvmInlineIrFailsLoad")
    unittest {
        parseSnippet(q{
            import ldc.llvmasm: __ir;

            int add(int a, int b) {
                return __ir!(`%r = add i32 %0, %1
                              ret i32 %r`, int)(a, b);
            }
            unittest {
                add(1, 2);
            }
        }).shouldThrow.msg.withoutSnippetCounter.should ==
            "LLVM inline IR (`pragma(LDC_inline_ir)`) is not supported in "
            ~ "`snippet_N.add`: no backend runs it. Only code that LDC "
            ~ "compiled into the host or the dependency image can use it";
    }

    @("inlineasm.loadDiagnostic.llvmInlineAsmFailsLoad")
    unittest {
        parseSnippet(q{
            import ldc.llvmasm: __asm;

            void pause() {
                __asm("pause", "");
            }
            unittest {
                pause();
            }
        }).shouldThrow.msg.withoutSnippetCounter.should ==
            "inline assembler (`pragma(LDC_inline_asm)`) is not supported in "
            ~ "`snippet_N.pause`: no backend runs it. Only code that LDC "
            ~ "compiled into the host or the dependency image can use it";
    }

    // The instance of a dependency template that root code instantiates is
    // part of the root program, and no image holds a copy that LDC compiled.
    @("inlineasm.loadDiagnostic.rootInstanceOfIrTemplateFailsLoad")
    unittest {
        const message = parseSnippet(q{
            import core.simd: float4, loadUnaligned;

            float4 load(const float4* pointer) {
                return loadUnaligned(pointer);
            }
        }).shouldThrow.msg.withoutSnippetCounter;
        // Both overloads of `loadUnaligned` have an instance.
        ("LLVM inline IR (`pragma(LDC_inline_ir)`) is not supported in "
            ~ "`ldc.simd.loadUnaligned!(__vector(float[4])).loadUnaligned`: "
            ~ "no backend runs it").should.be in message;
    }

    // Three template instances deep: nothing but the instance at the
    // bottom holds the inline IR. With no image to compile the instances,
    // the root program runs all of them, so the load names the bottom one.
    @("inlineasm.loadDiagnostic.irInstanceThreeLevelsDeepFailsLoadWithoutImage")
    unittest {
        const directory = buildPath(
            tempDir, text("ir_chain_", thisProcessID),
        );
        scope(exit) rmdirRecurse(directory);
        writeIrChainProject(directory, "ir_chain_depth");

        const noNativeDependencies = false;
        const message = prepareProject(
            buildPath(directory, "app"),
            [buildPath(directory, "deps")],
            null,
            noNativeDependencies,
            optimise: Optimise.no,
        ).shouldThrow.msg;
        ("LLVM inline IR (`pragma(LDC_inline_ir)`) is not supported in "
            ~ "`ir_chain_depth.innermost!int.innermost`: no backend runs it")
            .should.be in message;
    }

    // The same program loads where a dependency image holds the instances:
    // LDC compiles them there.
    @("inlineasm.loadDiagnostic.irInstanceLoadsWhenAnImageHoldsIt")
    unittest {
        const directory = buildPath(
            tempDir, text("ir_chain_image_", thisProcessID),
        );
        scope(exit) rmdirRecurse(directory);
        writeIrChainProject(directory, "ir_chain_image");

        parseRootModules(
            [buildPath(directory, "app", "ir_chain_image_root.d")],
            [buildPath(directory, "deps")],
            FrontendFlags(),
            dependencyImage: true,
        );
    }

    // The modules are named for the test: the frontend keeps a module of a
    // name for the life of the process.
    private void writeIrChainProject(
        in string directory,
        in string name,
        in bool madeByTheDependency = false,
    ) {
        mkdirRecurse(buildPath(directory, "deps"));
        mkdirRecurse(buildPath(directory, "app"));
        write(buildPath(directory, "deps", name ~ ".d"),
            "module " ~ name ~ ";\n" ~ q{
            import ldc.llvmasm: __ir;

            int innermost(T)(T a, T b) {
                return __ir!(`%r = add i32 %0, %1
                              ret i32 %r`, int)(a, b);
            }
            int middle(T)(T a, T b) { return innermost(a, b); }
            int outer(T)(T a, T b) { return middle(a, b); }
        } ~ (madeByTheDependency ? q{
            alias madeOuter = outer!int;
            alias madeMiddle = middle!int;
            alias madeInnermost = innermost!int;
        } : ""));
        write(buildPath(directory, "app", name ~ "_root.d"),
            "module " ~ name ~ "_root;\nimport " ~ name ~ ": outer;\n" ~ q{
            int sum() { return outer(1, 2); }
            void main() {}
        });
    }
}
