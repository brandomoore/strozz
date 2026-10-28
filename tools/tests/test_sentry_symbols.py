import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools/upload-sentry-symbols.sh"


class SentrySymbolTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.marker = self.root / "upload.json"
        self.environment = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                                MOCK_UPLOAD_ARGUMENTS=str(self.marker))
        self.executable("sentry-cli", """#!/usr/bin/env python3
import json, os, pathlib, sys
pathlib.Path(os.environ["MOCK_UPLOAD_ARGUMENTS"]).write_text(json.dumps(sys.argv[1:]))
sys.exit(int(os.environ.get("MOCK_UPLOAD_EXIT", "0")))
""")
        self.executable("xcrun", """#!/usr/bin/env python3
import os
if os.environ.get("MOCK_EMPTY_SYMBOLS") != "1":
    print("UUID: 11111111-1111-1111-1111-111111111111 (arm64) fixture")
""")

    def tearDown(self):
        self.temporary.cleanup()

    def executable(self, name, source):
        path = self.bin / name
        path.write_text(source)
        path.chmod(0o700)

    def run_upload(self, path):
        return subprocess.run(["bash", str(SCRIPT), str(path)], env=self.environment,
                              text=True, capture_output=True, timeout=20)

    def test_destination_is_fixed_and_raw_sources_are_never_requested(self):
        symbols = self.root / "StrozzMobile.app.dSYM"
        symbols.mkdir()
        result = self.run_upload(symbols)
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = json.loads(self.marker.read_text())
        self.assertEqual(arguments[:2], ["debug-files", "upload"])
        self.assertEqual(arguments[arguments.index("--org") + 1], "plozz")
        self.assertEqual(arguments[arguments.index("--project") + 1], "strozz")
        self.assertIn("--no-sources", arguments)
        self.assertNotIn("--include-sources", arguments)
        self.assertEqual(arguments[-1], str(symbols))

    def test_upload_failure_is_not_reported_as_success(self):
        symbols = self.root / "Strozz.app.dSYM"
        symbols.mkdir()
        self.environment["MOCK_UPLOAD_EXIT"] = "7"
        self.assertEqual(self.run_upload(symbols).returncode, 7)

    def test_wrong_app_and_empty_symbols_never_reach_the_service(self):
        wrong = self.root / "OtherApp.app.dSYM"
        wrong.mkdir()
        self.assertNotEqual(self.run_upload(wrong).returncode, 0)
        self.assertFalse(self.marker.exists())
        empty = self.root / "Strozz.app.dSYM"
        empty.mkdir()
        self.environment["MOCK_EMPTY_SYMBOLS"] = "1"
        self.assertNotEqual(self.run_upload(empty).returncode, 0)
        self.assertFalse(self.marker.exists())

    def test_archive_identity_is_checked_before_upload(self):
        archive = self.root / "Other.xcarchive"
        app = archive / "Products/Applications/Other.app"
        app.mkdir(parents=True)
        (archive / "Info.plist").write_bytes(plistlib.dumps({
            "ApplicationProperties": {"ApplicationPath": "Applications/Other.app"}
        }))
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.example.Other"
        }))
        self.assertNotEqual(self.run_upload(archive).returncode, 0)
        self.assertFalse(self.marker.exists())


if __name__ == "__main__":
    unittest.main()
