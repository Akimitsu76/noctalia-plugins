#!/usr/bin/env python3
"""Testes de portabilidade entre monitores: DP-3 -> eDP-1.

A detecção de outputs é substituída por NOCTALIA_PROFILE_OUTPUTS (JSON),
equivalente a monkeypatch da função detect_outputs() num processo isolado.
"""
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import tomllib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CLI = ROOT / "profiles" / "bin" / "noctalia-profile"
FIXTURES = ROOT / "tests" / "fixtures"

SETTINGS_DP3 = """\
[plugins]
enabled = ["victor/profiles"]

[desktop_widgets]
enabled = true
widget_order = ["w1", "w2", "w3"]

    [desktop_widgets.widget.w1]
    box_height = 200.0
    box_width = 400.0
    cx = 960.0
    cy = 848.0
    output = "DP-3"
    placement_height = 1080.0
    placement_width = 1920.0
    rotation = 0.0
    type = "clock"

        [desktop_widgets.widget.w1.settings]
        show_seconds = true

    [desktop_widgets.widget.w2]
    box_height = 160.0
    box_width = 384.0
    cx = 223.0
    cy = 766.0
    output = "DP-3"
    placement_height = 1080.0
    placement_width = 1920.0
    rotation = 0.0
    type = "victor/profiles:sticker"

    [desktop_widgets.widget.w3]
    box_height = 256.0
    box_width = 256.0
    cx = 1500.0
    cy = 869.0
    output = "DP-3"
    placement_height = 1080.0
    placement_width = 1920.0
    rotation = 0.0
    type = "victor/profiles:label"

[lockscreen_widgets]
enabled = false
widget_order = ["lockscreen-login-box@DP-3"]

    [lockscreen_widgets.widget."lockscreen-login-box@DP-3"]
    cx = 960.0
    cy = 898.0
    output = "DP-3"
    placement_height = 1080.0
    placement_width = 1920.0
    type = "login_box"

[wallpaper]
fill_mode = "span"

    [wallpaper.monitors.DP-3]
    path = "~/Imagens/wall.png"

[theme]
mode = "dark"
"""

CURRENT_EDP = [{"connector": "eDP-1", "description": "Internal display",
                "width": 1366, "height": 768, "primary": True}]


class OutputRemapTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="noctalia-remap-test-")
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
            "NOCTALIA_PROFILE_SKIP_FRAMES": "1",
        })

    def tearDown(self):
        self.tmp.cleanup()

    def make_profile(self):
        prof = self.state / "noctalia" / "profiles" / "desktop-principal"
        prof.mkdir(parents=True, exist_ok=True)
        (prof / "config").mkdir(exist_ok=True)
        (prof / "config" / "config.toml").write_text('[plugins]\nauto_update = "all"\n',
                                                      encoding="utf-8")
        (prof / "settings.toml").write_text(SETTINGS_DP3, encoding="utf-8")
        (prof / "assets").mkdir(exist_ok=True)
        (prof / "assets" / "wall.png").write_bytes(b"png")
        manifest = {
            "schema_version": 2,
            "name": "desktop-principal",
            "saved_at": "2026-11-24T00:00:00",
            "hostname": "maquina-a",
            "home": "~",
            "outputs": [{"connector": "DP-3", "description": "AOC", "make": "PNP",
                         "model": "27G2WG3", "serial": "YJFNCXA001197",
                         "width": 1920, "height": 1080, "primary": True}],
            "plugins": {"enabled": ["victor/profiles"], "sources": [],
                        "local_plugins": []},
            "desktop_widgets": {
                "widget_order": ["w1", "w2", "w3"],
                "widget_count": 3,
                "widget_types": [
                    {"id": "w1", "type": "clock", "output": "DP-3"},
                    {"id": "w2", "type": "victor/profiles:sticker", "output": "DP-3"},
                    {"id": "w3", "type": "victor/profiles:label", "output": "DP-3"},
                ],
            },
            "assets": {"~/Imagens/wall.png": "assets/wall.png"},
            "checksums": {},
        }
        (prof / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        return prof

    def run_cli(self, *args):
        env = dict(self.env)
        env["NOCTALIA_PROFILE_OUTPUTS"] = json.dumps(CURRENT_EDP)
        return subprocess.run([sys.executable, str(CLI), *args], env=env,
                              capture_output=True, text=True, timeout=120)

    def test_apply_remapeia_dp3_para_edp1(self):
        prof = self.make_profile()
        r = self.run_cli("apply", "desktop-principal", "--yes")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("APPLIED=1", r.stdout)
        self.assertIn("OUTPUT_REMAP=DP-3->eDP-1", r.stdout)
        self.assertIn("WIDGETS_RESTORED=3", r.stdout)
        self.assertIn("PLUGINS_INSTALLED=victor/profiles", r.stdout)
        self.assertNotIn("comando falhou", r.stdout + r.stderr)

        final = (self.state / "noctalia" / "settings.toml").read_text(encoding="utf-8")
        self.assertNotIn("DP-3", final)
        data = tomllib.loads(final)
        widgets = data["desktop_widgets"]["widget"]
        self.assertEqual(data["desktop_widgets"]["widget_order"], ["w1", "w2", "w3"])
        self.assertEqual(set(widgets), {"w1", "w2", "w3"})
        for w in widgets.values():
            self.assertEqual(w["output"], "eDP-1")
            self.assertEqual(w["placement_width"], 1366)
            self.assertEqual(w["placement_height"], 768)
        self.assertEqual(widgets["w1"]["cx"], 683.0)
        self.assertAlmostEqual(widgets["w1"]["cy"], 603.02, places=1)
        self.assertIn("eDP-1", data["wallpaper"]["monitors"])
        self.assertIn("lockscreen-login-box@eDP-1",
                      data["lockscreen_widgets"]["widget"])
        self.assertEqual(data["lockscreen_widgets"]["widget_order"],
                         ["lockscreen-login-box@eDP-1"])

        manifest = json.loads((prof / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["output_remap"], {"DP-3": "eDP-1"})
        self.assertIn("victor/profiles",
                      (self.fake_state / "plugins.txt").read_text(encoding="utf-8"))

    def test_save_registra_outputs_e_contagem_de_widgets(self):
        noctalia_state = self.state / "noctalia"
        noctalia_state.mkdir(parents=True, exist_ok=True)
        (noctalia_state / "settings.toml").write_text(SETTINGS_DP3, encoding="utf-8")

        r = self.run_cli("save", "snapshot")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

        manifest = json.loads(
            (self.state / "noctalia" / "profiles" / "snapshot" / "manifest.json")
            .read_text(encoding="utf-8"))
        self.assertEqual(manifest["schema_version"], 2)
        self.assertEqual(manifest["outputs"], [
            {**CURRENT_EDP[0], "make": "", "model": "", "serial": ""}])
        self.assertEqual(manifest["desktop_widgets"]["widget_count"], 3)
        self.assertEqual(len(manifest["desktop_widgets"]["widget_types"]), 3)
        self.assertEqual(manifest["home"], "~")

    def test_manifest_v1_completa_plugins_pelo_settings(self):
        prof = self.state / "noctalia" / "profiles" / "antigo"
        prof.mkdir(parents=True, exist_ok=True)
        (prof / "settings.toml").write_text(SETTINGS_DP3, encoding="utf-8")
        (prof / "manifest.json").write_text(json.dumps({
            "schema_version": 1, "name": "antigo",
            "wallpapers": {"~/Imagens/wall.png": "assets/wall.png"},
        }), encoding="utf-8")
        (prof / "assets").mkdir(exist_ok=True)
        (prof / "assets" / "wall.png").write_bytes(b"png")

        r = self.run_cli("apply", "antigo", "--yes")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("PLUGINS_INSTALLED=victor/profiles", r.stdout)
        self.assertIn("WIDGETS_RESTORED=3", r.stdout)
        self.assertIn("OUTPUT_REMAP=DP-3->eDP-1", r.stdout)
        self.assertIn("victor/profiles",
                      (self.fake_state / "plugins.txt").read_text(encoding="utf-8"))
        final = (self.state / "noctalia" / "settings.toml").read_text(encoding="utf-8")
        self.assertNotIn("DP-3", final)

    def test_build_output_map_primario_e_espelhamento(self):
        from importlib.machinery import SourceFileLoader
        loader = SourceFileLoader("noctalia_profile_mod", str(CLI))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        mod = importlib.util.module_from_spec(spec)
        loader.exec_module(mod)
        saved = [
            {"connector": "DP-3", "width": 1920, "height": 1080, "primary": True},
            {"connector": "HDMI-A-1", "width": 1920, "height": 1080, "primary": False},
        ]
        one = [{"connector": "eDP-1", "width": 1366, "height": 768, "primary": True}]
        self.assertEqual(mod.build_output_map(saved, one),
                         {"DP-3": "eDP-1", "HDMI-A-1": "eDP-1"})
        two = [*one, {"connector": "HDMI-1", "width": 2560, "height": 1440,
                      "primary": False}]
        self.assertEqual(mod.build_output_map(saved, two),
                         {"DP-3": "eDP-1", "HDMI-A-1": "HDMI-1"})
        # conector que já existe não é alterado
        same = [{"connector": "DP-3", "width": 1920, "height": 1080, "primary": True}]
        self.assertEqual(mod.build_output_map(saved, same),
                         {"DP-3": "DP-3", "HDMI-A-1": "DP-3"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
