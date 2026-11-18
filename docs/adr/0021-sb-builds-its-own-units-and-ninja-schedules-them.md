---
status: accepted
supersedes: ADR-0018, ADR-0019
---

# `sb` builds its own units, and ninja schedules them

Issue #958 states two requirements in the owner's words: "loading must be
equivalent to compiling to RAM and executing immediately", and "loading must
be MUCH faster than compiling from scratch". ADR-0018 gave the decision of
when to compile to an external build tool, with `sb` as a D compiler that
reggae calls. The owner dropped that plan on 2026-11-17. The requirement
now is a small build system inside `sb`: `sb` compiles again only what a
changed source file makes stale. There are three unit sizes. Each one stays
a command line option, and a measurement selects the fastest. In the owner's
words: "Just because dmd is faster doing it per package doesn't mean our
bytecode compiler will too."

Terms. A **unit** is the set of D modules that one compile step compiles
into one file. The **root package** is the dub package of the project. A
**D package** is a package of the language: the modules of one directory.
ninja is a build tool that runs commands in parallel and runs a command
again when one of its inputs is newer than its output.

The model is reggae with ninja, in the owner's words of 2026-11-18: "The
model is reggae/ninja." Each thing that is built is a build statement with
inputs and outputs. A design that puts such work inside another step, or
that gives `sb` a rule for it, does not follow the model.

## Decision

1. The option `--build=off|project|module|package` selects the unit. With
   `project` the unit is the root package. With `module` it is one D module.
   With `package` it is one D package. The default is `off` until the
   measurement selects a mode. Only the bytecode backend has units.
2. `sb` writes a `build.ninja` file for its units and runs ninja. All three
   modes go through ninja. They differ only in the build statements.
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
5. Each compile is a command that ninja runs, and so a child `sb` process:
   it runs the frontend, compiles all functions of the unit to bytecode and
   writes the unit file. The parent `sb` process gets the project
   directory. The child gets its inputs on its command line (item 3) and
   does not read the description of the dub project. The owner: "The parent
   gets the directory!" Only the stale units go through the frontend.
6. The process that runs the program loads it from disk and starts no
   frontend. Each run uses this one path, also after a compile.
7. With `project` there is one compile statement and no link step. The
   output is the saved **Bytecode program** of ADR-0017.
8. With `module` and `package` a link step writes one saved program from the
   unit files. A run loads only that file. A load of separate unit files is
   built only if the measured link time is a large part of the rebuild.
9. With `module` and `package`, a template instance goes into the unit that
   instantiates it, as in an object file, and the link step keeps one copy.
   ADR-0017 gives the instance to the module that declares the template.
   That rule changes when these two modes are built.
10. A backend executes each template instance that it can (issue #961). The
    `module` and `package` modes assume that no root unit needs an instance
    that is native in the dependency image (ADR-0007).
11. The files are in the project state directory.
12. The `--save` and `--load` options stay.
13. The dependency image (ADR-0007) is built by build statements of its
    own: one for the libraries of the dub dependencies and one for the
    `.so` file of the image. It is not a part of a compile step, and a
    change of a dependency is rare. The compile child loads no dependency
    image. What the image needs from the root code is in the output of the
    compile, and the statement that builds the `.so` takes it from there.
    The owner, on the frontend result that the `.so` needs: "this could be
    in the .sbc".

## Measurement

The measured case: touch the first source file of the root package in
lexical order, then time the rebuild. The time of the test run is not part
of the number, because the mode must not change it. For `module` and
`package`, the link time and the load time are reported as separate numbers.

The tool for this measurement is not decided. The owner wants an overhaul of
`bin/bench` (issue #991), and no words of the owner give this measurement to
the present tool. Until a decision, the measurement is: touch the file, run
`sb`, and read the time of the build from its report.

The gate of #958, 3 ms or less to the first guest instruction, applies to
the load step only. The time of the ninja run is a separate number. One
measurement of a ninja 1.13.2 run with nothing to do, on a machine with
other work, gave 3.4 ms for 1 unit, 4.5 ms for 50 and 8.5 ms for 500.

## Order of work

`project` is first. It needs a compile that loads no dependency image
(item 13), so the parts of track A of #960 that give this come before it.
`module` and `package` start after `project` is measured.

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
- A list, from each unit, of the instances that it needs in the dependency
  image. Not built: item 10 assumes that the lists are empty.

## Consequences

- `sb` needs ninja at run time when `--build` is not `off`.
- When a compile fails, ninja adds lines of its own to the output (the
  `FAILED:` line, the command, and `ninja: build stopped`). The owner
  accepted this on 2026-11-18.
- `sb` needs no parser of dmd options, no `ldmd2` name and no `-lib` call.
- The link output needs no `#!` line (ADR-0019), because `sb` starts the
  program itself.
- A rebuild compiles all functions of a stale unit, not only the functions
  that the run calls.
- A project that breaks the assumption of item 10 does not work in the
  `module` and `package` modes.
