---
status: superseded by ADR-0021
---

# The link output is a `#!` file

ADR-0018 makes `sb` a D compiler for a build tool. A build tool expects the
output of the link call to be a file that the operating system can run. The
saved **Bytecode program** (ADR-0017) must therefore be that file.

## Decision

1. The file that the link call writes is the saved program. Its first line
   is a `#!` line that names `sb --load`, so the operating system runs it.
2. The reader of the file accepts that line.
3. With `--load FILE`, the parsing of options stops at the file name. All
   arguments after it are arguments of the program.
4. The program holds no working directory. It runs where it is started, as
   a native executable does.

## Considered options

- A small native launcher with the program appended. It is a real
  executable for tools, and it works on Windows. Rejected for now: it is one
  more program to build and to copy at each link, and it gives nothing on
  Linux. It can replace the `#!` file later with no change to the format.
- A self-contained executable with its own copy of the VM. Rejected: the
  handler addresses are stored as distances (ADR-0020), so the VM in the
  executable must be the executable that compiled the program. Each link
  would copy all of `bin/sb`.

## Consequences

- The saved program is one file, and the operating system starts it.
- A tool that needs a native executable does not work with the `#!` file.
  The native launcher is the later option for that case.
