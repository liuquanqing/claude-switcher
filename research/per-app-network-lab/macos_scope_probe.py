"""Disposable GitHub Mac ONLY: test PF selectivity with same-user applications.

Expected negative control: PF user rules cannot distinguish two processes
running as the same login user. Both fixtures use the same Python executable;
this is not real app identification. Passing does NOT pass protection.
Every target is loopback; no proxy, credentials, Claude installation or real user
profile is accessed. Production integration remains HOLD.
"""
import hashlib
import json
import os
import platform
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path


def require_disposable():
    # These are execution guards, not test assertions: -O must never remove them.
    if not __debug__:
        raise SystemExit("Optimized Python is forbidden; evidence assertions must remain enabled")
    checks = [
        sys.platform == "darwin" and os.geteuid() == 0,
        os.environ.get("GITHUB_ACTIONS") == "true",
        os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted",
        os.environ.get("GITHUB_REPOSITORY") == "liuquanqing/claude-switcher",
        os.environ.get("CS_APP_SCOPE_LAB") == "ephemeral-loopback-only",
        bool(os.environ.get("RUNNER_TEMP")),
    ]
    if not all(checks):
        raise SystemExit("Refusing execution outside the explicit disposable hosted Mac experiment")


require_disposable()
PORTS = {"tcp": 29741, "udp": 29742}
PEERS = [(4, "127.0.0.1"), (6, "::1")]

if len(sys.argv) > 1 and sys.argv[1] == "--client":
    uid, family, protocol, token = int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]
    os.setgroups([])
    os.setgid(uid)
    os.setuid(uid)
    host = "127.0.0.1" if family == 4 else "::1"
    with socket.socket(socket.AF_INET if family == 4 else socket.AF_INET6,
                       socket.SOCK_STREAM if protocol == "tcp" else socket.SOCK_DGRAM) as client:
        client.settimeout(.35)
        try:
            client.connect((host, PORTS[protocol]))
            client.sendall((token + "\n").encode())
            ack = client.recv(4096) == (token + "\n").encode()
        except OSError:
            ack = False
    print(json.dumps({"uid": os.getuid(), "ack": ack}))
    sys.exit(0)

SEEN = {}
LOCK = threading.Lock()
CASES = []


class TCP(socketserver.StreamRequestHandler):
    def handle(self):
        while data := self.rfile.readline():
            with LOCK:
                SEEN[data.strip().decode()] = time.monotonic()
            try:
                self.wfile.write(data)
                self.wfile.flush()
            except OSError:
                break


class UDP(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        with LOCK:
            SEEN[data.strip().decode()] = time.monotonic()
        sock.sendto(data, self.client_address)


class T4(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class T6(T4):
    address_family = socket.AF_INET6


class U4(socketserver.ThreadingUDPServer):
    allow_reuse_address = True
    daemon_threads = True


class U6(U4):
    address_family = socket.AF_INET6


def pf(*args, check=True):
    return subprocess.run(["/sbin/pfctl", *args], capture_output=True, text=True, check=check)


def measure(stage, role, uid, expected):
    for family, _ in PEERS:
        for protocol in ("tcp", "udp"):
            token = uuid.uuid4().hex
            run = subprocess.run([sys.executable, __file__, "--client", str(uid), str(family), protocol, token],
                                 capture_output=True, text=True, check=True, timeout=5)
            client = json.loads(run.stdout)
            with LOCK:
                reached = token in SEEN
            record = dict(stage=stage, role=role, uid=uid, family=family, protocol=protocol,
                          token=token, ack=client["ack"], reachedSink=reached, expected=expected)
            CASES.append(record)
            assert client["uid"] == uid and client["ack"] == expected and reached == expected, record


def main():
    user = int(os.environ["SUDO_UID"])
    assert user not in (0, 65534)
    for cls, host, protocol in [(T4, "127.0.0.1", "tcp"), (T6, "::1", "tcp"),
                                 (U4, "127.0.0.1", "udp"), (U6, "::1", "udp")]:
        server = cls((host, PORTS[protocol]), TCP if protocol == "tcp" else UDP)
        threading.Thread(target=server.serve_forever, daemon=True).start()
    original = Path("/etc/pf.conf").read_text()
    enabled = "Status: Enabled" in pf("-s", "info").stdout
    error = None
    cleanup = False
    installed = False
    with tempfile.TemporaryDirectory(prefix="cs-per-app-", dir=os.environ["RUNNER_TEMP"]) as temporary:
        root = Path(temporary)
        base = root / "base.conf"
        base.write_text(original + '\nanchor "cs_app_scope_lab"\n')
        rule = root / "rules.conf"
        try:
            for role, uid in [("fictional-Claude", user), ("unrelated-same-user", user), ("unrelated-other-user", 65534)]:
                measure("baseline", role, uid, True)
            pf("-nf", str(base))
            pf("-f", str(base))
            installed = True
            pf("-e", check=False)
            # Scope limited to the lab destination and ports, never general outbound.
            lines = [f"block drop out quick on lo0 inet{'6' if family == 6 else ''} proto {{ tcp udp }} from any to {host} port {{ 29741 29742 }} user {user}"
                     for family, host in PEERS]
            rule.write_text("\n".join(lines) + "\n")
            pf("-a", "cs_app_scope_lab", "-nf", str(rule))
            pf("-a", "cs_app_scope_lab", "-f", str(rule))
            for _, host in PEERS:
                pf("-k", host, "-k", host)
            measure("user-rule", "fictional-Claude", user, False)
            # This is the important collateral-damage negative control, NOT a capability pass.
            measure("VULNERABILITY-user-rule", "unrelated-same-user", user, False)
            measure("user-rule", "unrelated-other-user", 65534, True)
            pf("-a", "cs_app_scope_lab", "-F", "rules")
            measure("recovery", "fictional-Claude", user, True)
            measure("recovery", "unrelated-same-user", user, True)
            # Retain the receiver log and check negative probes again after the
            # recovery controls, so late delivery cannot silently become PASS.
            with LOCK:
                for case in CASES:
                    case["receivedAtMonotonic"] = SEEN.get(case["token"])
                    case["reachedSinkAtFinalRead"] = case["token"] in SEEN
                    assert case["reachedSinkAtFinalRead"] == case["expected"], case
        except BaseException as exception:
            error = repr(exception)
        finally:
            if installed:
                a = pf("-a", "cs_app_scope_lab", "-F", "rules", check=False)
                b = pf("-f", "/etc/pf.conf", check=False)
                c = pf("-d", check=False) if not enabled else None
                cleanup = a.returncode == b.returncode == 0 and (c is None or c.returncode == 0)
            else:
                cleanup = True
    result = dict(layer="macOS-PF-same-UID-scope-negative-control", os=platform.mac_ver()[0],
                  arch=platform.machine(), cases=CASES, observations=len(CASES),
                  experimentCompleted=error is None and cleanup, error=error, cleanup=cleanup,
                  selectivityRequirementPassed=False, productionReady=False,
                  realClaudeOrCLI=False, sourceSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  fixtureExecutable="same Python interpreter, different processes",
                  receiverObservation="bounded experiment window, not a proof of indefinite non-delivery",
                  existingFlowRevocation="NOT_RUN", actualNetworkExtension="NOT_RUN")
    Path(os.environ["CS_SCOPE_RESULT"]).write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2), flush=True)
    # Threaded fixtures are entirely disposable; their process teardown must not hide result status.
    os._exit(0 if result["experimentCompleted"] else 1)


main()
