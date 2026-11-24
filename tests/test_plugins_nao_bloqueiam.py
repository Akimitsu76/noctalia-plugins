#!/usr/bin/env python3
"""Regressão: plugin já `enabled` não pode travar o apply.

Na máquina real 8 dos 30 plugins habilitados não têm pasta em
`materialized/`. O código antigo chamava `plugins enable` e esperava 30s para
cada um (240s), estourando o timeout do painel antes do remapeamento.
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
import tomllib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CLI = ROOT / "profiles" / "bin" / "noctalia-profile"
FIXTURES = ROOT / "tests" / "fixtures"

PLUGINS = [
    "tadomika_ari/config-swap", "noctalia/bongocat", "nightwatch75/dns-switcher",
    "raycursive/discord-voice", "nomadcxx/gamer-mode", "gustav0ar/drive-health",
    "imjustdoingmypart/niri-animations", "salemsayed/niri-active-workspace",
    "raycursive/niri-displays", "alexander/screen-toolkit", "nilsonlinux/speedtest-meter",
    "davemhammer/tailscale", "nightwatch75/todo", "theblackdon/kineticwe-layouts",
    "raell/dashboard", "goatnath/spotify-lyrics", "yocraft/desktop-launcher",
    "yugaaank/better-clock", "victor/fastfetch-desktop", "nomadcxx/gslapper",
    "ishan0121/wallpaper-deck", "theblackdon/theme-switcher",
    "weinguyen/opencode-companion", "noctalia/notes", "shin/lrc",
    "miixz/audio-sticker", "vn1k/cursor", "tylorismusic/gamepad-display",
    "tausif/ncs-visualizer", "victor/profiles",
]
SEM_MATERIALIZED = [
    "victor/fastfetch-desktop", "weinguyen/opencode-companion", "noctalia/notes",
    "shin/lrc", "miixz/audio-sticker", "vn1k/cursor",
    "tylorismusic/gamepad-display", "tausif/ncs-visualizer",
]
WIDGET_TYPES = [
    "clock", "victor/profiles:sticker", "tausif/ncs-visualizer:orb",
    "tylorismusic/gamepad-display:battery", "goatnath/spotify-lyrics:current",
    "victor/fastfetch-desktop:info",
]
CURRENT_EDP = [{"connector": "eDP-1", "description": "Internal display",
                "width": 1366, "height": 768, "primary": True}]


def build_settings():
    ids = [f"w{i:02d}" for i in range(1, 15)]
    lines = ["[plugins]", "enabled = ["]
    lines += [f'    "{p}",' for p in PLUGINS]
    lines += ["]", "", "[desktop_widgets]", "enabled = true",
              "widget_order = [" + ", ".join(f'"{w}"' for w in ids) + "]", ""]
    for i, wid in enumerate(ids):
        lines += [
            f'    [desktop_widgets.widget.{wid}]',
            "    box_height = 200.0", "    box_width = 300.0",
            f"    cx = {100.0 + i * 100.0}", f"    cy = {400.0 + i * 25.0}",
            '    output = "DP-3"', "    placement_height = 1080.0",
            "    placement_width = 1920.0", f'    type = "{WIDGET_TYPES[i % len(WIDGET_TYPES)]}"',
            "",
        ]
    lines += ["[wallpaper]", 'fill_mode = "span"', "",
              "    [wallpaper.monitors.DP-3]", '    path = "~/wall.png"', ""]
    return "\n".join(lines)


class PluginsNaoBloqueiamTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="noctalia-plugins-fast-")
        self.root = pathlib.Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("noctalia", "git"):
            dst = self.bin / name
            shutil.copy2(FIXTURES / f"fake_{name}.py", dst)
            dst.chmod(0o755)
        self.home = self.root / "home"
        self.cfg = self.home / ".config"
        self.state = self.home / ".local" / "state"
        self.fake_state = self.home / "fake-state"
        for d in (self.cfg, self.state, self.fake_state):
            d.mkdir(parents=True, exist_ok=True)
        self.env = dict(os.environ)
        self.env.update({
            "HOME": str(self.home),
            "XDG_CONFIG_HOME": str(self.cfg),
            "XDG_STATE_HOME": str(self.state),
            "XDG_DATA_HOME": str(self.home / ".local" / "share"),
            "PATH": str(self.bin) + os.pathsep + self.env.get("PATH", ""),
            "FAKE_NOCTALIA_STATE": str(self.fake_state),
            "FAKE_NOCTALIA_NO_MATERIALIZE": "1",
            "NOCTALIA_PROFILE_SKIP_FRAMES": "1",
            "NOCTALIA_PROFILE_OUTPUTS": json.dumps(CURRENT_EDP),
        })

        # 30 plugins enabled; 8 deliberadamente SEM diretório materializado.
        (self.fake_state / "plugins.txt").write_text(
            "".join(f"{p} [test] 1.0.0 enabled\n" for p in PLUGINS),
            encoding="utf-8")
        mat = self.state / "noctalia" / "plugins" / "materialized" / "test"
        for pid in PLUGINS:
            if pid not in SEM_MATERIALIZED:
                (mat / pid.split("/", 1)[1]).mkdir(parents=True, exist_ok=True)

        prof = self.state / "noctalia" / "profiles" / "Desktop"
        prof.mkdir(parents=True, exist_ok=True)
        (prof / "config").mkdir(exist_ok=True)
        (prof / "config" / "config.toml").write_text("[plugins]\n", encoding="utf-8")
        (prof / "settings.toml").write_text(build_settings(), encoding="utf-8")
        ids = [f"w{i:02d}" for i in range(1, 15)]
        manifest = {
            "schema_version": 2, "name": "Desktop",
            "saved_at": "2026-11-24T00:00:00", "hostname": "maquina-a", "home": "~",
            "outputs": [{"connector": "DP-3", "width": 1920, "height": 1080,
                         "primary": True}],
            "plugins": {"enabled": PLUGINS, "sources": [], "local_plugins": []},
            "desktop_widgets": {
                "widget_order": ids, "widget_count": 14,
                "widget_types": [{"id": wid, "type": WIDGET_TYPES[i % len(WIDGET_TYPES)],
                                  "output": "DP-3"} for i, wid in enumerate(ids)],
            },
            "assets": {}, "checksums": {},
        }
        (prof / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")

    def tearDown(self):
        self.tmp.cleanup()

    def test_apply_nao_espera_plugin_ja_habilitado(self):
        started = time.monotonic()
        r = subprocess.run([sys.executable, str(CLI), "apply", "Desktop", "--yes"],
                           env=self.env, capture_output=True, text=True, timeout=25)
        elapsed = time.monotonic() - started

        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertLess(elapsed, 10, f"apply demorou {elapsed:.1f}s")
        self.assertIn("APPLIED=1", r.stdout)
        self.assertIn("OUTPUT_REMAP=DP-3->eDP-1", r.stdout)
        self.assertIn("WIDGETS_RESTORED=14", r.stdout)
        self.assertIn("MISSING_PLUGINS=", r.stdout)
        self.assertNotIn("comando falhou", r.stdout + r.stderr)
        self.assertNotIn("ERROR=", r.stdout)

        # Nenhum enable para plugin que já estava enabled (mesmo sem materialized).
        calls = self.fake_state / "enable-calls.txt"
        self.assertFalse(calls.exists() and calls.read_text(encoding="utf-8").strip(),
                         "plugins enable foi chamado para plugin já habilitado")
        self.assertIn("sem diretório em materialized/ (ignorado)", r.stdout)

        final_raw = (self.state / "noctalia" / "settings.toml").read_text(encoding="utf-8")
        self.assertNotIn("DP-3", final_raw)
        final = tomllib.loads(final_raw)
        widgets = final["desktop_widgets"]["widget"]
        self.assertEqual(len(widgets), 14)
        self.assertEqual(final["desktop_widgets"]["widget_order"],
                         [f"w{i:02d}" for i in range(1, 15)])
        for w in widgets.values():
            self.assertEqual(w["output"], "eDP-1")
            self.assertEqual(w["placement_width"], 1366)
            self.assertEqual(w["placement_height"], 768)
        self.assertIn("eDP-1", final["wallpaper"]["monitors"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
