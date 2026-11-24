#!/usr/bin/env python3
"""Testes de integração: snapshot v2 + reinstalação automática na 'máquina B'.

Não usa o Noctalia real: um falso `noctalia` (e um falso `git`) implementam só
os IPCs que o CLI chama, com HOME/XDG_* isolados em diretórios temporários.
"""
import base64
import io
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CLI = ROOT / "profiles" / "bin" / "noctalia-profile"
FIXTURES = ROOT / "tests" / "fixtures"
PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)


class ProfileMachineBTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="noctalia-profile-test-")
        self.root = pathlib.Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("noctalia", "git"):
            dst = self.bin / name
            shutil.copy2(FIXTURES / f"fake_{name}.py", dst)
            dst.chmod(0o755)
        self.a = self.make_machine("A")
        self.b = self.make_machine("B")
        self.populate_machine_a()
        self.save_and_export()

    def tearDown(self):
        self.tmp.cleanup()

    # ── helpers ──────────────────────────────────────────────────────────────
    def make_machine(self, label):
        home = self.root / f"machine-{label}"
        cfg = home / ".config"
        state = home / ".local" / "state"
        data = home / ".local" / "share"
        fake_state = home / "fake-state"
        for d in (cfg, state, data, fake_state):
            d.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ)
        env.update({
            "HOME": str(home),
            "XDG_CONFIG_HOME": str(cfg),
            "XDG_STATE_HOME": str(state),
            "XDG_DATA_HOME": str(data),
            "PATH": str(self.bin) + os.pathsep + env.get("PATH", ""),
            "FAKE_NOCTALIA_STATE": str(fake_state),
            "NOCTALIA_PROFILE_SKIP_FRAMES": "1",
        })
        return {"home": home, "cfg": cfg, "state": state, "data": data,
                "fake": fake_state, "env": env}

    def run_cli(self, machine, *args):
        return subprocess.run(
            [sys.executable, str(CLI), *map(str, args)],
            env=machine["env"], capture_output=True, text=True, timeout=120,
        )

    def populate_machine_a(self):
        m = self.a
        home, cfg, state = m["home"], m["cfg"], m["state"]
        (home / "Imagens").mkdir(parents=True, exist_ok=True)
        (home / ".fonts").mkdir(parents=True, exist_ok=True)
        (home / "Imagens" / "wall.png").write_bytes(PNG)
        (home / "Imagens" / "avatar.png").write_bytes(PNG)
        (home / ".fonts" / "Gothic.ttf").write_bytes(b"fake-font")

        cfg_noctalia = cfg / "noctalia"
        (cfg_noctalia / "plugins" / "localfoo").mkdir(parents=True, exist_ok=True)
        (cfg_noctalia / "plugins" / "localfoo" / "plugin.toml").write_text(
            'id = "foo/bar"\n', encoding="utf-8")
        (cfg_noctalia / "config.toml").write_text(
            f'[plugins]\nauto_update = "all"\nwallpaper = "{home}/Imagens/wall.png"\n',
            encoding="utf-8")

        noctalia_state = state / "noctalia"
        plugin_data = noctalia_state / "plugins" / "data" / "victor" / "profiles"
        plugin_data.mkdir(parents=True, exist_ok=True)
        (plugin_data / "settings.toml").write_text('meu_valor = 42\n', encoding="utf-8")
        frames = noctalia_state / "frames"
        frames.mkdir(parents=True, exist_ok=True)
        (frames / "gothic-frame-01.png").write_bytes(PNG)

        (noctalia_state / "plugins" / "sources" / "akimitsu" / "repo" / ".git").mkdir(
            parents=True, exist_ok=True)
        (m["fake"] / "sources.txt").write_text(
            "akimitsu git https://github.com/Akimitsu76/noctalia-plugins\n"
            f"local path {cfg_noctalia / 'plugins' / 'localfoo'}\n",
            encoding="utf-8")
        (m["fake"] / "plugins.txt").write_text(
            "victor/profiles [akimitsu] 1.4.3 enabled\n"
            "foo/bar [local] 1.0.0 enabled\n", encoding="utf-8")

        (noctalia_state / "settings.toml").write_text(f"""\
[plugins]
enabled = ["victor/profiles", "foo/bar"]

[[plugins.source]]
name = "akimitsu"
kind = "git"
location = "https://github.com/Akimitsu76/noctalia-plugins"

[[plugins.source]]
name = "local"
kind = "path"
location = "{cfg_noctalia / 'plugins' / 'localfoo'}"

[desktop_widgets]
widget_order = ["clock", "media"]

[desktop_widgets.widget.clock.settings]
text = "oi"

[widget.clock]
font = "{home}/.fonts/Gothic.ttf"

[plugin_settings."victor/profiles"]
profiles_dir = ""

[plugin_settings."foo/bar"]
image_path = "{home}/Imagens/avatar.png"

[bar.default]
enabled = true

[theme]
name = "gothic"

[wallpaper]
default = "{home}/Imagens/wall.png"

[shell]
gaps = 16
""", encoding="utf-8")

    def save_and_export(self):
        r = self.run_cli(self.a, "save", "fixture")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("PROFILE=fixture", r.stdout)
        self.tar_path = self.root / "fixture.tar.gz"
        r = self.run_cli(self.a, "export", "fixture", self.tar_path)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(self.tar_path.is_file())

    # ── testes ───────────────────────────────────────────────────────────────
    def test_01_snapshot_v2_e_sem_caminho_absoluto_no_pacote(self):
        with tarfile.open(self.tar_path, "r:gz") as tf:
            members = tf.getmembers()
            names = {m.name for m in members}
            for required in ("manifest.json", "settings.toml", "config/config.toml",
                             "plugins-data/victor/profiles/settings.toml",
                             "frames/gothic-frame-01.png", "local-plugins/local/plugin.toml"):
                self.assertIn(required, names, f"falta no pacote: {required}")

            for m in members:
                self.assertFalse(m.name.startswith("/"), m.name)
                self.assertNotIn("..", pathlib.PurePosixPath(m.name).parts, m.name)
                if m.issym() or m.islnk():
                    self.assertFalse(pathlib.PurePosixPath(m.linkname).is_absolute())
                    self.assertNotIn("..", pathlib.PurePosixPath(m.linkname).parts)

            manifest = json.load(tf.extractfile("manifest.json"))
            self.assertEqual(manifest["schema_version"], 2)
            self.assertEqual(manifest["name"], "fixture")
            self.assertEqual(manifest["plugins"]["enabled"],
                             ["victor/profiles", "foo/bar"])
            self.assertEqual(
                {s["name"] for s in manifest["plugins"]["sources"]},
                {"akimitsu", "local"})
            self.assertEqual(
                next(s for s in manifest["plugins"]["sources"]
                     if s["name"] == "akimitsu")["revision"], "a" * 40)
            self.assertEqual(manifest["desktop_widgets"]["widget_order"],
                             ["clock", "media"])
            self.assertEqual(len(manifest["assets"]), 3)
            self.assertIn("checksums", manifest)

            home_a = str(self.a["home"])
            for m in members:
                if not m.isfile() or m.name == "manifest.json":
                    continue
                data = tf.extractfile(m).read()
                self.assertNotIn(home_a.encode(), data,
                                 f"path absoluto vazou em {m.name}")

    def test_02_import_na_maquina_b_instala_e_restaura_tudo(self):
        r = self.run_cli(self.b, "import", self.tar_path, "--yes")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("PROFILE=fixture", r.stdout)
        self.assertIn("APPLIED=1", r.stdout)
        self.assertNotIn("comando falhou", r.stdout + r.stderr)
        installed = next((l for l in r.stdout.splitlines()
                          if l.startswith("INSTALLED_PLUGINS=")), "")
        for pid in ("victor/profiles", "foo/bar", "source:akimitsu", "source:local"):
            self.assertIn(pid, installed)
        self.assertIn("MISSING_PLUGINS=", r.stdout)

        # fontes e plugins foram efetivamente adicionados/habilitados
        sources = (self.b["fake"] / "sources.txt").read_text(encoding="utf-8")
        self.assertIn("akimitsu git https://github.com/Akimitsu76/noctalia-plugins", sources)
        self.assertIn("local path ", sources)
        plugins = (self.b["fake"] / "plugins.txt").read_text(encoding="utf-8")
        self.assertIn("victor/profiles", plugins)
        self.assertIn("foo/bar", plugins)

        # settings.toml idêntico onde importa
        settings_b = tomllib.loads(
            (self.b["state"] / "noctalia" / "settings.toml").read_text(encoding="utf-8"))
        self.assertEqual(settings_b["desktop_widgets"]["widget_order"],
                         ["clock", "media"])
        self.assertEqual(settings_b["plugin_settings"]["foo/bar"]["image_path"],
                         str(self.b["home"] / "Imagens" / "avatar.png"))
        self.assertEqual(settings_b["wallpaper"]["default"],
                         str(self.b["home"] / "Imagens" / "wall.png"))
        self.assertEqual(settings_b["shell"]["gaps"], 16)
        path_location = next(s["location"] for s in settings_b["plugins"]["source"]
                             if s["name"] == "local")
        self.assertIn("user-plugins/local", path_location)
        self.assertNotIn(str(self.a["home"]), path_location)

        # config/, dados de plugin, plugins locais, frames e assets
        cfg_b = self.b["cfg"] / "noctalia"
        self.assertIn("auto_update", (cfg_b / "config.toml").read_text(encoding="utf-8"))
        self.assertFalse((cfg_b / "config.toml").read_text(encoding="utf-8").find(str(self.a["home"])) >= 0)
        self.assertEqual(
            (self.b["state"] / "noctalia" / "plugins" / "data" / "victor" / "profiles" / "settings.toml")
            .read_text(encoding="utf-8").strip(), "meu_valor = 42")
        self.assertTrue((self.b["data"] / "noctalia" / "user-plugins" / "local" / "plugin.toml").is_file())
        self.assertTrue((self.b["state"] / "noctalia" / "frames" / "gothic-frame-01.png").is_file())
        for rel in ("Imagens/wall.png", "Imagens/avatar.png", ".fonts/Gothic.ttf"):
            self.assertTrue((self.b["home"] / rel).is_file(), rel)

    def test_03_tar_malicioso_e_rejeitado(self):
        evil = self.root / "evil.tar.gz"
        with tarfile.open(evil, "w:gz") as tf:
            def add(name, data):
                info = tarfile.TarInfo(name)
                info.size = len(data)
                tf.addfile(info, io.BytesIO(data))
            add("manifest.json", b'{"schema_version": 2, "name": "evil"}')
            add("../evil.txt", b"vazou")
            add("/etc/evil.txt", b"vazou")
            info = tarfile.TarInfo("link")
            info.type = tarfile.SYMTYPE
            info.linkname = "/etc/passwd"
            tf.addfile(info)
        r = self.run_cli(self.b, "import", evil, "--yes")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("caminho inseguro", r.stderr + r.stdout)

    def test_04_compatibilidade_manifest_v1(self):
        v1 = self.root / "v1"
        v1.mkdir()
        (v1 / "manifest.json").write_text(json.dumps({
            "schema_version": 1,
            "name": "antigo",
            "wallpapers": {"~/wall.png": "assets/wall.png"},
            "plugins": {"enabled": [], "sources": []},
        }), encoding="utf-8")
        (v1 / "settings.toml").write_text('[plugins]\nenabled = []\n', encoding="utf-8")
        (v1 / "assets").mkdir()
        (v1 / "assets" / "wall.png").write_bytes(PNG)
        tar = self.root / "v1.tar.gz"
        with tarfile.open(tar, "w:gz") as tf:
            for item in sorted(v1.rglob("*")):
                tf.add(item, arcname=str(item.relative_to(v1)), recursive=False)

        r = self.run_cli(self.b, "import", tar, "--yes", "--no-apply")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("PROFILE=antigo", r.stdout)
        imported = json.loads(
            (self.b["state"] / "noctalia" / "profiles" / "antigo" / "manifest.json")
            .read_text(encoding="utf-8"))
        self.assertEqual(imported["schema_version"], 1)
        self.assertIn("imported_at", imported)

        r = self.run_cli(self.b, "apply", "antigo", "--dry-run")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("DRY_RUN=1", r.stdout)
        self.assertIn("PROFILE=antigo", r.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
