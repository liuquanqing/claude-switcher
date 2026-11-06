#!/usr/bin/env python3
"""Loopback-only sandbox check. No system routes, accounts or service changes."""
import http.server, threading, subprocess, json
class Handler(http.server.BaseHTTPRequestHandler):
    hits=0
    def do_GET(self):
        self.server.hits+=1;self.send_response(200);self.end_headers();self.wfile.write(b'fixture')
    def log_message(self,*args):pass
servers=[]
try:
    for _ in range(2):
        s=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);s.hits=0;servers.append(s)
        threading.Thread(target=s.serve_forever,daemon=True).start()
    allowed,other=servers
    port=allowed.server_port;second=other.server_port
    policy=f'(version 1) (allow default) (deny network*) (allow network-outbound (remote ip "localhost:{port}"))'
    def request(p,sandbox=True):
        command=['/usr/bin/curl','-q','--silent','--fail','--max-time','2','--noproxy','*',f'http://127.0.0.1:{p}']
        if sandbox:command=['/usr/bin/sandbox-exec','-p',policy]+command
        return subprocess.run(command,capture_output=True,timeout=5)
    r=request(port)
    assert r.returncode==0 and allowed.hits==1, (r.returncode,r.stderr.decode())
    assert request(second).returncode!=0 and other.hits==0
    assert request(second,False).returncode==0 and other.hits==1
    allowed.shutdown();allowed.server_close()
    assert request(port).returncode!=0
    assert other.hits==1
    print(json.dumps({'allowedProxyPort':'PASS','otherPortBlocked':'PASS','unrelatedProcessUnaffected':'PASS','closedProxyFails':'PASS'}))
finally:
    for s in servers:s.shutdown();s.server_close()
