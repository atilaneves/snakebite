# Throwaway DUB library benchmark

Question: Can DUB library calls reduce project description time below 1 ms?

Run from the worktree root:

```sh
bash prototypes/dub-library/run.sh examples/rt-simple 7
prototypes/dub-library/prototype . 7
```

The script requires LDC, libcurl, DMD, DUB, and the locally cached DUB 1.42.0
source. Set `DUB_SOURCE` to another DUB source directory if needed. Compilation
is outside the measured intervals. Both paths use the same compiled DUB code.
Package generation hooks can also call the installed DUB executable.

The rows measure a child CLI process plus JSON parsing, fresh library instances,
new instances with a shared package manager, repeated descriptions of an already
loaded project with saved compiler settings, JSON conversion alone, and
iteration over cached target source lists. Library description rows exclude
JSON conversion.
Each row reports its first sample, median, minimum, and maximum.

The cached source-list row does not validate the cache. It is only a lower bound
for reuse. This prototype does not handle changed recipes, dependencies,
compiler
settings, source-file additions, or generation-hook inputs. It is not suitable
for production use. It uses the default configuration and debug build type.
It does not use Snakebite's synthetic unittest configuration.

The package count and sorted target source paths are checked against the CLI
result. This is a smoke check, not proof that all build settings are equivalent.

## Results

Measured on 2026-09-21 with DUB 1.42.0 source and LDC 1.43.0 (`-O2`, assertions
enabled). Each row has nine samples. Dependencies were already installed. These
are elapsed times, not CPU times. Compilation and fixture setup are excluded.
The CLI row also extracts and sorts source paths for the later checks.

| Operation | Small project median | Snakebite median |
|---|---:|---:|
| CLI plus JSON parse | 8.816 ms | 149.492 ms |
| Fresh DUB instance and description | 3.634 ms | 139.470 ms |
| Shared package manager and description | 3.329 ms | 99.026 ms |
| Loaded project, saved settings, new description | 0.432 ms | 91.279 ms |
| JSON serialization and parsing only | 0.065 ms | 3.331 ms |
| Read cached source lists, no validation | <0.001 ms | <0.001 ms |

Snakebite's CLI samples ranged from 146.048 to 159.147 ms. Shared
package-manager samples ranged from 94.161 to 146.795 ms; the first sample
fills that cache.
Loaded-project samples ranged from 83.451 to 101.706 ms. This is a small local
experiment; load and cache state affect the absolute numbers.

The small project returned one package and five target source entries. Snakebite
returned 16 packages and 427 target source entries. The source-path checks
passed for all three library modes. `ninja bin/ut && bin/ut ut.dub` also passed
all four existing DUB parsing tests in the main checkout. No production D code
changed.

## Decision

A fresh library call does not solve the Snakebite delay. Sharing the package
manager helps, but even an already loaded project still takes about 91 ms to
describe. A small project can get below 1 ms with a loaded project and saved
compiler settings. This is not a general guarantee.

For Snakebite, investigate reuse of the completed description next. The cached
source-list row shows only the cost to read existing data. It does not establish
that a correct cache with input validation can meet 1 ms. Such a cache must
account for recipes, selections, compiler settings, source discovery, and
generation-hook inputs before it can replace fresh descriptions.

The prototype remains on `prototype/dub-library-cost`. No production integration
is justified by these measurements alone.

## Profile of repeated descriptions

Run the focused profile with:

```sh
prototypes/dub-library/prototype . 15 profile
```

This mode loads the project and compiler settings once. It then measures full
descriptions, metadata-only descriptions (`buildType = ""`), and individual
package descriptions. It excludes JSON conversion. Each row has 15 samples.

| Median | Original | Without root import paths | Restored |
|---|---:|---:|---:|
| Loaded project description | 97.355 ms | 56.163 ms | 80.272 ms |
| Package metadata only | 40.072 ms | 17.008 ms | 31.302 ms |
| Snakebite package metadata | 21.039 ms | 2.619 ms | 16.602 ms |

The middle run temporarily removed the five `importPaths "."` entries in
this worktree's manifest. All five were restored. This changes the description
and is only a diagnostic experiment, not a valid implementation change.
Other packages also got faster between runs, so do not attribute the entire
initial-to-middle difference to the manifest edit.

The DUB 1.42.0 source explains the repeated work:

- `package_.d:613` calls both `getBuildSettings` and
  `getCombinedBuildSettings` for each package description. The latter includes
  every configuration and platform, even those not used for this build.
- `compilers/buildsettings.d:527` recursively enumerates directories with
  `dirEntries(..., SpanMode.depth)`. This includes import paths, not only
  source paths. It filters hidden entries after traversal has reached them.
- `generators/generator.d:145` gathers build settings again for targets.
  Line 176 gathers them again after generation hooks. Line 189 gathers them
  again during finalization.

A CPU profile of the original full benchmark had 1,852 samples. Notable self
samples were GC spin locks (17.2%), wildcard matching (5.7%), path construction
(3.9%), GC allocation (3.9%), and GC marking (3.8%). These percentages cover
the full benchmark, including startup and JSON work. They must not be treated
as a breakdown of the isolated loaded-project call. Stack unwinding did not
give a useful inclusive call tree.

A process trace of the focused mode showed one compiler probe during setup.
Each full description, including the warm-up, ran DMD's generation hook. That
hook starts DUB, probes DMD, runs the cached config executable, and runs Git.
The hook alone took a median of 9.962 ms over 15 runs, with a range of
9.580 to 10.837 ms. This separate measurement is not an exact subtraction
from the full-call timing because its environment differs from the hook call.

The main cost is repeated file discovery and build-settings construction.
Keeping a `Dub` object alive does not preserve these results. Target generation
adds more scans and an unconditional hook call. A suitable next experiment is
to gather only the active build information once, then reuse file-discovery
results until directory contents or build inputs change. Hook reuse needs an
explicit input rule. Source-content edits alone need not change file lists.

The four existing `ut.dub` tests passed after the prototype edit. The focused
mode passed on the small project and Snakebite. No production change remains.
