#!/usr/bin/env python3
"""Signing boundary checks with fictional identities and temporary fixtures only."""
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import tempfile
import sys
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("release", Path(__file__).with_name("developer-id-release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class SigningChecks(unittest.TestCase):
    def test_prepared_metadata_identifies_preview_without_demo_or_identity_change(self):
        info = release.prepare_preview_metadata({"CFBundleIdentifier": release.BUNDLE_ID})
        self.assertEqual(info["CFBundleIdentifier"], "dev.claudeswitcher.candidate")
        self.assertEqual(info["CFBundleShortVersionString"], "1.3.6")
        self.assertEqual(info["CSReleaseChannel"], "preview")
        self.assertEqual(info["CSReleaseVersion"], "1.3.6-rc.8")
        self.assertEqual(info["CFBundleVersion"], "20261106.8.5")
        self.assertIn("预览", info["CFBundleDisplayName"])
        self.assertIn("预览", info["CFBundleName"])
        self.assertFalse(any(k.startswith("CSPreview") for k in info))
        self.assertNotIn("Demo", info["CFBundleDisplayName"])

    def test_preparation_rejects_demo_preferences_and_changed_bundle_id(self):
        for info in ({"CFBundleIdentifier": release.BUNDLE_ID, "CSPreviewMode": True},
                     {"CFBundleIdentifier": "fictional.other.app"}):
            with self.subTest(info=info), self.assertRaises(ValueError):
                release.prepare_preview_metadata(info)

    def test_channel_gate_rejects_missing_markers_wrong_version_and_ordinary_display_name(self):
        valid = release.prepare_preview_metadata({"CFBundleIdentifier": release.BUNDLE_ID})
        for key, value in (("CSReleaseChannel", None), ("CSReleaseChannel", "stable"),
                           ("CSUpdaterProtocolVersion", None), ("CSUpdaterProtocolVersion", 2),
                           ("CSReleaseVersion", None), ("CSReleaseVersion", "1.3.6"),
                           ("CSReleaseVersion", "1.3.6-rc.1"), ("CFBundleVersion", "20261102.1.0"),
                           ("CSReleaseVersion", "1.3.6-rc.2"), ("CFBundleVersion", "20261102.2.1"),
                           ("CSReleaseVersion", "1.3.6-rc.3"), ("CFBundleVersion", "20261103.3.0"),
                           ("CFBundleVersion", "20261103.4.0"),
                           ("CSReleaseVersion", "1.3.6-rc.4"), ("CFBundleVersion", "20261103.4.1"),
                           ("CFBundleVersion", "20261102.2.0"),
                           ("CFBundleShortVersionString", "1.3.6-rc.1"),
                           ("CFBundleName", "Claude Switcher"),
                           ("CFBundleDisplayName", "Claude Switcher"),
                           ("CSPreviewMode", False)):
            info = dict(valid)
            if value is None:
                info.pop(key)
            else:
                info[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                release.verify_preview_metadata(info)

    def test_metadata_gate_runs_before_any_signature_check(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary)
            (app / "Contents").mkdir()
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": release.BUNDLE_ID}))
            with patch.object(release, "pinned_team", return_value="FAKE123456"), patch.object(release, "run") as run:
                with self.assertRaisesRegex(ValueError, "Preview channel must be explicit"):
                    release.verify_app(app, "FAKE123456", app)
                run.assert_not_called()

    def test_unsigned_preparation_never_calls_security_codesign_or_notarytool(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "build/Claude Switcher.app"
            for rel in release.BINARIES:
                binary = source / rel
                binary.parent.mkdir(parents=True, exist_ok=True)
                binary.write_bytes(bytes.fromhex("cffaedfe") + b"fictional binary")
            (source / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": release.BUNDLE_ID}))
            calls = []

            def fake_run(*args):
                calls.append(args)
                if args[:2] == ("git", "status") or args[:2] == ("git", "merge-base"):
                    return ""
                if args[:2] == ("git", "rev-parse"):
                    return "c" * 40
                if args == ("bash", "build.sh", "stage-unsigned"):
                    return "Unsigned fixture staging only\n"
                if args[0] == "ditto":
                    shutil.copytree(args[-2], args[-1])
                    return ""
                if args[0] == "strip":
                    return ""
                if args == ("uname", "-m"):
                    return "arm64"
                self.fail(f"Unexpected offline command: {args}")

            with patch.object(release, "ROOT", root), patch.object(release, "pinned_team", return_value="FAKE123456"), \
                 patch.object(release, "run", side_effect=fake_run), patch.object(sys, "argv", ["release", "prepare"]):
                release.main()
            manifest = json.loads((root / "dist/developer-id/1.3.6-rc.8/RELEASE-MANIFEST.json").read_text())
            self.assertEqual(manifest["release"], "1.3.6-rc.8")
            self.assertEqual(manifest["candidateCommit"], "c" * 40)
            self.assertEqual(Path(manifest["appPath"]).name, "Claude Switcher Preview.app")
            self.assertEqual(release.DR_BASELINE_APP_NAME, "Claude Switcher Preview.app")
            self.assertEqual(manifest["signing"], "NOT_RUN")
            self.assertEqual(manifest["phase"], "prepared")
            self.assertFalse(manifest["distributionReady"])
            self.assertFalse(any(c[0] in ("security", "codesign", "xcrun") for c in calls))

    def test_wrong_public_team_stops_before_any_signature_access(self):
        with patch.object(release, "pinned_team", return_value="FAKE123456"), patch.object(release, "run") as run:
            with self.assertRaisesRegex(ValueError, "public Team pin"):
                release.verify_app(Path("fictional"), "OTHER12345", Path("fictional"))
            run.assert_not_called()

    def test_gui_requirement_comparison_ignores_executable_path(self):
        requirement = 'designated => identifier "fictional.app" and anchor apple generic'
        with patch.object(release, "run", side_effect=["Executable=/old/app\n" + requirement,
                                                      "Executable=/new/app\n" + requirement]):
            result = release.compare_designated_requirements(Path("old"), Path("new"))
        self.assertTrue(result["same"])
        self.assertTrue(result["keychainACLInheritance"].startswith("NOT_PROVEN"))

    def test_gui_requirement_mismatch_or_missing_evidence_is_not_inheritance_proof(self):
        with patch.object(release, "run", side_effect=['designated => identifier "old"', 'designated => identifier "new"']):
            self.assertFalse(release.compare_designated_requirements(Path("old"), Path("new"))["same"])
        with patch.object(release, "run", return_value="no designated requirement"):
            with self.assertRaisesRegex(ValueError, "Cannot read GUI"):
                release.compare_designated_requirements(Path("old"), Path("new"))

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
