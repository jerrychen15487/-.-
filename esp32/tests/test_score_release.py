"""A release must describe one completed build, never stale images plus new config."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from build_receipt import begin, finish, verify
from package_score_release import copy


class BuildReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name)
        self.build = self.project / "build-test"
        self.build.mkdir()
        for name in ("CMakeLists.txt", "dependencies.lock", "tools/build.ps1",
                     "tools/build_receipt.py", "main/app_main.c", "sdkconfig.defaults"):
            path = self.project / name
            path.parent.mkdir(exist_ok=True)
            path.write_text("fixture\n", encoding="utf-8")
        self.config = self.project / "sdkconfig.test"
        self.config.write_text("CONFIG_SCORE_ENABLED=y\n", encoding="utf-8")
        (self.build / "config").mkdir()
        self.json("config/sdkconfig.json", {"SCORE_ENABLED": True})
        for name in ("sdkconfig.h", "sdkconfig.cmake"):
            (self.build / "config" / name).write_text("compiled-config", encoding="utf-8")
        self.desc = {"project_path": str(self.project), "config_file": str(self.config),
                     "app_elf": "app.elf", "idf_path": "test-sdk", "git_revision": "v-test",
                     "c_compiler": "test-gcc", "target": "esp32s3"}
        self.json("project_description.json", self.desc)
        self.json("flasher_args.json", {"flash_files": {"0x0": "boot.bin", "0x10000": "app.bin"}})
        for name in ("boot.bin", "app.bin", "app.elf", "flash_args"):
            (self.build / name).write_bytes(name.encode())

    def json(self, name, value):
        (self.build / name).write_text(json.dumps(value), encoding="utf-8")

    def success(self):
        begin(self.project, self.build)
        finish(self.project, self.build, "fixture-commit")

    def test_success_and_document_only_changes(self):
        self.success()
        (self.project / "VALIDATION.md").write_text("new software evidence", encoding="utf-8")
        self.assertEqual(verify(self.project, self.build)["source_commit"], "fixture-commit")
        self.assertFalse(verify(self.project, self.build)["score_diagnostics"])

    def test_diagnostic_build_receipt_uses_compiled_configuration(self):
        self.config.write_text("CONFIG_SCORE_ENABLED=y\nCONFIG_SCORE_DIAGNOSTICS=y\n", encoding="utf-8")
        self.json("config/sdkconfig.json", {"SCORE_ENABLED": True, "SCORE_DIAGNOSTICS": True})
        self.success()
        self.assertTrue(verify(self.project, self.build)["score_diagnostics"])

    def test_missing_interrupted_and_failed_build_cannot_use_previous_images(self):
        with self.assertRaises(FileNotFoundError):
            verify(self.project, self.build)
        self.success()
        begin(self.project, self.build)
        with self.assertRaisesRegex(ValueError, "successful build receipt"):
            verify(self.project, self.build)

    def test_source_and_new_source_require_rebuild(self):
        for name in ("main/app_main.c", "main/new_module.c", "sdkconfig.defaults"):
            with self.subTest(name=name):
                self.success()
                (self.project / name).write_text("changed\n", encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "firmware inputs differ"):
                    verify(self.project, self.build)

    def test_mid_build_source_change_does_not_certify_mixed_artifacts(self):
        begin(self.project, self.build)
        (self.project / "main/app_main.c").write_text("changed", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "changed during build"):
            finish(self.project, self.build, "fixture-commit")
        with self.assertRaisesRegex(ValueError, "successful build receipt"):
            verify(self.project, self.build)

    def test_config_and_image_changes_are_rejected(self):
        self.success()
        self.config.write_text("CONFIG_SCORE_ENABLED=n\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "sdkconfig changed"):
            verify(self.project, self.build)
        self.json("config/sdkconfig.json", {"SCORE_ENABLED": False})
        self.success()
        (self.build / "app.bin").write_bytes(b"stale or substituted")
        with self.assertRaisesRegex(ValueError, "artifact changed: app.bin"):
            verify(self.project, self.build)

    def test_config_change_before_receipt_cannot_certify_old_binary(self):
        begin(self.project, self.build)
        self.config.write_text("CONFIG_SCORE_ENABLED=n\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "configuration generated for compilation"):
            finish(self.project, self.build, "fixture-commit")
        with self.assertRaisesRegex(ValueError, "successful build receipt"):
            verify(self.project, self.build)

    def test_copy_rejects_artifact_change_after_verification(self):
        self.success()
        receipt = verify(self.project, self.build)
        (self.build / "app.bin").write_bytes(b"another build")
        with self.assertRaisesRegex(ValueError, "Build changed during packaging"):
            copy(self.build / "app.bin", self.project / "release/app.bin", receipt["artifacts"]["app.bin"])

    def test_changed_flash_addresses_or_config_path_are_rejected(self):
        self.success()
        self.json("flasher_args.json", {"flash_files": {"0x0": "app.bin", "0x10000": "boot.bin"}})
        with self.assertRaisesRegex(ValueError, "artifact changed: flasher_args.json"):
            verify(self.project, self.build)
        self.success()
        self.desc["config_file"] = str(self.build / "different-config")
        self.json("project_description.json", self.desc)
        with self.assertRaisesRegex(ValueError, "artifact changed: project_description.json"):
            verify(self.project, self.build)


if __name__ == "__main__":
    unittest.main()
