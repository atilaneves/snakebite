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
