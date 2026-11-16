#!/usr/bin/env bash
set -euo pipefail
compiler=$1
collector=$2
output=$3
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project_dir=$(cd -- "$script_dir/../.." && pwd)
if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then
  printf 'The array allocation cache build needs x86-64 Linux.\n' >&2
  exit 1
fi
compiler_version=$("$compiler" --version)
if [[ $compiler_version != *'D compiler (1.43.0)'* ||
      $compiler_version != *'DMD v2.113.0'* ]]; then
  printf 'The array allocation cache build needs LDC 1.43.0 (D 2.113.0).\n' >&2
  exit 1
fi
input_hash=d4dbced2493d347d6682f35fc88fb45ad4440e3b3e0036995d60e1f4f3c41592
if ! printf '%s  %s\n' "$input_hash" "$collector" | sha256sum --check --status; then
  printf 'Unexpected array allocation collector source checksum for %s.\n' "$collector" >&2
  exit 1
fi
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
overlay="$temporary/array_allocation_collector.d"
patch --silent --output "$overlay" "$collector" "$script_dir/conservative.patch"
"$compiler" -O3 -release -link-defaultlib-shared -d-version=ArrayAllocationCache \
  -I"$project_dir/source" -c "$overlay" -of="$output"
