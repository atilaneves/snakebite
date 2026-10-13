module snakebite.sources;


private:


public struct SourceSet {
    import snakebite.frontend.compiler: FrontendFlags;
    import snakebite.dub: DubDependencies;

    public string[] files;
    public string[] importPaths;
    public string[] stringImportPaths;
    public string[] linkerFlags;
    public FrontendFlags flags;
    public string[string] sourceOverrides;
    public string[] linkerFiles;
    public DubDependencies dependencies;
    // Where `dub test` runs the test binary; empty when the recipe sets no
    // `workingDirectory`, and for a bare directory.
    public string workingDirectory;
    // A bare directory is built as `dmd -i` builds it, which compiles a C
    // module that a D module imports. A dub recipe names its C files in
    // `sourceFiles`, and dub does not compile one that it does not name.
    public bool importedCFilesAreRoots;
}
