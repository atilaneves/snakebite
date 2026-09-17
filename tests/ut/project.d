module ut.project;


import snakebite.project: projectStateDirectory, sourceSet;
import std.algorithm.searching: any, endsWith;
import std.digest.sha: sha256Of;
import std.digest: toHexString;
import std.file: getcwd;
import std.path: absolutePath, buildNormalizedPath, buildPath, dirName;
import ut;


@("stateDirectoryIsCwdScopedAndProjectPartitioned")
unittest {
    const cwd = getcwd;
    const firstProject = "projects/first".absolutePath.buildNormalizedPath;
    const secondProject = "projects/second".absolutePath.buildNormalizedPath;
    const first = projectStateDirectory("projects/first");
    const second = projectStateDirectory("projects/second");

    first.should == buildPath(cwd, ".snakebite",
        firstProject.sha256Of.toHexString.idup);
    second.should == buildPath(cwd, ".snakebite",
        secondProject.sha256Of.toHexString.idup);
    first.should.not == second;
}


@("sourceSet.loadsDubPackageSettings")
unittest {
    const directory = buildPath(__FILE__.dirName,
        "../fixtures/dub-package-settings");
    const sources = sourceSet(directory, null, null);

    sources.files.any!(path => path.endsWith("tests/main.d")).should == true;
    sources.importPaths.any!(path => path.endsWith("source/")).should == true;
}
