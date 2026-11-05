#!/usr/bin/env python3
"""Run the unmodified signed ClaudeUpdater against notarized credential-free apps.

All application and home paths stay inside _qa/signed-update/. Nothing is
installed in /Applications, and no real guard or login is a test fixture.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
QA = ROOT / "_qa/signed-update/integration-r2"
IDENTIFIER = "dev.claudeswitcher.candidate"
OLD, NEW = "20261105.7.1", "20261105.7.2"
TEMPLATES = {"old": (OLD, "ack"), "new": (NEW, "ack"),
             "no-ack": (NEW, "no-ack"), "old-refuse": (OLD, "refuse"),
             "new-refuse": (NEW, "refuse")}


def command(*args, **kwargs):
    return subprocess.check_output(list(map(str, args)), text=True, stderr=subprocess.STDOUT, **kwargs)


def save(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def sha(path):
    return hashlib.file_digest(path.open("rb"), "sha256").hexdigest()


def info(app):
    return plistlib.loads((app / "Contents/Info.plist").read_bytes())


def prepare(identity):
    assert not QA.exists(), "Keep prior evidence; do not prepare twice"
    assert identity and len(identity) == 40
    helper = ROOT / "build/Claude Switcher.app/Contents/Helpers/ClaudeUpdater"
    assert helper.is_file(), "Build the current source with stage-unsigned first"
    QA.mkdir(parents=True)
    command("swiftc", "-parse-as-library", ROOT / "scripts/fixtures/signed-update-app.swift", "-o", QA / "FixtureApp")
    command("swiftc", "-parse-as-library", ROOT / "scripts/fixtures/signed-update-control.swift", "-o", QA / "control")
    for name, (build, behavior) in TEMPLATES.items():
        app = QA / "templates" / (name + ".app")
        for directory in ["MacOS", "Helpers"]:
            (app / "Contents" / directory).mkdir(parents=True)
        shutil.copy2(QA / "FixtureApp", app / "Contents/MacOS/FixtureApp")
        shutil.copy2(helper, app / "Contents/Helpers/ClaudeUpdater")
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": IDENTIFIER, "CFBundleExecutable": "FixtureApp",
            "CFBundleName": "Signed Update QA", "CFBundleDisplayName": "Signed Update QA",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.0.0",
            "CFBundleVersion": build, "CSQABehavior": behavior, "LSUIElement": True,
            "LSMinimumSystemVersion": "13.0"}))
        for path in [app / "Contents/Helpers/ClaudeUpdater", app / "Contents/MacOS/FixtureApp", app]:
            command("codesign", "--force", "--sign", identity, "--timestamp", "--options", "runtime", path)
        command("codesign", "--verify", "--deep", "--strict", app)
    archive = QA / "signed-fixture-apps.zip"
    command("ditto", "-c", "-k", "--keepParent", QA / "templates", archive)
    save(QA / "manifest.json", {"sourceCommit": command("git", "rev-parse", "HEAD").strip(),
         "helperSourceSHA256": sha(ROOT / "Sources/ClaudeUpdater/UpdaterMain.swift"),
         "archiveSHA256": sha(archive), "notarization": "NOT_SUBMITTED", "testResults": []})


def notarize(profile, submit=False):
    file = QA / "manifest.json"
    state = json.loads(file.read_text())
    if submit:
        assert state["notarization"] == "NOT_SUBMITTED", "Do not resubmit an existing job"
        state["notarization"] = "SUBMISSION_STARTED"
        save(file, state)
        result = json.loads(command("xcrun", "notarytool", "submit", QA / "signed-fixture-apps.zip",
                                    "--keychain-profile", profile, "--no-wait", "--output-format", "json"))
        state["submissionID"] = result["id"]
        state["notarization"] = result.get("status", "Submitted")
    else:
        result = json.loads(command("xcrun", "notarytool", "info", state["submissionID"],
                                    "--keychain-profile", profile, "--output-format", "json"))
        state["notarization"] = result["status"]
        if result["status"] == "Accepted":
            for name in TEMPLATES:
                app = QA / "templates" / (name + ".app")
                command("xcrun", "stapler", "staple", app)
                command("xcrun", "stapler", "validate", app)
                command("spctl", "--assess", "--type", "execute", app)
            state["gatekeeper"] = "PASS"
    save(file, state)
    print(state["notarization"], state.get("submissionID", ""))


def wait_for(predicate, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.15)
    raise RuntimeError("Fictional application did not reach the expected state")


def run_case(name, old_template, new_template, expected, corrupt=False, helper=None):
    home = QA / "cases" / (name + "-" + uuid.uuid4().hex) / "home"
    applications = home / "Applications"
    applications.mkdir(parents=True)
    identifier = str(uuid.uuid4()).upper()
    app = applications / "Signed Update Fixture.app"
    stage = applications / (".claude-switcher-update-" + identifier + ".app")
    command("ditto", QA / "templates" / (old_template + ".app"), app)
    command("ditto", QA / "templates" / (new_template + ".app"), stage)
    if corrupt:
        with (stage / "Contents/MacOS/FixtureApp").open("ab") as out:
            out.write(b"fictional signature corruption")
    directory = home / "Library/Caches" / IDENTIFIER / "Installations" / identifier
    directory.mkdir(parents=True)
    # A valid disabled fixture config short-circuits GuardService.registered.
    # This exact production code path never queries the real launchd namespace.
    config = home / "Library/Application Support/ClaudeSwitcher/protection.json"
    config.parent.mkdir(parents=True)
    save(config, {"enabled": False, "expectedCountry": "SG", "proxyMode": "shadowrocket"})
    plan = {"id": identifier, "application": app.as_uri(), "stagedApplication": stage.as_uri(),
            "oldBuild": OLD, "newBuild": NEW, "release": "0.0.0-qa"}
    save(directory / "plan.json", plan)
    def control(action, *extra):
        return command(QA / "control", action, home, app, *extra).strip()
    environment = os.environ.copy()
    environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home))
    result_file = directory / "result.json"
    def result():
        try:
            return json.loads(result_file.read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            return {}
    process = None
    try:
        control("open", directory / "initial-start.json")
        initial = wait_for(lambda: json.loads((directory / "initial-start.json").read_text())
                           if (directory / "initial-start.json").exists() else None)
        assert initial["application"] == str(app) and initial["build"] == OLD
        runner = helper or app / "Contents/Helpers/ClaudeUpdater"
        process = subprocess.Popen([str(runner), "--install", str(directory / "plan.json")],
                                   env=environment, stdout=subprocess.DEVNULL, stderr=(directory / "helper-stderr.txt").open("w"))
        first = wait_for(lambda: result(), timeout=20)
        if first["state"] == "waitingForExit":
            control("quit")
        return_code = process.wait(timeout=85)
        outcome = result()
        assert outcome.get("state") == expected, (name, outcome, return_code)
        expected_build = NEW if expected in ["complete", "recoveryRequired"] else OLD
        assert info(app)["CFBundleVersion"] == expected_build
        if expected == "complete":
            record = json.loads((directory / ("launched-" + NEW + ".json")).read_text())
            assert record["application"] == str(app) and record["build"] == NEW
            assert info(stage)["CFBundleVersion"] == OLD and return_code == 0
        if expected == "rolledBack":
            assert (directory / ("launched-" + OLD + ".json")).exists()
            assert info(stage)["CFBundleVersion"] == NEW
        answer = {"case": name, "state": outcome["state"], "installedBuild": expected_build,
                  "helperExit": return_code, "actualSignedHelper": True, "nativeLaunch": True,
                  "guardConfig": "fictional-disabled", "realGuardQueriedOrChanged": False,
                  "helperSHA256": sha(runner), "distributionHelper": helper is not None}
        save(directory / "case-result.json", answer)
        return answer
    finally:
        if process and process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
        control("cleanup")
        command("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", "-u", app)


def run_tests(only=None, helper=None):
    state = json.loads((QA / "manifest.json").read_text())
    assert state["notarization"] == "Accepted" and state.get("gatekeeper") == "PASS"
    assert state["helperSourceSHA256"] == sha(ROOT / "Sources/ClaudeUpdater/UpdaterMain.swift")
    if helper:
        helper = Path(helper).resolve()
        assert helper.is_relative_to(ROOT / "dist") and helper.name == "ClaudeUpdater"
        command("codesign", "--verify", "--strict", helper)
    cases = [("upgrade", "old", "new", "complete", False),
             ("no-startup-confirmation", "old", "no-ack", "rolledBack", False),
             ("old-refuses-quit", "old-refuse", "new", "failed", False),
             ("new-refuses-rollback", "old", "new-refuse", "recoveryRequired", False),
             ("bad-signature", "old", "new", "failed", True)]
    for case in cases:
        if only and case[0] != only:
            continue
        outcome = run_case(*case, helper=helper)
        state["testResults"] = [r for r in state["testResults"] if r["case"] != outcome["case"]] + [outcome]
        save(QA / "manifest.json", state)
        print(json.dumps(outcome), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=["prepare", "submit", "check", "run"])
    parser.add_argument("--identity")
    parser.add_argument("--profile")
    parser.add_argument("--case")
    parser.add_argument("--helper", help="Exact signed distribution helper in this clone's dist/ directory")
    args = parser.parse_args()
    if args.phase == "prepare":
        prepare(args.identity)
    elif args.phase in ["submit", "check"]:
        assert args.profile
        notarize(args.profile, submit=args.phase == "submit")
    else:
        run_tests(args.case, args.helper)


if __name__ == "__main__":
    main()
