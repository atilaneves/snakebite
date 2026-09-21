# Interim Snakebite cache experiment

This is a throwaway prototype, not a change to normal `sb` execution.
It uses installed DUB as a command. It neither links DUB nor changes DUB.

## Run

From this worktree:

```sh
ldc2 -O2 prototypes/dub-library/snapshot.d -of=/tmp/snakebite-dub-snapshot
/tmp/snakebite-dub-snapshot --test
/tmp/snakebite-dub-snapshot . /tmp/snakebite-cache.bin --freeze-hooks
/tmp/snakebite-dub-snapshot . /tmp/snakebite-cache.bin --freeze-hooks
```

The cache path must be outside the project and its dependency directories.
Add `--refresh` to force a new description. Without `--freeze-hooks`, active
generation hooks force a fresh description on every call. The explicit flag
means that the caller accepts reuse of generated setup until refresh.
It must not become an implicit default for projects with arbitrary hooks.

## Measurements

All measurements below include loading the cache and checking its inputs.
They exclude process startup and do not measure a complete Snakebite run.

| Approach | Measured time |
|---|---:|
| Full DUB JSON, explicit unittest configuration, LDC | 160-170 ms |
| Selected DUB data fields, same configuration and compiler | 170 ms |
| Cache reconstructing the full description | about 5 ms |
| Compact resolved-input cache, Snakebite | 1.776 ms median |
| Compact resolved-input cache, small example | 0.488 ms |

The final Snakebite run had nine warm samples, from 1.722 to 1.825 ms.
It checked 564 paths and read a 159,355-byte cache. Its first miss cost
246.883 ms, including directory enumeration and cache publication.
The small example checked ten paths and read 3,264 bytes.

The full and selected-field DUB commands both use `--config=unittest`,
`--build=unittest`, and `--compiler=ldc`. Selecting fields does not bypass
DUB's full project-description path.

## Cache-hit optimization

The initial snapshot is committed as `b6b8ac1`. The follow-up preserves all
564 path checks and the generation-hook policy, but removes intermediate
text formatting and nested watch objects.

Add `--timings` to report environment, read/decode, and validation costs.
An initial warm sample spent 426 us on the environment fingerprint, 276 us
on reading and decoding, and 996 us on filesystem validation.

The changes are:

- Hash environment entries directly from the POSIX environment, with lengths
  separating entries. Avoid constructing and sorting a temporary map.
- Store device, inode, mtime, and ctime as six fixed-size fields. Avoid
  formatting six numbers on every path check.
- Store each watch as one binary string rather than a nested object.

SHA-256 remains the fingerprint algorithm. A trial with MurmurHash did not
give a useful gain and was reverted. The main environment cost was building
the temporary map, not the hash algorithm.

Nine warm optimized samples had a median of 0.872 ms, ranging from 0.797 to
0.987 ms. A separate alternating comparison reduced sensitivity to changing
machine load:

| Seven alternating warm runs | Median | Range |
|---|---:|---:|
| Initial cache | 1.604 ms | 1.564-1.966 ms |
| Optimized cache | 0.956 ms | 0.872-1.017 ms |

That is about 40% less elapsed time in the alternating comparison. The cache
shrunk from 159,355 to 133,017 bytes. No watched paths were removed. Typical
optimized costs were 33 us for context, 250 us for reading/decoding, and
570 us for path validation. Filesystem checks are now the largest cost.

These remain in-process operation times, excluding process startup and
Snakebite's frontend or native dependency preparation. A hit is often below
1 ms here, but that is not a strict upper bound. The initial miss still
costs about 212 ms. The remaining prototype limits below still apply.

## What is cached

The small record contains the root target's resolved source files, import
paths, string-import paths, compiler flags, version identifiers, options,
linker flags, libraries, and linker files. These are the fields consumed by
`snakebite.project.dubSourceSet`. It also contains an environment fingerprint,
filesystem validation data, and a digest of the full description.

The full JSON description is retained in a companion file. It need not be
parsed on every source edit. In a production integration, use its saved
digest in the image-cache settings and load the full document only when the
dependency build path needs it. This integration has not been implemented
or measured here; dependency-image validation can still add work.

Existing directory timestamps are cheap to inspect. If one changes, compare
its entry names and types. An atomic editor save changes the directory
timestamp but leaves its final entry set unchanged, so it can still hit.
New or removed files and directories cause a fresh DUB description.

Recipe and selection files use file timestamps and inode identity. The
environment fingerprint excludes `_` and `SHLVL`, which change with the
launching shell but do not describe the DUB build setup. Environment order
is retained; reordering causes a conservative cache miss. Environment access
assumes this single-threaded prototype has no concurrent environment edits.

## Checks

The executable's `--test` runs 19 checks against real DUB. They cover first
load, repeated access, in-place source edits, atomic source replacement,
file additions and removals, new directories, files in new directories,
recipe edits, forced refresh, environment changes and restoration, default
hook bypass, and explicit hook reuse.
All passed. The binary encoder also checks lossless round trips on each
cache miss. The four existing `ut.dub` tests passed after each D edit.

## Limits and production requirements

The result supports caching resolved inputs in Snakebite. It does not prove
a correct general cache can reach 1 ms, and is not ready to become a default.

- Generation-hook inputs can be arbitrary. Reuse must be explicit unless
  there is a defined input contract. DMD's hook is not special-cased here.
- Add compiler/DUB executable and configuration fingerprints, DUB overrides,
  recipe discovery outside package roots, and external source roots.
- Symlink traversal and explicitly used hidden directories need coverage.
  This prototype skips recursive symlinks and `.git`, `.dub`, `.snakebite`.
- Add stable cache-format versions, corruption recovery, atomic publication,
  concurrent-reader handling, and protection against edits during capture.
- Preserve Snakebite's configuration fallback, compiler choice, and custom
  version arguments. This experiment pins unittest and LDC.
- Handle packages without a root target. The prototype rejects them.
- Validate deferred use of the full description and native dependency
  rebuilds through Snakebite before treating the measured cost as its
  end-to-end discovery overhead.

The useful interim boundary is a saved project setup: ordinary source
contents remain live, while changes to build setup cause a refresh. A fresh
DUB instance, an in-process DUB library, or fewer output fields does not
provide that boundary by itself.
