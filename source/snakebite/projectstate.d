module snakebite.projectstate;


private:


// Project state lives under the directory snakebite started in. Guest code
// runs in the directory of its project so that it sees the files it expects,
// and that must not move the state with it.
private immutable string _startDirectory;

shared static this() {
    import std.file: getcwd;
    _startDirectory = getcwd;
}


public string projectStateDirectory(in string projectDirectory) {
    import std.digest.sha: sha256Of;
    import std.digest: toHexString;
    import std.path: absolutePath, buildNormalizedPath, buildPath;

    const absolute = projectDirectory.absolutePath.buildNormalizedPath;
    return buildPath(_startDirectory, ".snakebite",
        absolute.sha256Of.toHexString.idup);
}
