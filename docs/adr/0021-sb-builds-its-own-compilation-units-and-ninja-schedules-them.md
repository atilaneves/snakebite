---
status: accepted
supersedes: ADR-0018, ADR-0019
---

# `sb` builds its own compilation units, and ninja schedules them

Issue #958 states two requirements in the owner's words: "loading must be
equivalent to compiling to RAM and executing immediately", and "loading must
be MUCH faster than compiling from scratch". ADR-0018 gave the decision of
when to compile to an external build tool, with `sb` as a D compiler that
reggae calls. The owner dropped that plan on 2026-11-17. The requirement
now is a small build system inside `sb`: `sb` compiles again only what a
changed source file makes stale. There are three sizes of compilation unit.
Each one stays a command line option, and a measurement selects the
fastest. In the owner's words: "Just because dmd is faster doing it per
package doesn't mean our bytecode compiler will too."

The guiding rule, confirmed by the owner on 2026-11-25: `sb` does what
native code does. A native object file is the inspiration for what a compile
writes. In the owner's words: "it doesn't necessarily hold what a native
object file hold. That's the inspiration though, and deviations must be
justified."

Terms. A **compilation unit** is the source files that are given to one
compile. With `module` it is one source file. With `package` it is the
source files of one directory. With `project` it is all the source files.
The **root package** is the dub package of the project. A **D package** is
a package of the language: the modules of one directory. **Root modules**
keeps the meaning that it has in dmd: the modules that are given to a
compile as the files to compile. **Bytecode modules** are all the modules
of the program that `sb` compiles to bytecode. The other modules are native
code. The owner did not want the name "project modules" for them, because
parts of a project can be natively compiled code later. An **`.sbc` file**
is the file that a compile to a file writes. It holds a list of modules.
ninja is a build tool that runs commands in parallel and runs a command
again when one of its inputs is newer than its output.

The model is [reggae] with ninja, in the owner's words of 2026-11-18: "The
model is reggae/ninja." Each thing that is built is a build statement with
inputs and outputs. A design that puts such work inside another step, or
that gives `sb` a rule for it, does not follow the model.

[reggae]: https://github.com/atilaneves/reggae/blob/v0.18.0/payload/reggae/rules/d.d

## Decision

1. The option `--build=off|project|module|package` selects the compilation
   unit. The default is `off` until the measurement selects a mode. Only
   the bytecode backend has compilation units.
2. `sb` writes a `build.ninja` file for its compilation units and runs
   ninja. All three modes go through ninja. They differ only in the build
   statements. The compile rules are as reggae writes them. A command has
   no shell operator and no environment variable. A compile error is shown
   as ninja shows it.
3. ninja decides what is stale, with its own rule. `sb` adds no rule of its
   own. Each compile step writes a dependency file of the files that it
   read: imported modules and string imports. It is a `.dep` file, as in a
   reggae build, and its place follows from the place of the output by
   convention. No command line option names it. The import paths, the
   versions and the flags from the description of the dub project are in
   the command line of each compile statement, so a changed option changes
   the command. The `sb` executable is an input of each compile statement
   (this replaces item 2 of ADR-0020).
4. On a run with no change, no process reads the description of the dub
   project and no process makes `build.ninja` again. ninja's rule decides
   when `build.ninja` is made again: when the dub recipe or the freeze file
   (`dub.selections.json`) is newer than it. `sb` makes it when it does not
   exist. The owner: "Why would it do any of that if nothing has changed?"
5. Each compile is a command that ninja runs, and so a child `sb` process.
   The parent `sb` process gets the project directory. The child gets its
   inputs on its command line (item 3) and does not read the description of
   the dub project. The owner: "The parent gets the directory!" Only the
   stale compilation units go through the frontend. The child gets the
   files of its compilation unit as the files to compile, and no other
   module is given to it as a file to compile. What the frontend then does
   with imported modules, with the signature of a function in a different
   module, and with a declaration that has no body, is what the dmd
   frontend already does. `sb` adds nothing there.
6. The child loads no dependency image. A call to a function that the
   compile does not define is a call to its name, made from the signature
   of the function only. The compile does not know or ask where the
   definition is. When the program is made ready to run (item 10), the
   name is connected to bytecode when an `.sbc` file defines it, else to
   native code. The owner: "It's a call to a function defined elsewhere,
   it's the job of the linker or whatever maps names to actual functions
   to connect it to bytecode or native."
7. The child writes to the `.sbc` file: the functions and data that the
   modules of its compilation unit define; each template instance that the
   compile made, in the entry of the module that declares the template (as
   ADR-0017 gives it); the symbol name of each definition; and a reference
   by symbol name to each thing that is defined elsewhere. The reason for
   symbol names is that the guiding rule gives an object file the same:
   a definition and a reference are found by name, not by a position in the
   list of modules of one compile.
8. The child also writes the native template instances that its own modules
   need, next to the `.sbc` file. These are instances of dependency
   templates that no backend can execute (issue #961, ADR-0007). A backend
   executes each template instance that it can. The compile needs no other
   output for the dependency image (item 14).
9. The compiler has no flag for "part of a larger program". A compile of a
   whole project is the same code as a compile of many modules. The
   `project` mode is one compile with all the source files, and it writes
   one `.sbc` file.
10. One function takes the `.sbc` files and gives a program in memory (a
    **Bytecode program**, ADR-0017). In the first version, the process that
    runs the tests calls it. There is no link statement, no second process
    and no program file for this. The reason is the time from the end of
    the compile to the start of the tests, measured on a prototype for
    sumtype, automem and cerealed: 83.6, 111.5 and 215.6 ms with a link
    step that writes a program file and a load of it, against 23.3, 32.4
    and 71.5 ms when the run process puts the files together. A run with no
    edit is slower without the program file. The owner, asked if such a run
    counts as much as a run after an edit: "no". Two other ways stay as
    later experiments, to be measured against this one: a separate link
    step that writes one complete program file, and a link that only
    records which definition is used.
11. The function of item 10 gives a name its definition first from an
    `.sbc` file, then from native code, as a native linker takes object
    files before libraries. A template instance that several files hold is
    kept one time. A datum of such an instance that native code in the
    process also holds is taken from native code: that native code cannot
    be made to use the copy of a file, and the program keeps one copy of the
    datum. Two other definitions of one name are an error that
    names the symbol, as the link of native code that LDC, the compiler of
    the host, builds one module at a time reports. A `main` in a module of a
    library that dub tests is such a second definition, because the test
    runner module of dub defines `main`. dmd gives the error for a variable
    only: it makes each function a symbol that the linker lets a second
    definition replace or drop with no error, and its link keeps the first
    of two functions, also of two `main` functions. In
    one compile, dmd and LDC report two `main` functions as an error of the
    compile. A name with no definition is an error only when code that uses
    it runs (ADR-0017). The order of module constructors and of unit tests
    of modules that do not import each other is not fixed. Native builds give
    different orders for different ways of building, and the D
    specification says "There is no other order imposed on the execution of
    module static constructors."
12. `bin/sb DIR` with no `--build` stays a different way of compiling. The
    owner: "they are two different ways of compiling". It has one frontend
    for all the files, compiles a function at its first call, uses
    pointers in memory, and has symbol names only when the output is a
    file.
13. The files are in the project state directory. The `--save` and `--load`
    options stay.
14. The dependency image (ADR-0007) is built by build statements of its
    own: one for the libraries of the dub dependencies and one for the
    `.so` file of the image. It is not a part of a compile step, and a
    change of a dependency is rare. The compile child loads no dependency
    image. The statement that builds the `.so` takes the native template
    instances of item 8 from all compile statements together, each
    instance one time.
15. The values of a compile come from the dub recipe. `--build` is for a
    dub project and takes no option that changes the compile. So nothing
    changes a compile without a change of the recipe, of the freeze file or
    of a source file. The owner: "How do the options change without the dub
    recipe or freeze file changing?"
16. The code of the build is in a package of its own in the codebase. The
    owner: "everything related to this had better be in its own
    module/package in the codebase".

## Results and tests

The `module` and `package` modes give the results of native code that is
built in the same way. Example: a unit test inside a template of an imported
module does not run when each module is compiled alone, because dmd parses
the body of a unit test only in a root module. It runs one time when all the
files are compiled in one command.

Tests state behaviour only. Where a native build for each module and a
native build in one command agree, a test compares with `bin/sb DIR`: the
same exit status, the same standard error, and the same lines on standard
output as a set. Where they differ, the test states the native result as an
expected value, with a comment on how that value was found.

## Measurement

The measured case: touch the first source file of the root package in
lexical order, then time the rebuild. The time of the test run is not part
of the number, because the mode must not change it. For `module` and
`package`, the time to make the program ready (item 10) is reported as a
separate number. The owner selects the default mode from the measurement of
the three modes.

The tool for this measurement is not decided. The owner wants an overhaul of
`bin/bench` (issue #991), and no words of the owner give this measurement to
the present tool. Until a decision, the measurement is: touch the file, run
`sb`, and read the time of the build from its report.

The time to make the program ready has no gate. The owner on 2026-11-25:
"3ms would be great, but I don't think we can use that as a gate." The time
of the ninja run is a separate number. One measurement of a ninja 1.13.2 run
with nothing to do, on a machine with other work, gave 3.4 ms for 1
compilation unit, 4.5 ms for 50 and 8.5 ms for 500.

## Order of work

1. Five refactor steps on master. Each is its own PR and keeps the behaviour
   of master. The next step can start as soon as the PR of the one before
   it is created.
   1. The start record of a module is made from that module alone, with its
      imports by name.
   2. The facts of the whole program move out of the compile.
   3. One decision with three results: defined only here, defined here and
      elsewhere, not defined here.
   4. A reference to a function of other bytecode is a name that is found
      when the program is made ready.
   5. A caller uses only the signature of the function that it calls.
2. The `module` mode, on a new branch.
3. The `package` mode.
4. The measurement of the three modes. The owner selects the default.

The `project` mode needs a compile that loads no dependency image (item 6),
so the parts of track A of #960 that give this come before it. PR #1067 is
closed. Its branch stays as a reference of what not to do.

## Rules that stay

- A load gives the same result as a compile to RAM that runs at once.
- The process that loads has no AST and starts no frontend.
- The test of a load runs the load in a process other than the one that
  compiled.
- A test of a saved file checks what the loaded program does. It does not
  examine the content of the file or of a compiled function. The owner:
  "Nobody cares as long as that data can be loaded and does what we expect
  it to."

## Considered options

- `sb` as a D compiler that reggae calls (ADR-0018). Dropped by the owner.
- `sb` schedules the child processes itself. Rejected by the owner: it is a
  second implementation of what ninja does.
- A check inside `sb` that skips the ninja run when nothing changed.
  Rejected: it is a second copy of the stale rule.
- A link step that writes one complete program file, and a link that only
  records which definition is used. Not in the first version: items 10 and
  11 give the measured reason. Both stay as later experiments.

## Consequences

- `sb` needs ninja at run time when `--build` is not `off`.
- When a compile fails, ninja shows the error as it shows any error: it
  adds lines of its own to the output (the `FAILED:` line, the command, and
  `ninja: build stopped`). The owner accepted this on 2026-11-18.
- `sb` needs no parser of dmd options, no `ldmd2` name and no `-lib` call.
- There is no link output, so ADR-0019 has nothing to decide: `sb` starts
  the program itself.
- A rebuild compiles all functions of a stale compilation unit, not only
  the functions that the run calls.
- A call to a function that the compile does not define is connected to its
  definition when the program is made ready to run, so a part of a project
  that is compiled to native code later needs no change of the compile.
