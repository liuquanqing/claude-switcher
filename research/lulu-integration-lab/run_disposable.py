"""Official LuLu binary signature validation on a disposable hosted Mac only.

No installer/app execution, no privileged command, no system extension activation,
no XPC call, no rule mutation, no real Claude or login. The DMG is mounted read-only
inside runner temporary storage, examined, then detached in finally.
"""
import hashlib
import json
import os
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

from inspect_source import LULU_COMMIT, inventory


def disposable_only():
    if not __debug__ or sys.platform != "darwin" or os.geteuid() == 0:
        raise SystemExit("Non-root disposable Mac with assertions enabled required")
    expected = {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted",
                "GITHUB_REPOSITORY": "liuquanqing/claude-switcher", "CS_LULU_LAB": "read-only-official-binary"}
    if any(os.environ.get(k) != v for k, v in expected.items()) or not os.environ.get("RUNNER_TEMP"):
        raise SystemExit("Refusing execution outside the explicit disposable runner")


disposable_only()
output = Path(os.environ["CS_LULU_RESULT_DIR"])
output.mkdir(parents=True, exist_ok=True)
lab = Path(__file__).resolve().parent
digest = "c84c94912405eb852753fc3b51d79ad816d94c6b3b5aec4db4daf2eb8f357597"
url = "https://github.com/objective-see/LuLu/releases/download/v4.5.5/LuLu_4.5.5.dmg"
def command(*args):
    try:
        return subprocess.run(args, check=True, text=True, capture_output=True, timeout=120)
    except subprocess.CalledProcessError as failure:
        # Inputs are official public URLs, source files and temporary fixtures.
        # Retain preparation errors rather than losing compiler diagnostics.
        (output / "command-error.json").write_text(json.dumps({
            "arguments": args, "status": failure.returncode,
            "stdout": failure.stdout, "stderr": failure.stderr}, indent=2) + "\n")
        raise


mounted = False
cleanup = False
error = None
signature = None
facts = None
version = None
with tempfile.TemporaryDirectory(prefix="cs-lulu-readonly-", dir=os.environ["RUNNER_TEMP"]) as temporary:
    root = Path(temporary)
    mount = root / "mount"
    mount.mkdir()
    try:
        source = root / "source"
        command("git", "clone", "--quiet", "--depth", "1", "--branch", "v4.5.5", "https://github.com/objective-see/LuLu.git", str(source))
        facts = inventory(source)
        (output / "source-inventory.json").write_text(json.dumps(facts, indent=2) + "\n")
        with urllib.request.urlopen(url, timeout=90) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != digest:
            raise ValueError("official DMG digest mismatch")
        dmg = root / "LuLu.dmg"
        dmg.write_bytes(data)
        command("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(dmg))
        mounted = True
        apps = [p for p in mount.glob("*.app") if not p.is_symlink()]
        if len(apps) != 1 or apps[0].name != "LuLu.app":
            raise ValueError("unexpected official DMG contents")
        app = apps[0]
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        version = info["CFBundleShortVersionString"]
        if version != "4.5.5":
            raise ValueError("unexpected official app version")
        command("codesign", "--verify", "--deep", "--strict", str(app))
        requirement = facts["xpcRequirement"]
        # Both negative fixtures are newly compiled test programs, never real apps.
        (root / "fixture.c").write_text("int main(void) { return 0; }\n")
        plain = root / "ordinary-switcher-fixture"
        same_name = root / "same-identifier-fixture"
        command("clang", str(root / "fixture.c"), "-o", str(plain))
        shutil.copy2(plain, same_name)
        command("codesign", "--force", "-s", "-", "--options", "runtime", "--identifier", "dev.claudeswitcher.fixture.integration", str(plain))
        command("codesign", "--force", "-s", "-", "--options", "runtime", "--identifier", "com.objective-see.lulu.app", str(same_name))
        manifest = {"requirement": requirement, "cases": [
            {"label": "official-LuLu-app", "path": str(app), "expectedMatch": True},
            {"label": "ordinary-switcher-fixture", "path": str(plain), "expectedMatch": False},
            {"label": "same-ID-different-signer-fixture", "path": str(same_name), "expectedMatch": False}]}
        manifest_path = root / "manifest.json"
        manifest_path.write_text(json.dumps(manifest))
        checker = root / "signature-gate"
        command("swiftc", "-parse-as-library", str(lab / "signature_gate.swift"), "-o", str(checker))
        signature = json.loads(command(str(checker), str(manifest_path)).stdout)
        (output / "signature-results.json").write_text(json.dumps(signature, indent=2) + "\n")
    except BaseException as failure:
        error = repr(failure)
    finally:
        try:
            if mounted:
                command("hdiutil", "detach", str(mount))
            cleanup = True
        except BaseException as failure:
            error = (error or "") + " cleanup: " + repr(failure)

result = {"layer": "disposable-mac-official-binary-static-signature-gate", "sourceCommit": LULU_COMMIT,
          "officialVersion": version, "officialDMG": {"URL": url, "SHA256": digest},
          "os": platform.mac_ver()[0], "arch": platform.machine(),
          "experimentCompleted": error is None and cleanup and signature is not None,
          "error": error, "cleanup": cleanup,
          "automaticIntegration": "STATIC_REQUIREMENT_REJECTED_EXTERNAL_CLIENT" if signature is not None else "NOT_RUN",
          "existingFlowRevocation": "NOT_RUN", "selectiveClaudeRuntime": "NOT_RUN",
          "installed": False, "appOrExtensionLaunched": False, "networkOrGuardConfigModified": False,
          "productionIntegration": "HOLD"}
(output / "validation-results.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2), flush=True)
sys.exit(0 if result["experimentCompleted"] else 1)
