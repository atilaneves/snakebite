module snakebite.dependencypreparation;


private:


// Collects image data from a live program without resetting the frontend.
// `program` runs at most once, only when cache validation needs image source.
// For startup without a live program, use `prepareStartupDependencies`.
public const(imported!"snakebite.dependencyimage".DependencyImage)* prepareDependencies(
    in string directory,
    in imported!"snakebite.project".SourceSet sources,
    scope imported!"snakebite.backends".Program delegate() program,
    in imported!"snakebite.dependencyimage".Optimise optimise
        = imported!"snakebite.dependencyimage".Optimise.yes,
    in bool projectEntry = true,
) {
    return Preparation(directory, sources, optimise, projectEntry
        ? Mode.projectEntry : Mode.live).run(program);
}


// Startup only: no live frontend session may exist. Analysis is exclusive
// and resets all frontend modules and caches, not an entry snapshot. Only
// host-owned image data leaves analysis. Image build and load run afterwards,
// so constructors can wait for workers that use the frontend. A clean cache
// hit does not analyse or reset. Unrelated stderr writers must be absent
// during analysis because diagnostic capture redirects process-wide fd 2.
public const(imported!"snakebite.dependencyimage".DependencyImage)* prepareStartupDependencies(
    in string directory,
    imported!"snakebite.project".SourceSet sources,
    in imported!"snakebite.dependencyimage".Optimise optimise
        = imported!"snakebite.dependencyimage".Optimise.yes,
) {
    import snakebite.project: loadProject;

    const buildsDependencyImage = true;
    return Preparation(directory, sources, optimise, Mode.startup).run(
        () => loadProject(directory, sources, buildsDependencyImage).program);
}


private struct DependencyAnalysis {
    string source;
    string[] inputs;
    bool deferStartup;
}


private DependencyAnalysis dependencyAnalysis(
    imported!"snakebite.backends".Program program,
) {
    import snakebite.frontend.compiler: withCompilerLock;
    import snakebite.frontend.imagesource: imageSource, imageInputs;

    DependencyAnalysis result;
    withCompilerLock({
        result = DependencyAnalysis(imageSource(program), imageInputs(program),
            program.hasCEntryPoint && !program.checks.betterC);
    });
    return result;
}


private enum Mode { live, projectEntry, startup }


private struct Preparation {
    import snakebite.backends: Program;
    import snakebite.dependencyimage: DependencyImage, Optimise;
    import snakebite.project: SourceSet;

    private string _directory;
    private const(SourceSet) _sources;
    private Optimise _optimise;
    private Mode _mode;
    private string _stateDirectory;
    private string _imageDirectory;

    private this(in string directory, in SourceSet sources,
        in Optimise optimise, in Mode mode,
    ) {
        import snakebite.project: projectStateDirectory;
        import std.path: buildPath;

        _directory = directory;
        _sources = sources;
        _optimise = optimise;
        _mode = mode;
        _stateDirectory = projectStateDirectory(directory);
        _imageDirectory = buildPath(_stateDirectory, "images");
    }

    private const(DependencyImage)* run(scope Program delegate() program) {
        import snakebite.dependencyimage: ProjectImageCache;
        import snakebite.frontend.compiler: withScratchFrontend;
        import std.path: buildPath;

        DependencyAnalysis analysed;
        bool analysedOnce;
        DependencyAnalysis analysis() {
            if (!analysedOnce) {
                // End scratch analysis before the cache can build or load an
                // image: its constructors can wait for frontend workers.
                analysed = _mode == Mode.startup
                    ? withScratchFrontend(() => dependencyAnalysis(program()))
                    : dependencyAnalysis(program());
                analysedOnce = true;
            }
            return analysed;
        }

        auto cache = ProjectImageCache(
            buildPath(_imageDirectory, "project.json"), settings, _sources.files);
        auto image = new DependencyImage;
        const prepared = cache.prepare(*image,
            () => analysis.source,
            (scope string delegate() source) {
                buildDependencies;
                const generated = source();
                DependencyImage built;
                if (generated.length || _sources.linkerFiles.length)
                    built = buildImage(generated.length ? generated
                        : "module snakebite_dependency_image;\n", analysis);
                return ProjectImageCache.Prepared(built,
                    watchedInputs(analysis.inputs));
            });
        return prepared ? image : null;
    }

    private string settings() const {
        import snakebite.dubcache: toJson;
        import std.conv: text;
        import std.json: JSONValue;
        import std.process: environment;

        const projectEntry = _mode == Mode.projectEntry;
        return text(_sources.flags, _sources.importPaths,
            _sources.stringImportPaths, _sources.linkerFlags,
            _sources.linkerFiles, JSONValue(_sources.sourceOverrides),
            toJson(_sources.dubDescription).toString, environment.get("DFLAGS", ""),
            environment.get("LFLAGS", ""), "\noptimise:", _optimise,
            "\nprojectEntry:", projectEntry,
            projectEntry ? DependencyImage.entryStartupSettings : "");
    }

    private void buildDependencies() const {
        import snakebite.dub: buildDubDependencies;
        import snakebite.project: isDubProject;

        if (_sources.linkerFiles.length && isDubProject(_directory))
            buildDubDependencies(_directory, _stateDirectory,
                _sources.dubDescription, _sources.linkerFiles);
    }

    private DependencyImage buildImage(in string source,
        in DependencyAnalysis analysis,
    ) const {
        import snakebite.dependencyimage: defaultCompiler, prepareImage;

        return prepareImage(source, _imageDirectory, defaultCompiler,
            analysis.inputs, _sources.importPaths, _sources.stringImportPaths,
            _sources.flags.compilerArguments, _sources.linkerFiles,
            _sources.linkerFlags, optimise: _optimise,
            deferStartup: _mode == Mode.projectEntry && analysis.deferStartup);
    }

    private string[] watchedInputs(in string[] analysisInputs) const {
        import snakebite.dub: dubInputs;
        import snakebite.project: isDubProject;

        return analysisInputs ~ _sources.linkerFiles
            ~ (isDubProject(_directory)
                ? dubInputs(_directory, _sources.dubDescription) : null);
    }
}
