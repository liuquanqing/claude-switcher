#!/usr/bin/env python3
"""Signing boundary checks with fictional identities and temporary fixtures only."""
import importlib.util
import json
from pathlib import Path
import tempfile
import sys
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("release", Path(__file__).with_name("developer-id-release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class SigningChecks(unittest.TestCase):
    def test_inventory_requires_all_three_components(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary)
            for name in release.BINARIES:
                p = app / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(bytes.fromhex("cffaedfe") + b"fictional binary")
            release.inventory(app)
            (app / "unexpected").write_bytes(bytes.fromhex("cffaedfe"))
            with self.assertRaisesRegex(ValueError, "Unexpected Mach-O"):
                release.inventory(app)

    def test_symlink_does_not_escape_signing_inventory(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary)
            (app / "external").symlink_to("/Applications")
            with self.assertRaisesRegex(ValueError, "symlink"):
                release.inventory(app)

    def test_wrong_team_missing_timestamp_or_runtime_rejected(self):
        good = "Authority=Developer ID Application: Fictional\nTeamIdentifier=FAKE123456\nTimestamp=Nov 2, 2026\nflags=0x10000(runtime)\n"
        cases = [good.replace("FAKE123456", "OTHER12345"), good.replace("Timestamp=", "Signed Time="),
                 good.replace("(runtime)", "(adhoc)"), good.replace("Developer ID Application:", "Apple Development:")]
        for detail in cases:
            with self.subTest(detail=detail), patch.object(release, "run", side_effect=["", detail]):
                with self.assertRaises(ValueError):
                    release.verify_code(Path("fictional"), "FAKE123456")
        with patch.object(release, "run", side_effect=["", good]):
            self.assertEqual(release.verify_code(Path("fictional"), "FAKE123456"), good)

    def test_sign_has_timestamp_and_runtime_without_deep(self):
        with patch.object(release, "run") as run:
            release.sign(Path("fictional"), "F" * 40)
        command = run.call_args.args
        self.assertIn("--timestamp", command)
        self.assertIn("runtime", command)
        self.assertNotIn("--deep", command)

    def test_pending_and_rejected_notary_results_never_staple(self):
        for status in ("In Progress", "Invalid"):
            with tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary) / "evidence"
                directory.mkdir()
                state = {"notarization": {"app": {"id": "fictional-submission"}}}
                calls = []

                def fake_run(*args):
                    calls.append(args)
                    return json.dumps({"status": status})

                with patch.object(release, "run", side_effect=fake_run):
                    with self.assertRaisesRegex(ValueError, "not stapled"):
                        release.check_notary("app", state, directory, "fictional-profile")
                self.assertFalse(any("stapler" in command for command in calls))
                saved = json.loads((directory.parent / "RELEASE-MANIFEST.json").read_text())
                self.assertEqual(saved["notarization"]["app"]["status"], status)
                self.assertEqual(any("log" in command for command in calls), status == "Invalid")

    def test_missing_submission_id_never_queries_or_uploads(self):
        with patch.object(release, "run") as run:
            with self.assertRaisesRegex(ValueError, "No app submission ID"):
                release.check_notary("app", {"notarization": {"app": {}}}, Path("fictional"), "fictional")
            run.assert_not_called()

    def test_acceptance_records_id_status_and_downloads_log(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "evidence"
            directory.mkdir()
            state = {"notarization": {"app": {"id": "fictional-submission"}}}
            with patch.object(release, "run", return_value=json.dumps({"status": "Accepted"})) as run:
                release.check_notary("app", state, directory, "fictional-profile")
            self.assertEqual(state["notarization"]["app"]["status"], "Accepted")
            self.assertIn("log", run.call_args.args)


if __name__ == "__main__":
    unittest.main()
