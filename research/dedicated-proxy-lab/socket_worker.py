"""Disposable socket client, optionally launched under macOS Seatbelt.
Never claims to be Claude. Only loopback fixtures and parent-supplied markers.
"""
import ipaddress
import json
import os
import socket
import subprocess
import sys

if (not __debug__ or sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true" or
        os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted" or os.environ.get("CS_PROXY_LAB") != "loopback-only"):
    raise SystemExit("Disposable hosted Mac only")

streams = {}
def run(msg):
    host = msg.get("host", "127.0.0.1")
    if not ipaddress.ip_address(host).is_loopback:
        raise ValueError("loopback fixtures only")
    if msg["op"] == "child":
        child = subprocess.run([sys.executable, __file__, "--once", json.dumps(msg["command"])],
                               capture_output=True, text=True, check=True, timeout=3)
        return json.loads(child.stdout)
    if msg["op"] in ("connect", "udp"):
        stream = socket.socket(socket.AF_INET if ":" not in host else socket.AF_INET6,
                               socket.SOCK_DGRAM if msg["op"] == "udp" else socket.SOCK_STREAM)
        stream.settimeout(.3)
        try:
            stream.connect((host, msg["port"]))
            if msg["op"] == "udp":
                stream.sendall((msg["token"] + "\n").encode())
                return {"ok": stream.recv(4096) == (msg["token"] + "\n").encode()}
            if msg.get("authority"):
                stream.sendall(("CONNECT " + msg["authority"] + " HTTP/1.1\r\n\r\n").encode())
                reply = b""
                while b"\r\n\r\n" not in reply:
                    data = stream.recv(4096)
                    if not data:
                        break
                    reply += data
                if not reply.startswith(b"HTTP/1.1 200"):
                    return {"ok": False, "stage": "proxy-denied"}
            streams[msg["key"]] = stream
            stream = None
            return {"ok": True}
        except OSError as failure:
            return {"ok": False, "errno": failure.errno}
        finally:
            if stream:
                stream.close()
    if msg["op"] == "send":
        try:
            stream = streams[msg["key"]]
            stream.sendall((msg["token"] + "\n").encode())
            data = stream.recv(4096)
            return {"ok": data == (msg["token"] + "\n").encode(), "unexpectedBytes": bool(data) and data != (msg["token"] + "\n").encode()}
        except OSError as failure:
            return {"ok": False, "errno": failure.errno}
    raise ValueError("unknown fixture operation")

if len(sys.argv) == 3 and sys.argv[1] == "--once":
    print(json.dumps(run(json.loads(sys.argv[2]))), flush=True)
else:
    try:
        for line in sys.stdin:
            print(json.dumps(run(json.loads(line))), flush=True)
    finally:
        for stream in streams.values():
            stream.close()
