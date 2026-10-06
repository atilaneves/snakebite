# dub keeps a build record for each package name under `~/.dub/cache`, and
# nothing removes it. A test that makes a throw-away dub package names it
# with `dub_name`, and the fixture in conftest.py deletes the record of that
# name when the test is over, also when it failed.

import secrets
import shutil
from pathlib import Path

_names: dict[str, str] = {}


def dub_name(base: str) -> str:
    """A name for the package `base` that no other test uses. The same
    `base` gives the same name until the test is over."""
    if base not in _names:
        _names[base] = f"{base}-{secrets.token_hex(6)}"
    return _names[base]


def forget_dub_names() -> None:
    cache = Path.home() / ".dub" / "cache"
    for name in _names.values():
        shutil.rmtree(cache / name, ignore_errors=True)
    _names.clear()
