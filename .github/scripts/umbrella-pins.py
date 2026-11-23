"""Read the umbrella's declared paths and pinned commits without opening members."""

import json
import os
import re
import subprocess
import sys


def records(*args):
    output = subprocess.check_output(["git", *args])
    return os.fsdecode(output).rstrip("\0").split("\0") if output else []


def members():
    modules = {}
    for item in records("config", "--null", "--file", ".gitmodules", "--list"):
        key, _, value = item.partition("\n")
        section, _, field = key.rpartition(".")
        if section.startswith("submodule.") and field in {"path", "url"}:
            values = modules.setdefault(section, {})
            if field in values:
                raise ValueError(f"duplicate {field} for {section}")
            values[field] = value

    slugs = {}
    for section, values in modules.items():
        path = values.get("path")
        url = values.get("url", "").removesuffix(".git")
        match = re.fullmatch(r"https://github\.com/([\w.-]+/[\w.-]+)", url, re.ASCII)
        if not path or not match:
            raise ValueError(f"{section} requires a path and a GitHub repository URL")
        if path in slugs:
            raise ValueError(f"duplicate declared path {path!r}")
        slugs[path] = match[1]

    pins = {}
    for item in records("ls-tree", "-rz", "--full-tree", "HEAD"):
        metadata, path = item.split("\t", 1)
        mode, _, sha = metadata.split()
        if mode == "160000":
            pins[path] = sha

    missing = sorted(slugs.keys() - pins.keys())
    extra = sorted(pins.keys() - slugs.keys())
    if missing or extra:
        raise ValueError(f"declared without gitlink: {missing!r}; gitlink without declaration: {extra!r}")
    if not slugs:
        raise ValueError("no submodule members found")

    return [{"path": path, "slug": slug, "sha": pins[path]} for path, slug in slugs.items()]


if __name__ == "__main__":
    try:
        print(json.dumps(members()))
    except ValueError as error:
        sys.exit(str(error))
