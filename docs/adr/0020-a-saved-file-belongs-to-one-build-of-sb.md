---
status: accepted
---

# A saved file belongs to one build of `sb`

The saved **Bytecode program** (ADR-0017) holds the addresses of host code:
the instruction handlers, the entries of builtins and the halt actions. The
file stores each address as a distance from one handler. The file is
therefore valid only for the executable that wrote it. Issue #958 gives the
requirement that loading is much faster than compiling, so the load must not
translate each address one by one.

## Decision

1. The header of the file holds a key of the executable that wrote it. The
   load refuses a file with another key.
2. The refusal must not occur in normal use. The `sb` executable is an
   input of each compile statement in the `build.ninja` file that `sb`
   writes (ADR-0021). A new `sb` then makes ninja compile again.

## Considered options

- A handler index in the file, with a table in the VM. Rejected. A
  throwaway change on master 3f36bdfe measured +0.3 to +1.0 % on the load.
  But no single place lists all handlers: about 6472 are in tables and about
  137 are not. Building the table added about 7 M instructions, +24 %, to
  each start of `bin/sb`. An earlier prototype had found a translation at
  load "slightly faster but not nearly enough to compensate for the added
  complexity", in the words of the maintainer.
- A format that is stable across versions of `sb`. Rejected: neither goal of
  #958 asks for it, the dependency image (ADR-0007) is per build too, and it
  needs a versioned format for every VM type that the file holds.

## Consequences

- A file from another build of `sb` is refused, and is never run wrongly.
- The load needs no translation of addresses.
- ninja renews a file after a new `sb`.
