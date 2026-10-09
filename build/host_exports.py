#!/usr/bin/env python3
"""Make an exact test-host map from the host compiler's linker names."""

import pathlib
import subprocess
import sys


def main():
    output = pathlib.Path(sys.argv[1])
    result = subprocess.run(sys.argv[2:], capture_output=True, text=True)
    if result.returncode:
        sys.stderr.write(result.stdout + result.stderr)
        return result.returncode
    exports = {}
    for line in (result.stdout + result.stderr).splitlines():
        if not line.startswith("SB_EXPORT\t"):
            continue
        _, name, consumer = line.split("\t")
        if not name or any(char in name for char in '*?[];" \n'):
            raise ValueError(f"Not an exact linker name: {name!r}")
        exports.setdefault(name, set()).add(consumer)
    if not exports:
        raise ValueError("The compiler emitted no designated test fixtures")
    base = pathlib.Path(__file__).with_name("host-exports.map").read_text()
    entries = "".join(
        f"        /* {', '.join(sorted(consumers))} */\n        {name};\n"
        for name, consumers in sorted(exports.items())
    )
    output.write_text(base.replace("        rt_options;", "        rt_options;\n" + entries))
    return 0


if __name__ == "__main__":
    sys.exit(main())
