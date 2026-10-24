"""V2 copy isolation: never import the original trans tools or share its DB."""
import hashlib
import importlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from project_paths import PROJECT, WEBSITE
from freeze_image import verify_image


class V2IsolationTests(unittest.TestCase):
    def test_all_tool_modules_belong_to_v2(self):
        for name in ("score_pc.simulator", "score_pc.client", "score_pc.__main__", "score_vectors", "package_score_release"):
            module = importlib.import_module(name)
            self.assertTrue(Path(module.__file__).resolve().is_relative_to(PROJECT))
        module = importlib.import_module("score_vectors")
        self.assertEqual(module.DEST, PROJECT / "tests/vectors")
        self.assertEqual(module.FIXTURE, WEBSITE / "tests/fixtures/v2-golden.json")

    def test_frozen_image_rejects_changed_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / "app.bin").write_bytes(b"image")
            info = {"version": "2.0", "files": {"app.bin": hashlib.sha256(b"image").hexdigest()}, "flash_files": {"0x10000": "app.bin"}}
            (directory / "image.json").write_text(json.dumps(info), encoding="utf-8")
            self.assertEqual(verify_image(directory), info)
            (directory / "app.bin").write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "checksum"):
                verify_image(directory)


if __name__ == "__main__":
    unittest.main()
