"""Fixture-only HTTP CONNECT relay. Not a production proxy or firewall.
Only inherited private control FD; only manifest-approved loopback upstreams.
No TLS termination, account data, system routing or firewall changes.
"""
import asyncio
import ipaddress
import json
import math
import socket
import sys
import time


class Gateway:
    def __init__(self, manifest):
        self.targets = manifest["targets"]
        for target in self.targets.values():
            if not ipaddress.ip_address(target[0]).is_loopback:
                raise ValueError("fixture upstream must be loopback")
        self.ttl = manifest["ttl"]
        self.context = "route-1"
        self.deadline = 0
        self.generation = 0
        self.connections = set()

    def active(self):
        return time.monotonic() < self.deadline

    def revoke(self, reason):
        self.deadline = 0
        self.generation += 1
        pairs = list(self.connections)
        for pair in pairs:
            for writer in pair:
                writer.close()
        print(json.dumps({"event": "revoked", "reason": reason,
                          "at": time.monotonic(), "connectionsClosed": len(pairs)}), flush=True)

    async def control(self, fd):
        sock = socket.socket(fileno=fd)
        reader, writer = await asyncio.open_connection(sock=sock)
        try:
            while line := await reader.readline():
                msg = {}
                try:
                    msg = json.loads(line)
                    if not isinstance(msg, dict):
                        raise ValueError("control object required")
                    if self.deadline and not self.active():
                        self.revoke("permit-expired")
                    if msg.get("op") == "context":
                        self.context = msg["context"]
                        self.revoke("context-changed")
                    elif msg.get("op") == "revoke":
                        self.revoke("explicit-revoke")
                    elif msg.get("op") == "permit":
                        sample = msg.get("sampledAt")
                        valid = (type(sample) in (int, float) and math.isfinite(sample) and
                                 0 <= time.monotonic() - sample < self.ttl and
                                 msg.get("country") == "SG" and msg.get("tunnelReady") is True and
                                 msg.get("context") == self.context)
                        if valid:
                            self.deadline = sample + self.ttl
                        else:
                            self.revoke("invalid-or-stale-evidence")
                    else:
                        self.revoke("invalid-control")
                except (ValueError, KeyError, TypeError):
                    self.revoke("invalid-control")
                writer.write((json.dumps({"id": msg.get("id") if isinstance(msg, dict) else None,
                                          "active": self.active(), "at": time.monotonic()}) + "\n").encode())
                await writer.drain()
        finally:
            self.revoke("controller-eof")
            writer.close()

    async def expiry(self):
        while True:
            await asyncio.sleep(.02)
            if self.deadline and not self.active():
                self.revoke("permit-expired")

    async def handle(self, reader, writer):
        upstream = None
        pair = None
        try:
            header = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 2)
            verb, authority, version = header.split(b"\r\n", 1)[0].decode("ascii").split()
            print(json.dumps({"event": "connect-attempt", "authority": authority,
                              "at": time.monotonic(), "active": self.active()}), flush=True)
            if verb != "CONNECT" or authority not in self.targets:
                writer.write(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
                await writer.drain()
                return
            if not self.active():
                writer.write(b"HTTP/1.1 503 Blocked\r\nContent-Length: 0\r\n\r\n")
                await writer.drain()
                return
            generation = self.generation
            upstream_reader, upstream = await asyncio.wait_for(asyncio.open_connection(*self.targets[authority]), 1)
            if not self.active() or generation != self.generation:
                return
            pair = (writer, upstream)
            self.connections.add(pair)
            writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            await writer.drain()

            async def pump(source, destination):
                while data := await source.read(4096):
                    # No await between permission check and write. Already sent
                    # bytes cannot be recalled; tests distinguish post-cut markers.
                    if not self.active() or generation != self.generation:
                        return
                    destination.write(data)
                    await destination.drain()

            tasks = [asyncio.create_task(pump(reader, upstream)),
                     asyncio.create_task(pump(upstream_reader, writer))]
            try:
                await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            finally:
                for task in tasks:
                    task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)
        except (OSError, ValueError, asyncio.IncompleteReadError, asyncio.LimitOverrunError, asyncio.TimeoutError):
            pass
        finally:
            if pair:
                self.connections.discard(pair)
            for stream in (writer, upstream):
                if stream:
                    stream.close()
                    try:
                        await stream.wait_closed()
                    except OSError:
                        pass


async def main():
    manifest = json.load(open(sys.argv[1]))
    gate = Gateway(manifest)
    servers = [await asyncio.start_server(gate.handle, host, 0, limit=8192) for host in ("127.0.0.1", "::1")]
    print(json.dumps({"event": "ready", "ports": [s.sockets[0].getsockname()[1] for s in servers]}), flush=True)
    await asyncio.gather(gate.control(int(sys.argv[2])), gate.expiry(), *(s.serve_forever() for s in servers))


if __name__ == "__main__":
    # The runner enforces the disposable environment. Standalone invocation also
    # refuses ordinary machines before opening any socket or reading a manifest.
    import os
    if (not __debug__ or sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true" or
            os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted" or
            os.environ.get("CS_PROXY_LAB") != "loopback-only"):
        raise SystemExit("Disposable hosted Mac fixture only")
    asyncio.run(main())
