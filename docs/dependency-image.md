# Dependency image preparation

`snakebite.dependencyimage.prepareImage` compiles generated D source into a
position-independent object, links a shared library, and loads it through
druntime. It supports the Linux DMD and LDC builds used by Snakebite.

## Project execution

`prepareProject` prepares an image before `bin/sb` or `bin/bench` constructs a
backend that calls native code. Runs with only CTFE or the native compiler skip
this step. The frontend walks function bodies and collects dependency function
template instances. Generated source takes their addresses, which retains the
original D symbols in the image. There are no forwarding wrappers or changes to
the calling convention. Overloaded templates are instantiated separately with
`__traits(getOverloads)`.

Root-defined templates stay in the guest. Instances that require private names,
guest-local types, or a captured context cannot be compiled in the image and
keep the normal backend fallback.

For dub projects, the same `dub describe` call supplies root sources and the
full dependency description. Snakebite uses the host compiler with `dub build
--deep` to build missing or changed dependencies. The image links each
dependency's artifact in dub's build cache, which dub keys by compiler and
build settings, not the copy dub leaves in the package's target path: any
compiler's build of that package replaces the copy. For the same reason
Snakebite runs every dub command in the process environment as it is. A flag
added through `DFLAGS` for the build alone would move the artifacts to paths
the description does not name. Both host compilers emit position-independent
code by default on the supported platform, which the shared image needs. The
image includes every member of every static archive in the transitive link
dependency chain, including members that no template reference uses. Dub
linker files, linker flags, and system libraries are also supplied to the link.
The root package is not linked into the image.

Snakebite records hashes of dependency sources, recipes, build settings, and
archives in the project's hashed state partition under `.snakebite` in the
current working directory. An unchanged dependency set
skips `dub build`. A change to root source contents alone also skips that build.
A missing archive, changed dependency, or changed build setting makes dub check
and build the project again. The first run also makes this check to establish
archives for the host compiler and shared image. Dub build hooks run when dub
builds the project; they do not run on a dependency cache hit.

The image remains mapped until the executable exits, including after the
loading thread exits. `Project`, `Program`, and `Resolver` hold descriptions of
that image. The benchmark reports image preparation time separately from
frontend and execution time.

## Direct use

Callers can also prepare an image explicitly:

```d
import snakebite.dependencyimage: prepareImage;

auto image = prepareImage(q{
    module image;
    import core.atomic: MemoryOrder;
    import core.internal.atomic: atomicLoad;
    export __gshared auto retained = &atomicLoad!(MemoryOrder.seq, int);
}, cacheDirectory);

auto program = Program(rootModules);
program.dependencyImage = &image;
scope backend = new Bytecode(program);
// Run the program with the prepared image.
```

Guest code imports and calls `core.internal.atomic.atomicLoad` directly. The
retained pointer causes the compiler to emit its D symbol. The resolver finds
that symbol and the normal FFI path calls it.

Prepare the image before constructing any backend. Each backend searches the
image handle first, then the process symbols. Symbol misses and call plans stay
cached. There is no compile step on symbol lookup.

`DependencyImage` is a copyable description. Its scope does not control the
image lifetime. The native loader retains the image with `RTLD_NODELETE`, while
druntime still performs D module initialization and thread cleanup.

## Compiler and runtime

The default compiler is `dmd` for a DMD host and `ldc2` for an LDC host. Callers
can supply its path. Use the same compiler installation as the host. Preparation
checks the compiler family and the D frontend version. These checks do not prove
that two installations use the same runtime build.

All Reggae executable configurations link druntime and Phobos shared. The image
does the same. The loader runs D module constructors and registers the image
with druntime. The compiler's shared libraries must be available to the system
loader.

## Cache and errors

Project images are cached in the current working directory under
`.snakebite/<project-path-hash>/images`. Startup images and DUB dependency
state use the same project partition. The project path hash is the SHA-256
hash of the normalized absolute project path. Project preparation supplies
imported source files as cache inputs.

Every image has two cache levels. A stamp record, keyed on the build flags,
import paths, generated source, frontend version, compiler path, linker
arguments, and the paths of `inputs` and `linkerFiles`, holds file metadata
for the compiler, every input, and the image. If all of them are unchanged,
preparation loads the image directly: it does not run the compiler, read the
compiler executable, or read an input. Only a stamp miss computes the content
key, which adds the compiler executable content, the compiler version output,
and the contents of `inputs` and `linkerFiles`. Callers must list any extra
source or configuration files used by the generated source. The compiler's
runtime headers and libraries are assumed unchanged within an installation.

Project preparation first checks the partition's
`images/project.json`. This records the image path, build settings, and file
metadata for the compiler, dependency inputs, archives, and root sources. If
they are unchanged, preparation loads the existing image directly. It does not
discover templates, probe the compiler, or
read and hash input contents. File identity, size, modification time, and change
time detect replaced files and same-size edits with restored modification times.

If only root source metadata changed, preparation checks whether the generated
template references changed. If they did not, it reuses the image and updates
the root metadata. Otherwise, it uses the two-level image cache described
above. Direct calls to `prepareImage`, including the test startup image, use
that cache. A cache hit for a CLI run therefore costs a handful of `stat`
calls and a loader reference, whichever level it hits.

Builds use unique temporary directories and publish completed libraries with an
atomic rename. A failed build does not publish an image. Concurrent builders can
duplicate work but cannot expose a partially linked library.

Compiler errors name the failed phase. Their exception cause retains the command
and compiler output. Loader errors include the library path. The cache directory
must be writable and owned by the caller. Cache eviction is left to the caller.

## Verification

`ut.ffi.symbol` runs in the DMD unit runner and the LDC acceptance runner. It
covers direct native calls and calls through the interpreter and bytecode
backends, cache reuse, source and input changes, compiler and linker failure,
compiler family checks, and D module construction. The atomic tests call
druntime's real `atomicLoad!int` and `atomicFetchAdd!int`. They also check
automatic project preparation, image lifetime, and cache reuse. CTFE cannot
execute loaded native code. The dub fixture checks the full backend matrix,
transitive archive members, paths with spaces, missing archives, changed
dependency sources, and reuse after a root source edit.
