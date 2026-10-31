"""Real loopback TCP/UDP on disposable macOS. No firewall/routing mutations.
Fixtures named desktop/CLI are NOT official applications. Direct bypass is an
expected negative control; a green experiment must still say integration HOLD.
"""
import json
import os
import platform
import queue
import select
import signal
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path


def guard():
    if (not __debug__ or sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true" or
            os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted" or
            os.environ.get("GITHUB_REPOSITORY") != "liuquanqing/claude-switcher" or
            os.environ.get("CS_PROXY_LAB") != "loopback-only" or not os.environ.get("RUNNER_TEMP")):
        raise SystemExit("Disposable hosted Mac fixture only")


guard()
TTL = 2.0
SEEN = {}
CONNECTIONS = []
BY_TOKEN = {}
CLIENT_RECEIVED = {}
HOP_PAIRS = set()
LOCK = threading.Lock()
CASES = []


class TCP(socketserver.StreamRequestHandler):
    def handle(self):
        with LOCK:
            CONNECTIONS.append(self.request)
        try:
            for data in iter(self.rfile.readline, b""):
                with LOCK:
                    SEEN[data.strip().decode()] = time.monotonic()
                    BY_TOKEN[data.strip().decode()] = self.request
                self.wfile.write(data)
                self.wfile.flush()
        except OSError:
            pass


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
    daemon_threads = True


class U6(U4):
    address_family = socket.AF_INET6


class Hop(socketserver.BaseRequestHandler):
    def handle(self):
        pair = None
        try:
            upstream = socket.create_connection(self.server.target, timeout=.3)
            pair = (self.request, upstream)
            with LOCK:
                HOP_PAIRS.add(pair)
            while True:
                ready, _, _ = select.select(pair, [], [], .1)
                for source in ready:
                    data = source.recv(4096)
                    if not data:
                        return
                    pair[1 if source is pair[0] else 0].sendall(data)
        except (OSError, ValueError):
            pass
        finally:
            if pair:
                with LOCK:
                    HOP_PAIRS.discard(pair)
                for stream in pair:
                    stream.close()


HOSTS = ["127.0.0.1", "::1"]
SERVERS = []
for cls, host, handler in [(T4, HOSTS[0], TCP), (T6, HOSTS[1], TCP),
                            (U4, HOSTS[0], UDP), (U6, HOSTS[1], UDP)]:
    server = cls((host, 0), handler)
    SERVERS.append(server)
    threading.Thread(target=server.serve_forever, daemon=True).start()


def connect(family, port):
    sock = socket.socket(socket.AF_INET if family == 0 else socket.AF_INET6, socket.SOCK_STREAM)
    sock.settimeout(.3)
    sock.connect((HOSTS[family], port))
    return sock


def exchange(case, family, stream, expected, role, is_bypass=False):
    token = uuid.uuid4().hex
    ack = False
    try:
        stream.sendall((token + "\n").encode())
        reply = stream.recv(4096)
        if not expected and reply:
            raise AssertionError("unexpected bytes on a blocked stream")
        ack = reply == (token + "\n").encode()
    except OSError:
        pass
    with LOCK:
        reached = token in SEEN
    record = dict(case=case, family=4 if family == 0 else 6, role=role,
                  token=token, echo=ack, reachedSink=reached, expected=expected,
                  expectedBypass=is_bypass)
    CASES.append(record)
    if ack != expected or reached != expected:
        raise AssertionError(record)
    return token


def main():
    gateway = None
    control = None
    events = queue.Queue()
    streams = []
    workers = []
    kernel_cases = []
    error = None
    cleanup = False
    results = Path(os.environ["CS_PROXY_RESULT"])
    with tempfile.TemporaryDirectory(prefix="cs-connect-gate-", dir=os.environ["RUNNER_TEMP"]) as temporary:
        root = Path(temporary)
        hops = []
        hop_ports = []
        def start_hops():
            hops.clear()
            for family, cls in enumerate((T4, T6)):
                port = hop_ports[family] if len(hop_ports) > family else 0
                server = cls((HOSTS[family], port), Hop)
                server.target = (HOSTS[family], SERVERS[family].server_address[1])
                if len(hop_ports) <= family:
                    hop_ports.append(server.server_address[1])
                hops.append(server)
                threading.Thread(target=server.serve_forever, kwargs={"poll_interval": .02}, daemon=True).start()

        def stop_hops():
            for server in hops:
                server.shutdown()
                server.server_close()
            with LOCK:
                pairs = list(HOP_PAIRS)
            for pair in pairs:
                for stream in pair:
                    try:
                        stream.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
                    stream.close()

        start_hops()
        manifest = root / "manifest.json"
        manifest.write_text(json.dumps({"ttl": TTL, "targets": {
            "fixture4.invalid:443": [HOSTS[0], hop_ports[0]],
            "fixture6.invalid:443": [HOSTS[1], hop_ports[1]]}}))
        unrelated_held = [connect(family, SERVERS[family].server_address[1]) for family in (0, 1)]
        streams.extend(unrelated_held)
        def start():
            nonlocal gateway, control
            if control:
                control.close()
            left, right = socket.socketpair()
            gateway = subprocess.Popen([sys.executable, "-u", str(Path(__file__).with_name("gateway.py")),
                str(manifest), str(right.fileno())], pass_fds=(right.fileno(),), stdout=subprocess.PIPE,
                stderr=root.joinpath("gateway.stderr").open("w"), text=True)
            right.close()
            control = left
            control.settimeout(3)
            def read_events(process):
                for line in process.stdout:
                    events.put(json.loads(line))
            threading.Thread(target=read_events, args=(gateway,), daemon=True).start()
            return wait("ready")["ports"]

        def wait(event, reason=None):
            end = time.monotonic() + 4
            while time.monotonic() < end:
                value = events.get(timeout=max(.01, end - time.monotonic()))
                if value.get("event") == event and (reason is None or value.get("reason") == reason):
                    return value
            raise AssertionError((event, reason))

        def command(op="permit", country="SG", context="route-1", sampled=None, tunnel_ready=True):
            message = dict(op=op, country=country, context=context, tunnelReady=tunnel_ready,
                           sampledAt=time.monotonic() if sampled is None else sampled, id=uuid.uuid4().hex)
            control.sendall((json.dumps(message) + "\n").encode())
            buf = b""
            while b"\n" not in buf:
                buf += control.recv(4096)
            reply = json.loads(buf)
            if reply["id"] != message["id"]:
                raise AssertionError(reply)
            return reply

        def tunnel(family, expected):
            try:
                sock = connect(family, ports[family])
                authority = "fixture4.invalid:443" if family == 0 else "fixture6.invalid:443"
                sock.sendall(("CONNECT " + authority + " HTTP/1.1\r\nHost: " + authority + "\r\n\r\n").encode())
                header = b""
                while b"\r\n\r\n" not in header:
                    part = sock.recv(4096)
                    if not part:
                        break
                    header += part
                allowed = header.startswith(b"HTTP/1.1 200")
            except OSError:
                sock = None
                allowed = False
            if allowed != expected:
                raise AssertionError(("CONNECT", family, header if sock else None))
            return sock

        def new_flows(name, allowed):
            for family in (0, 1):
                sock = tunnel(family, allowed)
                if sock:
                    if allowed:
                        exchange(name, family, sock, True, "explicit-proxy-fixture")
                    else:
                        # A 503 response never established an origin tunnel.
                        token = uuid.uuid4().hex
                        CASES.append(dict(case=name, family=4 if family == 0 else 6, role="explicit-proxy-fixture",
                            probeType="CONNECT-attempt", token=token, echo=False, reachedSink=False, expected=False, expectedBypass=False))
                    sock.close()
                else:
                    CASES.append(dict(case=name, family=4 if family == 0 else 6, role="explicit-proxy-fixture",
                        probeType="CONNECT-attempt", token=uuid.uuid4().hex, echo=False, reachedSink=False, expected=False, expectedBypass=False))

        def open_streams(name):
            held = [tunnel(family, True) for family in (0, 1)]
            tokens = []
            for family, sock in enumerate(held):
                tokens.append(exchange(name, family, sock, True, "existing-CONNECT-fixture"))
            streams.extend(held)
            return held, tokens

        def pushes(name, held, tokens, expected):
            for family, (sock, original) in enumerate(zip(held, tokens)):
                token = uuid.uuid4().hex
                received = False
                with LOCK:
                    source = BY_TOKEN[original]
                try:
                    source.sendall((token + "\n").encode())
                except OSError:
                    pass
                try:
                    data = sock.recv(4096)
                    if not expected and data:
                        raise AssertionError("unexpected server push after cut")
                    received = data == (token + "\n").encode()
                except OSError:
                    pass
                if received:
                    CLIENT_RECEIVED[token] = time.monotonic()
                CASES.append(dict(case=name, family=4 if family == 0 else 6, role="server-push-fixture",
                    direction="server-to-client", token=token, echo=received, reachedSink=received,
                    expected=expected, expectedBypass=False))
                if received != expected:
                    raise AssertionError(CASES[-1])

        def old_flows(name, held):
            for family, sock in enumerate(held):
                exchange(name, family, sock, False, "existing-CONNECT-fixture")
                sock.close()

        def unaffected(name):
            for family in (0, 1):
                exchange(name, family, unrelated_held[family], True, "unrelated-existing-stream-fixture")
                with connect(family, SERVERS[family].server_address[1]) as sock:
                    exchange(name, family, sock, True, "unrelated-new-stream-fixture")

        def bypass(name):
            for family in (0, 1):
                with connect(family, SERVERS[family].server_address[1]) as sock:
                    exchange(name, family, sock, True, "target-fixture-bypasses-proxy", True)
                token = uuid.uuid4().hex
                with socket.socket(socket.AF_INET if family == 0 else socket.AF_INET6, socket.SOCK_DGRAM) as udp:
                    udp.settimeout(.3)
                    udp.sendto((token + "\n").encode(), (HOSTS[family], SERVERS[2 + family].server_address[1]))
                    ack = udp.recv(4096) == (token + "\n").encode()
                with LOCK:
                    reached = token in SEEN
                CASES.append(dict(case=name + "-UDP", family=4 if family == 0 else 6,
                    role="target-fixture-bypasses-proxy", token=token, echo=ack, reachedSink=reached,
                    expected=True, expectedBypass=True))
                if not ack or not reached:
                    raise AssertionError("bypass positive control failed")

        try:
            ports = start()
            new_flows("default-deny", False)
            unaffected("default-deny-unrelated")
            bypass("VULNERABILITY-default-direct-bypass")
            for cause in ("JP", "unknown", "tunnel-down", "upstream-outage", "context", "expiry", "controller-EOF", "gateway-crash", "gateway-pause"):
                if cause == "gateway-pause":
                    ports = start()
                reply = command()
                if not reply["active"]:
                    raise AssertionError("fresh permit rejected")
                held, tokens = open_streams(cause + "-before")
                pushes(cause + "-push-before", held, tokens, True)
                if cause == "JP":
                    command(country="JP")
                elif cause == "unknown":
                    command(country=None)
                elif cause == "tunnel-down":
                    command(tunnel_ready=False)
                elif cause == "upstream-outage":
                    stop_hops()
                elif cause == "context":
                    command("context", context="route-2")
                elif cause == "expiry":
                    wait("revoked", "permit-expired")
                elif cause == "controller-EOF":
                    control.close()
                    wait("revoked", "controller-eof")
                elif cause == "gateway-crash":
                    gateway.kill()
                    gateway.wait(timeout=3)
                else:
                    gateway.send_signal(signal.SIGSTOP)
                    time.sleep(TTL + .15)
                    # Data queued while the gate is paused must not be forwarded
                    # when it resumes with expired evidence.
                    for sock in held:
                        sock.sendall(b"expired-queued-fixture\n")
                    gateway.send_signal(signal.SIGCONT)
                    wait("revoked", "permit-expired")
                pushes(cause + "-push-blocked", held, tokens, False)
                old_flows(cause + "-old-blocked", held)
                new_flows(cause + "-new-blocked", False)
                unaffected(cause + "-unrelated")
                bypass("VULNERABILITY-" + cause + "-direct-bypass")
                if cause == "context":
                    command("context", context="route-1")
                if cause == "upstream-outage":
                    start_hops()
                if cause == "controller-EOF":
                    gateway.terminate()
                    gateway.wait(timeout=3)
                    ports = start()
            # The last pause leaves a live, denied gateway: stale evidence must
            # not restore it, whereas fresh valid evidence should recover.
            command(sampled=time.monotonic() - TTL - 1)
            new_flows("stale-evidence-stays-denied", False)
            command()
            new_flows("fresh-evidence-recovers", True)
            command("revoke")
            new_flows("explicit-revoke", False)
            # The deprecated launcher is an experimental, per-process kernel
            # restriction. It is not a global app filter and cannot retrofit an
            # already-running process. No system network settings are changed.
            policy = root / "fixture.sb"
            policy.write_text('(version 1)\n(allow default)\n(deny network*)\n' +
                '(allow network-outbound (remote ip "localhost:' + str(ports[0]) + '") (remote ip "localhost:' + str(ports[1]) + '"))\n')
            worker_path = str(Path(__file__).with_name("socket_worker.py"))
            protected = subprocess.Popen(["/usr/bin/sandbox-exec", "-f", str(policy), sys.executable, worker_path],
                                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=(root/'worker.stderr').open('w'), text=True)
            ordinary = subprocess.Popen([sys.executable, worker_path], stdin=subprocess.PIPE,
                                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            workers.extend([protected, ordinary])
            def call(worker, message, expected, name):
                worker.stdin.write(json.dumps(message) + "\n")
                worker.stdin.flush()
                reply = json.loads(worker.stdout.readline())
                row = dict(case=name, expected=expected, result=reply, family=4 if message.get('host') == HOSTS[0] else 6)
                kernel_cases.append(row)
                if reply.get('ok') != expected or reply.get('unexpectedBytes'):
                    raise AssertionError(row)
                return reply
            for family, host in enumerate(HOSTS):
                key = str(family)
                direct = dict(op="connect", host=host, port=SERVERS[family].server_address[1], key=key)
                call(ordinary, direct, True, "unrelated-existing-open")
                call(protected, direct, False, "kernel-direct-TCP-denied")
                call(protected, dict(op="udp", host=host, port=SERVERS[2+family].server_address[1], token=uuid.uuid4().hex), False, "kernel-direct-UDP-denied")
                call(protected, dict(op="child", command=direct), False, "child-inherits-direct-denial")
            command()
            for family, host in enumerate(HOSTS):
                proxy = dict(op="connect", host=host, port=ports[family], key=str(family),
                             authority="fixture4.invalid:443" if family == 0 else "fixture6.invalid:443")
                call(protected, proxy, True, "kernel-proxy-route-allowed")
                call(protected, dict(op="send", host=host, key=str(family), token=uuid.uuid4().hex), True, "kernel-proxy-existing-positive")
            command("revoke")
            for family, host in enumerate(HOSTS):
                call(protected, dict(op="send", host=host, key=str(family), token=uuid.uuid4().hex), False, "kernel-proxy-existing-revoked")
                call(protected, dict(op="connect", host=host, port=ports[family], key="new", authority="fixture4.invalid:443" if family == 0 else "fixture6.invalid:443"), False, "kernel-proxy-new-revoked")
                call(protected, dict(op="connect", host=host, port=SERVERS[family].server_address[1], key="direct-after"), False, "kernel-direct-after-revoke-denied")
                call(ordinary, dict(op="send", host=host, key=str(family), token=uuid.uuid4().hex), True, "unrelated-existing-unaffected-by-kernel-gate")
                call(ordinary, dict(op="connect", host=host, port=SERVERS[family].server_address[1], key="new-unrelated"), True, "unrelated-new-unaffected-by-kernel-gate")
            command()
            for family, host in enumerate(HOSTS):
                call(protected, dict(op="connect", host=host, port=ports[family], key="recovery", authority="fixture4.invalid:443" if family == 0 else "fixture6.invalid:443"), True, "kernel-fresh-proxy-recovery")
            with LOCK:
                if "expired-queued-fixture" in SEEN:
                    raise AssertionError("expired buffered bytes were forwarded")
                for item in CASES:
                    receiver = CLIENT_RECEIVED if item.get("direction") == "server-to-client" else SEEN
                    item["receivedAtMonotonic"] = receiver.get(item["token"])
                    item["reachedSinkAtFinalRead"] = item["token"] in receiver
                    if item["reachedSinkAtFinalRead"] != item["expected"]:
                        raise AssertionError(item)
        except BaseException as failure:
            error = repr(failure)
        finally:
            for worker in workers:
                worker.stdin.close()
                try:
                    worker.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    worker.terminate()
                    worker.wait(timeout=2)
            stop_hops()
            if control:
                control.close()
            if gateway and gateway.poll() is None:
                gateway.send_signal(signal.SIGCONT)
                gateway.terminate()
                gateway.wait(timeout=3)
            for sock in streams:
                sock.close()
            cleanup = gateway is None or gateway.poll() is not None
            stderr = (root / "gateway.stderr").read_text() if (root / "gateway.stderr").exists() else ""
    result = dict(layer="dedicated-CONNECT-data-path-fixtures", os=platform.mac_ver()[0], arch=platform.machine(),
                  TTL=TTL, observations=len(CASES), cases=CASES, error=error, cleanup=cleanup,
                  experimentCompleted=error is None and cleanup, sourceOrchestration="fixture clients, same UID",
                  directBypassBlocked=False, actualClaudeOrCLI=False, nativePerAppFirewall="NOT_RUN",
                  noSystemNetworkOrGuardMutation=True, gatewayStderr=stderr, productionIntegration="HOLD")
    result.update(kernelLauncherCases=kernel_cases, kernelLauncher="deprecated sandbox-exec, launched fixtures only",
                  preexistingUnwrappedProcessesCovered=False, actualClaudeOrCLICompatibility="NOT_RUN")
    results.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k:v for k,v in result.items() if k != "cases"}, indent=2), flush=True)
    os._exit(0 if result["experimentCompleted"] else 1)


main()
