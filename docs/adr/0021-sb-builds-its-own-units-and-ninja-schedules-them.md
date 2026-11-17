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

## Decision

1. The option `--build=off|project|module|package` selects the unit. With
   `project` the unit is the root package. With `module` it is one D module.
   With `package` it is one D package. The default is `off` until the
   measurement selects a mode. Only the bytecode backend has units.
2. `sb` writes a `build.ninja` file for its units and runs ninja. All three
   modes go through ninja. They differ only in the build statements.
3. ninja decides what is stale, with its own rule. `sb` adds no rule of its
   own. Each compile step writes a dependency file from the record that the
   frontend keeps of the files it read: imported modules and string imports.
   The import paths, the versions and the flags from the description of the
   dub project are in the command line of each compile statement, so a
   changed option changes the command. The `sb` executable is an input of
   each compile statement (this replaces item 2 of ADR-0020).
4. `sb` writes `build.ninja` again only when its cached description of the
   dub project is not valid.
5. A child `sb` process compiles each stale unit: it runs the frontend,
   compiles all functions of the unit to bytecode and writes the unit file.
   The frontend holds process-global state, so two compiles cannot share a
   process. Only the stale units go through the frontend.
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
11. The files are in the project state directory that `sb` already has.
12. The `--save` and `--load` options stay.

## Measurement

The measured case: touch the first source file of the root package in
lexical order, then time the rebuild. The time of the test run is not part
of the number, because the mode must not change it. `bin/bench` makes this
measurement. For `module` and `package`, the link time and the load time
are reported as separate numbers.

The gate of #958, 3 ms or less to the first guest instruction, applies to
the load step only. The time of the ninja run is a separate number. One
measurement of a ninja 1.13.2 run with nothing to do, on a machine with
other work, gave 3.4 ms for 1 unit, 4.5 ms for 50 and 8.5 ms for 500.

## Order of work

`project` is first. `module` and `package` start after `project` is
measured and after the rule of #961 is on master.

## Rules that stay

- A load gives the same result as a compile to RAM that runs at once.
- The process that loads has no AST and starts no frontend.
- The test of a load runs the load in a process other than the one that
  compiled.

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
- `sb` needs no parser of dmd options, no `ldmd2` name and no `-lib` call.
- The link output needs no `#!` line (ADR-0019), because `sb` starts the
  program itself.
- A rebuild compiles all functions of a stale unit, not only the functions
  that the run calls.
- A project that breaks the assumption of item 10 does not work in the
  `module` and `package` modes.
