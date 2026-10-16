import importlib.util
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "verify_macos_build", ROOT / "scripts/verify-macos-build.py")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)

METADATA = """Load command 11
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform MACOS
    minos 13.0
      sdk 27.0
   ntools 1
"""


class MacOSBuildTests(unittest.TestCase):
    def test_accepts_new_sdk_without_raising_deployment_target(self):
        CHECK.validate_load_commands(METADATA, "13.0.0", "27")

    def test_rejects_incompatible_or_missing_metadata(self):
        for output in ("", METADATA.replace("13.0", "27.0"),
                       METADATA.replace("27.0", "26.5"),
                       METADATA.replace("27.0", "13.0"),
                       METADATA.replace("MACOS", "MACCATALYST"),
                       METADATA + "sdk 27.0\n"):
            with self.subTest(output=output), self.assertRaises(ValueError):
                CHECK.validate_load_commands(output, "13.0", "27.0")

    def test_checks_each_slice_and_resources(self):
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp)
            resources = app / "Contents/Resources"
            resources.mkdir(parents=True)
            for name in ("agentdeckd.py", "session_performance.py", "VERSION", "AgentDeck_AgentDeckKit.bundle"):
                (resources / name).touch()
            with (app / "Contents/Info.plist").open("wb") as stream:
                plistlib.dump({"CFBundleExecutable": "AgentDeck",
                               "LSMinimumSystemVersion": "13.0"}, stream)
            with patch.object(CHECK, "command", side_effect=[
                    "x86_64 arm64", METADATA, METADATA]) as run:
                CHECK.verify(app, "13.0", "27.0")
                self.assertEqual(run.call_args_list[1].args[3], "arm64")
                self.assertEqual(run.call_args_list[2].args[3], "x86_64")
            with patch.object(CHECK, "command", return_value="arm64"):
                with self.assertRaisesRegex(ValueError, "universal"):
                    CHECK.verify(app, "13.0", "27.0")
            with patch.object(CHECK, "command", side_effect=[
                    "arm64 x86_64", METADATA, METADATA.replace("27.0", "13.0")]):
                with self.assertRaisesRegex(ValueError, "Binary SDK"):
                    CHECK.verify(app, "13.0", "27.0")
            with patch.object(CHECK, "command", side_effect=OSError("tool missing")):
                with self.assertRaises(OSError):
                    CHECK.verify(app, "13.0", "27.0")
            (resources / "session_performance.py").unlink()
            with patch.object(CHECK, "command", side_effect=[
                    "arm64 x86_64", METADATA, METADATA]):
                with self.assertRaisesRegex(ValueError, "Missing bundled"):
                    CHECK.verify(app, "13.0", "27.0")

    def test_cli_failure_returns_nonzero(self):
        with tempfile.TemporaryDirectory() as temp:
            result = subprocess.run(
                [sys.executable, str(ROOT / "scripts/verify-macos-build.py"),
                 temp, "--sdk-version", "27.0"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Build metadata check failed", result.stderr)
        self.assertNotIn("verified", result.stdout)


if __name__ == "__main__":
    unittest.main()
