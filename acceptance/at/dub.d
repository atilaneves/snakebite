module at.dub;

import ut.backends;
import snakebite.dependencyimage: defaultCompiler;
import std.conv: text;
import std.path: buildPath, absolutePath;
import std.process: execute, Config;
import std.string: toLower;

// Separate processes match normal sb execution. DMD retains parsed modules
// inside one process, independently of the discovery cache.
static foreach (backend; Matrix!()) {
    @("cache.normalExecutionSeesSourceEdits." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const sandbox = Sandbox();
        sandbox.writeFile("app/dub.sdl", `name "edited-app"
configuration "unittest" {
    targetType "executable"
    mainSourceFile "source/main.d"
}
`);
        sandbox.writeFile("app/source/main.d", "module main; void main() {}\n");
        const directory = sandbox.inSandboxPath("app");
        foreach (answer; [42, 42, 0]) {
            sandbox.writeFile("app/source/app.d", text(
                "module app; int answer() { return ", answer,
                "; } unittest { assert(answer() == 42); }\n"));
            const expected = answer == 42 ? 0 : 1;
            static if (is(backend == Native)) {
                execute(["dub", "build", "--compiler=" ~ defaultCompiler,
                    "--config=unittest", "--build=unittest",
                ], null, Config.none, size_t.max, directory).status.should == 0;
                execute([buildPath(directory, "edited-app")]).status.should == expected;
            } else {
                const result = execute(["bin/sb".absolutePath, "-b",
                    backend.stringof.toLower, directory,
                ]);
                result.status.should == expected;
            }
        }
    }
}

// `snakebite.project.bareSourceSet` calls `dirEntries!false(string, string,
// SpanMode, bool)` on the host, to find this very project's own `*.d`
// files, before any guest code runs. That instantiates the same mangled
// symbol inside `bin/sb` (an LDC build) that a guest program's own call to
// `dirEntries(dir, "*.d", SpanMode.depth)` needs. A resolver that reaches
// the main executable before the dependency image or an already-loaded
// shared object binds the guest call to `bin/sb`'s own copy: `dirEntries`'s
// nested closure `f` was allocated with LDC's frame layout by that native
// call, but a guest backend reads captured variables out of it with
// snakebite's own layout, so the guest sees garbage instead of the
// project's one matching file. `scanDirectory` sits outside the scanned
// project directory so this project's own `*.d` file never confuses the
// count the test asserts on.
//
// `symbolAddress` (source/snakebite/ffi/symbol.d) searches every
// already-loaded shared object before the executable, so a guest call
// prefers a genuine independent native copy - the dependency image, or a
// project's own C/C++ library - over `bin/sb`'s own instantiation. This
// project has no dependency, so no such independent copy exists anywhere:
// the *only* native code for this exact `dirEntries` instantiation is the
// one inside `bin/sb` itself. `CallSelection.buildDecision`
// (source/snakebite/backends/calls.d) never reuses that executable-only
// answer for a template instance a guest call reaches: it asks the
// resolver whether an independent copy answers - the dependency image or
// an already-loaded shared object - and keeps the guest body otherwise, so
// `f`'s closure is always read with the layout that allocated it.
static foreach (backend; Matrix!(
    Omit!(Ctfe, Because.inexpressible, "CTFE cannot run file IO"),
)) {
    @("guestDirEntriesFindsGuestFilesNotHostTemplateInstance." ~ backend.stringof)
    @Tags(backend.stringof)
    unittest {
        const sandbox = Sandbox();
        const scanDirectory = sandbox.inSandboxPath("scanned");
        sandbox.writeFile("app/source/app.d", text(`
            module app;
            import std.file: dirEntries, mkdirRecurse, rmdirRecurse, write, SpanMode;
            void main() {
                mkdirRecurse("`, scanDirectory, `");
                scope(exit) rmdirRecurse("`, scanDirectory, `");
                write("`, scanDirectory, `/foo.d", "");
                size_t count;
                foreach (entry; dirEntries("`, scanDirectory, `", "*.d", SpanMode.depth))
                    ++count;
                assert(count == 1, "expected exactly one *.d entry");
            }
        `));
        const appSource = sandbox.inSandboxPath("app/source/app.d");
        const directory = sandbox.inSandboxPath("app");
        static if (is(backend == Native))
            // DMD writes object files in its working directory, even with -run.
            const result = execute(["dmd", "-run", appSource],
                null, Config.none, size_t.max, directory);
        else
            const result = execute(["bin/sb".absolutePath, "-b",
                backend.stringof.toLower, directory,
            ]);
        if (result.status != 0)
            fail(result.output, __FILE__, __LINE__);
    }
}
