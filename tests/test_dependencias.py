#!/usr/bin/env python3
"""Regressão: dependências dos plugins com widget entram no apply.

O NCS Visualizer declara `aurora-ncs` e `cava`; o sticker do profiles declara
`ffmpeg`. Plugins sem widget (screen-toolkit) não podem poluir a lista.
"""
import os
import pathlib
import tempfile
import unittest
from importlib.machinery import SourceFileLoader

ROOT = pathlib.Path(__file__).resolve().parents[1]
CLI = ROOT / "profiles" / "bin" / "noctalia-profile"

PLUGIN_TOMLS = {
    "community/ncs-visualizer": (
        'id = "tausif/ncs-visualizer"\ndependencies = ["aurora-ncs", "cava"]\n'),
    "akimitsu/profiles": (
        'id = "victor/profiles"\ndependencies = ["ffmpeg"]\n'),
    "community/spotify-lyrics": (
        'id = "goatnath/spotify-lyrics"\ndependencies = ["playerctl", "syncedlyrics"]\n'),
    "community/screen-toolkit": (
        'id = "alexander/screen-toolkit"\ndependencies = ["apk", "apt-get"]\n'),
}


class DependenciasTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="noctalia-deps-")
        self.root = pathlib.Path(self.tmp.name)
        self.home = self.root / "home"
        self.state = self.home / ".local" / "state"
        self.mat = self.state / "noctalia" / "plugins" / "materialized"
        for rel, text in PLUGIN_TOMLS.items():
            target = self.mat / rel
            target.mkdir(parents=True, exist_ok=True)
            (target / "plugin.toml").write_text(text, encoding="utf-8")

        self._env = {k: os.environ.get(k) for k in
                     ("HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME")}
        os.environ["HOME"] = str(self.home)
        os.environ["XDG_CONFIG_HOME"] = str(self.home / ".config")
        os.environ["XDG_STATE_HOME"] = str(self.state)
        os.environ["XDG_DATA_HOME"] = str(self.home / ".local" / "share")
        self.cli = SourceFileLoader("noctalia_profile_deps", str(CLI)).load_module()

    def tearDown(self):
        for key, value in self._env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        self.tmp.cleanup()

    def manifest(self):
        return {
            "dependencies": ["ffmpeg"],
            "plugins": {"enabled": [
                "tausif/ncs-visualizer", "victor/profiles",
                "goatnath/spotify-lyrics", "alexander/screen-toolkit",
            ]},
            "desktop_widgets": {"widget_types": [
                {"id": "orb", "type": "tausif/ncs-visualizer:orb"},
                {"id": "sticker", "type": "victor/profiles:sticker"},
                {"id": "lyrics", "type": "goatnath/spotify-lyrics:lyrics-desktop"},
            ]},
        }

    def test_apenas_widgets(self):
        deps = set(self.cli.plugin_dependencies(self.manifest(), only_widgets=True))
        self.assertEqual(deps, {"aurora-ncs", "cava", "ffmpeg",
                                "playerctl", "syncedlyrics"})
        self.assertNotIn("apk", deps)
        self.assertNotIn("apt-get", deps)

    def test_sem_filtro_inclui_todos_os_plugins(self):
        deps = set(self.cli.plugin_dependencies(self.manifest()))
        self.assertIn("apk", deps)
        self.assertIn("aurora-ncs", deps)

    def test_instalador_conhecido(self):
        self.assertIn("aurora-ncs", self.cli.DEPENDENCY_INSTALLERS)
        self.assertFalse(self.cli.dependency_available("aurora-ncs"))


if __name__ == "__main__":
    unittest.main()
