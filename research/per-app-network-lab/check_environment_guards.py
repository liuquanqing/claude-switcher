"""Test the guard function in memory. Never imports or executes the PF probe."""
import ast
import json
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

tree = ast.parse(Path(__file__).with_name("macos_scope_probe.py").read_text())
guard = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "require_disposable")
code = compile(ast.Module(body=[guard], type_ignores=[]), "isolated-guard-function", "exec")
valid = {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted",
         "GITHUB_REPOSITORY": "liuquanqing/claude-switcher",
         "CS_APP_SCOPE_LAB": "ephemeral-loopback-only", "RUNNER_TEMP": "/fictional/temporary"}
count = 0
for absent in [None, *valid]:
    env = valid.copy()
    if absent is not None:
        del env[absent]
    namespace = {"sys": SimpleNamespace(platform="darwin"),
                 "os": SimpleNamespace(geteuid=lambda: 0, environ=env)}
    exec(code, namespace)
    rejected = False
    try:
        namespace["require_disposable"]()
    except SystemExit:
        rejected = True
    if rejected != (absent is not None):
        raise RuntimeError("incorrect guard decision: " + str(absent))
    count += 1
for platform, uid in [("linux", 0), ("darwin", 501)]:
    namespace = {"sys": SimpleNamespace(platform=platform),
                 "os": SimpleNamespace(geteuid=lambda: uid, environ=valid)}
    exec(code, namespace)
    try:
        namespace["require_disposable"]()
    except SystemExit:
        count += 1
    else:
        raise RuntimeError("wrong platform or uid accepted")
# Compile only the extracted function under optimized Python. There are no PF
# commands, imports of the probe, real uid changes or environment writes here.
snippet = ast.unparse(guard) + "\nrequire_disposable()\n"
run = subprocess.run([sys.executable, "-O", "-c", snippet], capture_output=True, text=True)
if run.returncode == 0 or "Optimized Python is forbidden" not in run.stderr:
    raise RuntimeError("optimized Python did not fail closed")
count += 1
print(json.dumps({"layer": "extracted-environment-guard-only", "checks": count,
                  "passed": True, "networkActions": False}))
