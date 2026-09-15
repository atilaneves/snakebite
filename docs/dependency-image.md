# Dependency image preparation

`snakebite.dependencyimage.prepareImage` compiles generated D source into a
position-independent object, links a shared library, and loads it through
druntime. It supports the Linux DMD and LDC builds used by Snakebite.

This is the compile, link, and load part of ADR-0007. Callers supply the
source. Automatic template discovery, wrapper generation, dub dependency
archives, and CLI preparation are still separate work.

## Use

```d
import snakebite.dependencyimage: prepareImage;

auto image = prepareImage(q{
    module image;
    import core.atomic: atomicLoad;
    export extern(C) int image_atomic_load(shared int* value) {
        return atomicLoad(*value);
    }
}, cacheDirectory);

auto program = Program(rootModules);
program.dependencyImage = &image;
scope backend = new Bytecode(program);
// Run the program while image is alive.
```

The guest declares `extern(C) int image_atomic_load(shared int*)`. Its call
uses the normal FFI path. The C wrapper has C linkage on both sides. Do not
map a D declaration to a C wrapper without also changing the call ABI.

Prepare the image before constructing any backend. Each backend searches
the image handle first, then the process symbols. Symbol misses and call
plans stay cached. There is no compile step on symbol lookup.

`DependencyImage` cannot be copied. It owns a loader reference and releases
that reference when its scope ends. The image must outlive its backends,
callbacks, and any returned objects whose methods or destructors are in the
image. `Program` and `Resolver` borrow the image; they do not own it.

## Compiler and runtime

The default compiler is `dmd` for a DMD host and `ldc2` for an LDC host.
Callers can supply its path. Use the same compiler installation as the host.
Preparation checks the compiler family and the D frontend version. These
checks do not prove that two installations use the same runtime build.

All Reggae executable configurations link druntime and Phobos shared. The
image does the same. The loader runs D module constructors and registers
the image with druntime. The compiler's shared libraries must be available
to the system loader.

## Cache and errors

The cache key includes build flags, generated source, host frontend version,
compiler path, compiler executable content, compiler version output, and the
paths and contents of explicit `inputs`. Callers must list any extra source or
configuration files used by the generated source. The compiler's runtime
headers and libraries are assumed unchanged within an installation.

A cache hit skips compilation and linking. It still identifies the compiler,
hashes the inputs, and loads the image. Builds use unique temporary
directories and publish completed libraries with an atomic rename. A failed
build does not publish an image. Concurrent builders can duplicate work but
cannot expose a partially linked library.

Compiler errors name the failed phase. Their exception cause retains the
command and compiler output. Loader errors include the library path. The
cache directory must be writable and owned by the caller. Cache eviction is
left to the caller.

## Verification

`ut.ffi.symbol` runs in the DMD unit runner and the LDC acceptance runner.
It covers direct native calls and calls through the interpreter and bytecode
backends, cache reuse, source and input changes, compiler and linker failure,
compiler family checks, and D module construction. The atomic tests call
druntime's real `atomicLoad!int`; they do not emulate an atomic operation.
CTFE cannot execute loaded native code.
