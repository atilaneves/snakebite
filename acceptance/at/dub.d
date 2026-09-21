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
                    "--config=unittest", "--build=unittest"], null,
                    Config.none, size_t.max, directory).status.should == 0;
                execute([buildPath(directory, "edited-app")]).status.should == expected;
            } else {
                const result = execute(["bin/sb".absolutePath, "-b",
                    backend.stringof.toLower, directory]);
                result.status.should == expected;
            }
        }
    }
}
