# dub keeps a build record for each package name under `~/.dub/cache`, and
# nothing removes it. A test that makes a throw-away dub package names it
# with `dub_name`, and the fixture in conftest.py deletes the record of that
# name when the test is over, also when it failed.
#
# The same fixture fails a test whose recipe has a plain name with a record,
# and deletes that record only if the test made it. It reads only the recipes
# below `tmp_path` at the end of the test: a project made elsewhere, or a
# recipe that the test removed or changed, is not seen. A record that a
# killed run left is not removed.

import json
import re
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


def _cache() -> Path:
    return Path.home() / ".dub" / "cache"


def cache_entries() -> set[str]:
    cache = _cache()
    return {entry.name for entry in cache.iterdir()} if cache.is_dir() else set()


def forget_dub_names() -> None:
    for name in _names.values():
        shutil.rmtree(_cache() / name, ignore_errors=True)
    _names.clear()


_recipe_names = ("dub.sdl", "dub.json", "package.json")
_sdl_string = r'(?:"([^"]*)"|`([^`]*)`)'
_sdl_name = re.compile(rf"^\s*name\s+{_sdl_string}", re.MULTILINE)
_sdl_path_dependency = re.compile(
    rf"^\s*dependency\s+{_sdl_string}[^\n]*\bpath\s*=", re.MULTILINE,
)


def _package_name(dependency: str) -> str:
    return dependency.split(":", 1)[0]


def _json_names(recipe: dict) -> list[str]:
    names = [recipe["name"]] if isinstance(recipe.get("name"), str) else []
    dependencies = recipe.get("dependencies")
    if isinstance(dependencies, dict):
        names += [
            _package_name(name) for name, value in dependencies.items()
            if isinstance(value, dict) and "path" in value
        ]
    for sub in recipe.get("subPackages", []):
        if isinstance(sub, dict):
            names += _json_names(sub)
    return names


def _recipe_package_names(recipe: Path) -> list[str]:
    text = recipe.read_text(encoding="utf-8", errors="replace")
    if recipe.suffix == ".sdl":
        names = [a or b for a, b in _sdl_name.findall(text)]
        return names + [
            _package_name(a or b)
            for a, b in _sdl_path_dependency.findall(text)
        ]
    try:
        recipe_json = json.loads(text)
    except json.JSONDecodeError:
        return []
    return _json_names(recipe_json) if isinstance(recipe_json, dict) else []


def delete_plain_dub_names(root: Path, before: set[str]) -> list[str]:
    """A message for each package name in the dub recipes under `root` that
    did not come from `dub_name` and has a cache record. The record is
    deleted unless its name is in `before`, the entries of the cache when
    the test began."""
    cache = _cache()
    messages: list[str] = []
    for recipe in sorted(root.rglob("*")):
        if recipe.name not in _recipe_names or not recipe.is_file():
            continue
        for name in _recipe_package_names(recipe):
            record = cache / name
            if name in _names.values() or not record.is_dir():
                continue
            if name not in before:
                shutil.rmtree(record, ignore_errors=True)
            messages.append(
                f"package {name} in {recipe}: use dub_name() for the name"
            )
    return messages
