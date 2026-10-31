"""Read-only source inventory, not a claim of firewall runtime validation."""
import hashlib
import json
import re
import subprocess
from pathlib import Path

LULU_COMMIT = "6ad78b988c179ffce08668533671bc0dedef19a8"
FILES = ["App/main.m", "Extension/FilterDataProvider.m", "Extension/FilterDataProvider.h",
         "Extension/XPCListener.m", "Extension/XPCDaemon.m", "Extension/Profiles.m",
         "Extension/Preferences.m", "Extension/Rules.m", "Extension/Process.m", "Shared/consts.h"]


def inventory(root):
    root = Path(root)
    actual = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
    if actual != LULU_COMMIT:
        raise ValueError("unexpected LuLu source revision")
    texts = {name: (root / "LuLu" / name).read_text() for name in FILES}
    consts = texts["Shared/consts.h"]
    def value(name):
        match = re.search(r'^#define\s+' + name + r'\s+@"([^"]+)"', consts, re.M)
        if not match:
            raise ValueError("missing source constant: " + name)
        return match.group(1)
    requirement = ('anchor apple generic and identifier ' + json.dumps(value("APP_ID")) +
                   ' and certificate leaf [subject.CN] = ' + json.dumps(value("SIGNING_AUTH")))
    def matches(text, pattern):
        return [{"line": index, "text": line.strip()} for index, line in enumerate(text.splitlines(), 1)
                if re.search(pattern, line)]
    extension = {str(p.relative_to(root)): p.read_text() for p in (root / "LuLu/Extension").glob("*.[mh]")}
    return {
        "evidenceClass": "STATIC_SOURCE_INVENTORY", "repository": "https://github.com/objective-see/LuLu",
        "tag": "v4.5.5", "sourceCommit": actual, "sourceLicense": "GPL-3.0",
        "sourceSHA256": {name: hashlib.sha256((root / "LuLu" / name).read_bytes()).hexdigest() for name in FILES},
        "xpcRequirement": requirement,
        "cliArgumentBranches": matches(texts["App/main.m"], r'containsObject:@"-'),
        "clientSignatureGate": matches(texts["Extension/XPCListener.m"], r'CS_RUNTIME|SecTaskValidateForRequirement|requirement ='),
        "explicitExistingFlowUpdateMatches": {name: matches(text, r'\bupdateFlow\s*:|\busingVerdict\s*:')
            for name, text in extension.items() if matches(text, r'\bupdateFlow\s*:|\busingVerdict\s*:')},
        "dataCallbackMatches": {name: matches(text, r'handleInboundData|handleOutboundData')
            for name, text in extension.items() if matches(text, r'handleInboundData|handleOutboundData')},
        "newFlowVerdicts": matches(texts["Extension/FilterDataProvider.m"], r'handleNewFlow:|allowVerdict|dropVerdict'),
        "pausedFlowTracking": matches(texts["Extension/FilterDataProvider.m"], r'addRelatedFlow:|resumeFlowsForKey:|processRelatedFlow:'),
        "profileChange": matches(texts["Extension/XPCDaemon.m"], r'setProfile:|\[profiles set:|\[rules load\]|\[preferences load\]'),
        "processTreeBoundary": matches(texts["Extension/Rules.m"], r'process \+ kids|no signing validation|intermediate parent has exited'),
        "actualFilterRuntime": "NOT_RUN", "productionReady": False,
        "interpretation": "No explicit update match is source evidence only, not a packet-capture proof or full API audit."
    }


if __name__ == "__main__":
    import sys
    print(json.dumps(inventory(sys.argv[1]), indent=2))
