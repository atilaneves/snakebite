module snakebite.project.dependencies;


private:

import snakebite.project.dub: SourceSet;


// Collects image data from a live program without resetting the frontend.
// `program` runs at most once, only when cache validation needs image source.
// For startup without a live program, use `prepareStartupDependencies`.
public const(imported!"snakebite.image.loaded".DependencyImage)* prepareDependencies(
    in string directory,
    in SourceSet sources,
    scope imported!"snakebite.program".Program delegate() program,
    in imported!"snakebite.image.dependency".Optimise optimise
        = imported!"snakebite.image.dependency".Optimise.yes,
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
public const(imported!"snakebite.image.loaded".DependencyImage)* prepareStartupDependencies(
    in string directory,
    SourceSet sources,
    in imported!"snakebite.image.dependency".Optimise optimise
        = imported!"snakebite.image.dependency".Optimise.yes,
) {
    import snakebite.project.loading: loadProject;

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
    imported!"snakebite.program".Program program,
) {
    import snakebite.frontend.compiler: withCompilerLock;
    import snakebite.project.imagesource: imageSource, imageInputs;

    DependencyAnalysis result;
    withCompilerLock({
        result = DependencyAnalysis(imageSource(program), imageInputs(program),
            program.hasCEntryPoint && !program.checks.betterC);
    });
    return result;
}


private enum Mode { live, projectEntry, startup }


private struct Preparation {
    import snakebite.program: Program;
    import snakebite.image.loaded: DependencyImage;
    import snakebite.image.dependency: Optimise;

    private const(SourceSet) _sources;
    private Optimise _optimise;
    private Mode _mode;
    private string _imageDirectory;

    private this(in string directory, in SourceSet sources,
        in Optimise optimise, in Mode mode,
    ) {
        import snakebite.project.state: projectStateDirectory;
        import std.path: buildPath;

        _sources = sources;
        _optimise = optimise;
        _mode = mode;
        _imageDirectory = buildPath(projectStateDirectory(directory), "images");
    }

    private const(DependencyImage)* run(scope Program delegate() program) {
        import snakebite.image.dependency: ProjectImageCache;
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
                _sources.dependencies.build;
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
        import std.conv: text;
        import std.json: JSONValue;
        import std.process: environment;

        const projectEntry = _mode == Mode.projectEntry;
        return text(_sources.flags, _sources.importPaths,
            _sources.stringImportPaths, _sources.linkerFlags,
            _sources.linkerFiles, JSONValue(_sources.sourceOverrides),
            _sources.dependencies.identity, environment.get("DFLAGS", ""),
            environment.get("LFLAGS", ""), "\noptimise:", _optimise,
            "\nprojectEntry:", projectEntry,
            projectEntry ? DependencyImage.entryStartupSettings : "");
    }

    private DependencyImage buildImage(in string source,
        in DependencyAnalysis analysis,
    ) const {
        import snakebite.image.dependency: defaultCompiler, prepareImage;

        return prepareImage(source, _imageDirectory, defaultCompiler,
            analysis.inputs, _sources.importPaths, _sources.stringImportPaths,
            _sources.flags.compilerArguments, _sources.linkerFiles,
            _sources.linkerFlags, optimise: _optimise,
            deferStartup: _mode == Mode.projectEntry && analysis.deferStartup);
    }

    private string[] watchedInputs(in string[] analysisInputs) const {
        return analysisInputs ~ _sources.linkerFiles
            ~ _sources.dependencies.inputs;
    }
}
