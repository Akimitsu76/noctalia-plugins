#!/usr/bin/env python3
"""Falso `noctalia` usado pelos testes: implementa só os IPCs do CLI."""
import os
import pathlib
import sys

state = pathlib.Path(os.environ["FAKE_NOCTALIA_STATE"])
home = pathlib.Path(os.environ["HOME"])
noctalia_state = home / ".local" / "state" / "noctalia"
a = sys.argv[1:]


def read(name):
    f = state / name
    return f.read_text(encoding="utf-8") if f.exists() else ""


def append(name, line):
    state.mkdir(parents=True, exist_ok=True)
    with (state / name).open("a", encoding="utf-8") as f:
        f.write(line + "\n")


if a == ["--version"]:
    print("noctalia-test 5.0")

elif a == ["msg", "plugins", "source", "list"]:
    print(read("sources.txt"), end="")

elif a[:4] == ["msg", "plugins", "source", "add"]:
    name, kind, location = a[4], a[5], a[6]
    append("sources.txt", f"{name} {kind} {location}")
    (noctalia_state / "plugins" / "sources" / name / "repo" / ".git").mkdir(
        parents=True, exist_ok=True)

elif a[:3] == ["msg", "plugins", "update"]:
    name = a[3]
    (noctalia_state / "plugins" / "sources" / name / "repo" / ".git").mkdir(
        parents=True, exist_ok=True)

elif a == ["msg", "plugins", "list"]:
    print(read("plugins.txt"), end="")

elif a[:3] == ["msg", "plugins", "enable"]:
    pid = a[3]
    append("enable-calls.txt", pid)
    append("plugins.txt", f"{pid} [test] 1.0.0 enabled")
    if os.environ.get("FAKE_NOCTALIA_NO_MATERIALIZE") != "1":
        (noctalia_state / "plugins" / "materialized" / "test" / pid.split("/")[-1]).mkdir(
            parents=True, exist_ok=True)

elif a[:2] in (["msg", "config-reload"], ["msg", "desktop-widgets-show"]):
    pass

else:
    sys.exit(f"falso noctalia: comando desconhecido: {' '.join(a)}")
