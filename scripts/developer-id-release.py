#!/usr/bin/env python3
"""Local, staged Developer ID preview delivery. Never installs or starts the app."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
RELEASE = "1.3.6-rc.1"
BUNDLE_ID = "dev.claudeswitcher.candidate"
APP_NAME = "Claude Switcher 签名预览.app"
BINARIES = (
    "Contents/Helpers/ClaudeGuard",
    "Contents/Helpers/ClaudeSessionTransfer",
    "Contents/MacOS/ClaudeSwitcher",
)
MAGICS = {bytes.fromhex(s) for s in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca",
    "cafebabf", "bfbafeca",
)}


def run(*args):
    return subprocess.check_output([str(a) for a in args], cwd=ROOT, text=True,
                                   stderr=subprocess.STDOUT)


def save(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(path)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def inventory(app):
    found = set()
    for p in app.rglob("*"):
        require(not p.is_symlink(), f"Unexpected symlink inside preview: {p}")
        if p.is_file():
            with p.open("rb") as f:
                if f.read(4) in MAGICS:
                    found.add(p.relative_to(app).as_posix())
    require(found == set(BINARIES), f"Unexpected Mach-O inventory: {sorted(found)}")


def verify_code(path, team, runtime=True):
    run("codesign", "--verify", "--strict", path)
    detail = run("codesign", "-d", "--verbose=4", path)
    require("Authority=Developer ID Application:" in detail, "Not a Developer ID Application signature")
    require(f"TeamIdentifier={team}\n" in detail, "Signing Team ID mismatch")
    require("Timestamp=" in detail and "Timestamp=none" not in detail, "Secure timestamp missing")
    if runtime:
        require(re.search(r"flags=.*\bruntime\b", detail), "Hardened Runtime missing")
    return detail


def verify_app(app, team, evidence):
    inventory(app)
    for rel in BINARIES:
        (evidence / (Path(rel).name + "-signature.txt")).write_text(verify_code(app / rel, team))
    (evidence / "app-signature.txt").write_text(verify_code(app, team))
    run("codesign", "--verify", "--deep", "--strict", app)


def sign(path, identity, runtime=True):
    args = ["codesign", "--force", "--sign", identity, "--timestamp"]
    if runtime:
        args += ["--options", "runtime"]
    run(*args, path)


def check_notary(kind, state, directory, profile):
    submission = state["notarization"][kind]
    require(submission.get("id"), f"No {kind} submission ID; do not submit again blindly")
    result = json.loads(run("xcrun", "notarytool", "info", submission["id"],
                            "--keychain-profile", profile, "--output-format", "json"))
    save(directory / f"{kind}-notary-info.json", result)
    submission["status"] = result["status"]
    save(directory.parent / "RELEASE-MANIFEST.json", state)
    if result["status"] != "In Progress":
        run("xcrun", "notarytool", "log", submission["id"], "--keychain-profile", profile,
            directory / f"{kind}-notary-log.json")
    require(result["status"] == "Accepted", f"{kind} notarization: {result['status']}; not stapled")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("prepare", "sign", "submit-app", "check-app",
                                          "package", "submit-dmg", "check-dmg"))
    parser.add_argument("--output", type=Path, default=ROOT / "dist/developer-id" / RELEASE)
    parser.add_argument("--identity", help="Exact 40-character SHA-1 of a local Developer ID identity")
    parser.add_argument("--team-id", help="Personal Team ID; never select a company team")
    parser.add_argument("--profile", help="Existing local notarytool Keychain profile name; no secrets")
    args = parser.parse_args()
    directory = args.output.resolve()
    require(directory.is_relative_to(ROOT / "dist"), "Output must stay inside this clone's dist/")
    manifest = directory / "RELEASE-MANIFEST.json"
    app = directory / APP_NAME
    evidence = directory / "evidence"
    if args.phase == "prepare":
        require(not directory.exists(), "Output already exists; use a new directory, never overwrite evidence")
        require(not run("git", "status", "--porcelain").strip(), "Commit source changes before preparing")
        source = run("git", "rev-parse", "HEAD").strip()
        print(run("bash", "build.sh"), end="", flush=True)
        directory.mkdir(parents=True)
        evidence.mkdir()
        run("ditto", "--norsrc", "--noextattr", ROOT / "build/Claude Switcher.app", app)
        info_path = app / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        require(info["CFBundleIdentifier"] == BUNDLE_ID, "Bundle ID changed")
        require(not any(k.startswith("CSPreview") for k in info), "Unexpected preview preferences")
        info.update(CFBundleShortVersionString="1.3.6", CFBundleVersion="20261102.1.0")
        info_path.write_bytes(plistlib.dumps(info))
        inventory(app)
        for rel in BINARIES:
            run("strip", "-S", app / rel)
        state = dict(release=RELEASE, version="1.3.6", build=info["CFBundleVersion"],
                     sourceCommit=source, architecture=run("uname", "-m").strip(),
                     bundleIdentifier=BUNDLE_ID, appPath=str(app), signing="NOT_RUN",
                     notarization={"app": {"status": "NOT_RUN"}, "dmg": {"status": "NOT_RUN"}},
                     staple={"app": "NOT_RUN", "dmg": "NOT_RUN"},
                     gatekeeper={"app": "NOT_RUN", "dmg": "NOT_RUN"},
                     installation="NOT_RUN", realAccountValidation="NOT_RUN", files={}, phase="prepared")
        save(manifest, state)
    else:
        state = json.loads(manifest.read_text())
        require(state["sourceCommit"] == run("git", "rev-parse", "HEAD").strip(),
                "Source HEAD differs from prepared package; resume from its original commit")
        require(not run("git", "status", "--porcelain").strip(), "Source has uncommitted changes")
        require(state["bundleIdentifier"] == BUNDLE_ID, "Manifest Bundle ID changed")
        require(state["appPath"] == str(app), "Output directory was moved")
        phase = args.phase
        if phase == "sign":
            require(state["phase"] == "prepared", "Sign only a newly prepared app")
            require(args.identity and re.fullmatch(r"[0-9A-Fa-f]{40}", args.identity), "Use exact identity SHA-1")
            require(args.team_id and re.fullmatch(r"[A-Z0-9]{10}", args.team_id), "A 10-character personal Team ID is required")
            identities = run("security", "find-identity", "-v", "-p", "codesigning")
            line = next((line for line in identities.splitlines() if args.identity.upper() in line.upper()), "")
            require("Developer ID Application:" in line and f"({args.team_id})" in line,
                    "Identity is not a valid Developer ID Application for the requested team")
            inventory(app)
            for rel in BINARIES:
                sign(app / rel, args.identity)
            sign(app, args.identity)
            verify_app(app, args.team_id, evidence)
            state.update(identitySHA1=args.identity.upper(), teamID=args.team_id,
                         signing="Developer ID Application; Hardened Runtime; secure timestamp", phase="signed")
        elif phase.startswith("submit-"):
            kind = phase.removeprefix("submit-")
            require(args.profile, "Existing local Keychain profile required")
            require(state["phase"] == ("signed" if kind == "app" else "packaged"), "Unexpected submission phase")
            require(state["notarization"][kind]["status"] == "NOT_RUN", "Submission already exists")
            verify_app(app, state["teamID"], evidence)
            if kind == "app":
                archive = directory / "app-submission.zip"
                require(not archive.exists(), "Submission archive exists; inspect history before resubmitting")
                run("ditto", "-c", "-k", "--keepParent", app, archive)
            else:
                archive = directory / state["dmgName"]
                verify_code(archive, state["teamID"], runtime=False)
            # Persist intent first: an interrupted upload must be reconciled with notarytool history.
            state["notarization"][kind] = {"status": "SUBMISSION_STARTED; reconcile history if interrupted",
                                              "sha256": digest(archive)}
            save(manifest, state)
            result = json.loads(run("xcrun", "notarytool", "submit", archive, "--keychain-profile", args.profile,
                                    "--no-wait", "--output-format", "json"))
            save(evidence / f"{kind}-notary-submit.json", result)
            state["notarization"][kind].update(id=result["id"], status=result.get("status", "Submitted"))
            state["phase"] = kind + "-submitted"
        elif phase.startswith("check-"):
            kind = phase.removeprefix("check-")
            require(args.profile, "Existing local Keychain profile required")
            require(state["phase"] == kind + "-submitted", "No pending submission for this phase")
            check_notary(kind, state, evidence, args.profile)
            target = app if kind == "app" else directory / state["dmgName"]
            run("xcrun", "stapler", "staple", target)
            run("xcrun", "stapler", "validate", target)
            state["staple"][kind] = "PASS"
            if kind == "app":
                verify_app(app, state["teamID"], evidence)
                assessment = run("spctl", "--assess", "--type", "execute", "--verbose=4", app)
            else:
                verify_code(target, state["teamID"], runtime=False)
                assessment = run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature",
                                 "--verbose=4", target)
            (evidence / f"{kind}-gatekeeper.txt").write_text(assessment)
            state["gatekeeper"][kind] = "PASS"
            state["phase"] = kind + "-accepted"
            if kind == "dmg":
                files = [directory / state[k] for k in ("zipName", "dmgName")]
                state["files"] = {p.name: digest(p) for p in files}
                (directory / "SHA256SUMS").write_text("".join(f"{h}  {n}\n" for n, h in state["files"].items()))
                state["phase"] = "ready-for-review"
        elif phase == "package":
            require(state["phase"] == "app-accepted", "App must be Accepted, stapled and assessed first")
            verify_app(app, state["teamID"], evidence)
            run("xcrun", "stapler", "validate", app)
            stem = f"ClaudeSwitcher-{RELEASE}-{state['architecture']}-developer-id-preview"
            zip_path, dmg_path = directory / (stem + ".zip"), directory / (stem + ".dmg")
            require(not zip_path.exists() and not dmg_path.exists(), "Do not overwrite existing packages")
            # ditto's defaults preserve the stapled app's resource fork and extended attributes.
            run("ditto", "-c", "-k", "--keepParent", app, zip_path)
            stage = directory / "dmg-stage"
            require(not stage.exists(), "Existing DMG stage; inspect before retrying")
            stage.mkdir()
            run("ditto", app, stage / APP_NAME)
            (stage / "Applications").symlink_to("/Applications")
            run("hdiutil", "create", "-volname", f"Claude Switcher {RELEASE} Preview", "-srcfolder", stage,
                "-fs", "HFS+", "-format", "UDZO", dmg_path)
            sign(dmg_path, state["identitySHA1"], runtime=False)
            (evidence / "dmg-signature.txt").write_text(verify_code(dmg_path, state["teamID"], runtime=False))
            state.update(zipName=zip_path.name, dmgName=dmg_path.name, phase="packaged")
        save(manifest, state)
    print(f"{state['phase']}: {manifest}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as exc:
        print(f"Stopped: {exc}", file=sys.stderr)
        if isinstance(exc, subprocess.CalledProcessError):
            print(exc.output, file=sys.stderr)
        sys.exit(1)
