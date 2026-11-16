---
status: accepted
---

# `sb` is a D compiler for the build tool; reggae is the target

Issue #958 states two requirements in the owner's words: "loading must be
equivalent to compiling to RAM and executing immediately", and "loading must
be MUCH faster than compiling from scratch". Saved bytecode programs
(ADR-0017) become the default. This record states who decides when to
compile, and how `sb` takes its input. reggae is a build tool for D. dub is
the package manager of D.

## Decision

1. The build tool decides when to compile. `sb` has no cache of its own for
   saved programs. A build tool that runs `sb` as a D compiler gets a
   **Bytecode program** in a file, and it runs the compiler again when its
   own rules say so.
2. `sb` takes dmd-style options through the parser of the frontend,
   `parseCommandLine`. It does not parse options itself.
3. A `-c` call compiles the root package. A `-lib` call goes unchanged to
   the dmd-style driver of the host compiler. Dependencies stay native, as
   ADR-0009 says. A link call links (ADR-0019 gives the output).
4. The first unit size is all-at-once: one compile call for the root
   package, and one link call. A unit of one D package, and a unit of one D
   module, follow in a second plan.
5. reggae is the target. The first version is started through a symbolic
   link named `ldmd2` to `bin/sb`. reggae and the library of dub accept only
   known compiler names. No change to reggae is made for `sb`.
6. The compile-to-RAM path stays, for the REPL, the tests and the
   benchmarks.

## Considered options

- `bin/sb DIR` keeps its own cache of saved programs. Rejected: the build
  tool decides when to compile. A second place that decides is a second copy
  of that state.
- dub as the first target. Rejected for the first version: dub reads no
  dependency files, so a new `sb` is seen only through the version string.
- A parser of options that `sb` owns. Rejected: it is a second copy of the
  rules of dmd for options.

## Consequences

- An option that dmd accepts is accepted by `sb` with the meaning that the
  frontend gives it.
- A new `sb` must make the build tool compile again. ADR-0020 states how.
- dub is a later, optional target.
