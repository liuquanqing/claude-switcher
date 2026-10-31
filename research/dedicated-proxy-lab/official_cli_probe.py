"""Official blank CLI via TLS fixture + CONNECT + process sandbox, hosted Mac only.
No real account, model request, trust-store install, firewall or routing mutation.
Temporary CA is trusted only through this child's NODE_EXTRA_CA_CERTS.
"""
import hashlib
import json
import os
import queue
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

if (not __debug__ or sys.platform != 'darwin' or os.environ.get('GITHUB_ACTIONS') != 'true' or
    os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted' or os.environ.get('CS_PROXY_LAB') != 'loopback-only'):
    raise SystemExit('Disposable hosted Mac only')

API = []
PUSH = 'fixture-start'
STOP = threading.Event()
class APIHandler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        API.append(dict(at=time.monotonic(), path=self.path))
        self.send_response(200)
        if 'count_tokens' in self.path:
            data = b'{"input_tokens":1}'
            self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(data)))
            self.end_headers(); self.wfile.write(data); return
        self.send_header('Content-Type', 'text/event-stream'); self.send_header('Connection', 'close'); self.end_headers()
        def sse(event, data):
            self.wfile.write(('event: '+event+'\ndata: '+json.dumps(data)+'\n\n').encode()); self.wfile.flush()
        try:
            sse('message_start', dict(type='message_start', message=dict(id='msg_fixture', type='message', role='assistant', model='claude-sonnet-4-6', content=[], stop_reason=None, stop_sequence=None, usage=dict(input_tokens=1, output_tokens=0))))
            sse('content_block_start', dict(type='content_block_start', index=0, content_block=dict(type='text', text='')))
            last = None
            while not STOP.is_set():
                if PUSH != last:
                    sse('content_block_delta', dict(type='content_block_delta', index=0, delta=dict(type='text_delta', text=PUSH)))
                    last = PUSH
                STOP.wait(.05)
        except OSError:
            pass

class Server6(ThreadingHTTPServer): address_family = socket.AF_INET6

root_result = Path(os.environ['CS_OFFICIAL_PROXY_RESULT'])
clients = []; gate = None; control = None; servers = []; logs = []; events = []; eventq = queue.Queue()
error = None; records = []; artifact = None; cleanup = False
def command(*args): return subprocess.run(args, capture_output=True, text=True, check=True, timeout=90)
with tempfile.TemporaryDirectory(prefix='cs-official-proxy-', dir=os.environ['RUNNER_TEMP']) as temporary:
    root = Path(temporary)
    try:
        version = '2.1.314'
        base = 'https://downloads.claude.ai/claude-code-releases/'+version
        manifest = json.loads(urllib.request.urlopen(base+'/manifest.json', timeout=30).read())
        binary = root/'claude-fixture'
        data = urllib.request.urlopen(base+'/darwin-x64/claude', timeout=90).read()
        digest = hashlib.sha256(data).hexdigest()
        if digest != manifest['platforms']['darwin-x64']['checksum']: raise ValueError('official CLI digest mismatch')
        binary.write_bytes(data); binary.chmod(0o755)
        command('codesign', '--verify', '--strict', str(binary))
        artifact = dict(version=version, SHA256=digest, officialManifestMatched=True)
        key, cert = root/'fixture.key', root/'fixture.pem'
        command('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=fixture4.invalid',
                '-addext', 'subjectAltName=DNS:fixture4.invalid,DNS:fixture6.invalid', '-keyout', str(key), '-out', str(cert))
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(cert, key)
        for cls, host in [(ThreadingHTTPServer, '127.0.0.1'), (Server6, '::1')]:
            server = cls((host, 0), APIHandler); server.socket = context.wrap_socket(server.socket, server_side=True)
            servers.append(server); threading.Thread(target=server.serve_forever, daemon=True).start()
        config = root/'manifest.json'
        config.write_text(json.dumps({'ttl': 3, 'targets': {'fixture4.invalid:443':['127.0.0.1',servers[0].server_address[1]], 'fixture6.invalid:443':['::1',servers[1].server_address[1]]}}))
        left,right = socket.socketpair()
        gate = subprocess.Popen([sys.executable,'-u',str(Path(__file__).with_name('gateway.py')),str(config),str(right.fileno())],pass_fds=(right.fileno(),),stdout=subprocess.PIPE,stderr=(root/'gateway.stderr').open('w'),text=True)
        right.close();control=left;control.settimeout(3)
        def read_events():
            for line in gate.stdout:
                value=json.loads(line);events.append(value);eventq.put(value)
        threading.Thread(target=read_events,daemon=True).start()
        ready=eventq.get(timeout=4)
        if ready['event']!='ready':raise AssertionError(ready)
        ports=ready['ports']
        policy=root/'proxy-only.sb';policy.write_text('(version 1)\n(allow default)\n(deny network*)\n(allow network-outbound (remote ip "localhost:'+str(ports[0])+'") (remote ip "localhost:'+str(ports[1])+'"))\n')
        def permit(active=True):
            msg=dict(op='permit' if active else 'revoke',country='SG',context='route-1',tunnelReady=True,sampledAt=time.monotonic(),id=uuid.uuid4().hex)
            control.sendall((json.dumps(msg)+'\n').encode());buf=b''
            while b'\n' not in buf:buf+=control.recv(4096)
            result=json.loads(buf)
            if result['id']!=msg['id'] or result['active']!=active:raise AssertionError(result)
            return result
        def launch(family):
            profile=root/('cli-'+uuid.uuid4().hex);profile.mkdir();home=root/('home-'+uuid.uuid4().hex);home.mkdir()
            proxy='http://127.0.0.1:'+str(ports[0]) if family==0 else 'http://[::1]:'+str(ports[1])
            env=dict(PATH='/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin',HOME=str(home),TMPDIR=str(root),LANG='en_US.UTF-8',
                     CLAUDE_CONFIG_DIR=str(profile),ANTHROPIC_API_KEY='sk-ant-api03-fixture-only-not-a-real-key',
                     ANTHROPIC_BASE_URL='https://fixture'+str(4 if family==0 else 6)+'.invalid',
                     HTTPS_PROXY=proxy,HTTP_PROXY=proxy,NO_PROXY='',NODE_EXTRA_CA_CERTS=str(cert),CLAUDE_CODE_CERT_STORE='bundled',
                     DISABLE_TELEMETRY='1',DISABLE_ERROR_REPORTING='1',CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1',
                     CLAUDE_CODE_GZIP_REQUEST_BODIES='0',API_TIMEOUT_MS='60000')
            path=root/('output-'+uuid.uuid4().hex);out=path.open('w');logs.append(out)
            p=subprocess.Popen(['/usr/bin/sandbox-exec','-f',str(policy),str(binary),'--bare','-p','Fixture only.','--output-format','stream-json','--verbose','--include-partial-messages','--max-turns','1','--tools','','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--disable-slash-commands','--no-session-persistence'],env=env,cwd=root,stdout=out,stderr=out)
            clients.append((p,path,family));return p,path
        def until(check, seconds, renew=True):
            deadline=time.monotonic()+seconds
            while time.monotonic()<deadline:
                if check():return
                if renew:permit()
                time.sleep(.1)
            raise AssertionError('official-client fixture condition timed out')
        permit()
        live=[launch(0),launch(1)]
        until(lambda:all('fixture-start' in path.read_text(errors='replace') for p,path in live),25)
        PUSH='before-cut-'+uuid.uuid4().hex
        until(lambda:all(PUSH in path.read_text(errors='replace') for p,path in live),3)
        records.append(dict(case='official-CLI-both-families-live-TLS-SSE',passed=True,processesAlive=[p.poll() is None for p,path in live]))
        cutoff=permit(False)['at'];PUSH='after-cut-'+uuid.uuid4().hex;time.sleep(.5)
        if any(PUSH in path.read_text(errors='replace') for p,path in live):raise AssertionError('post-revoke push reached official CLI')
        records.append(dict(case='official-CLI-existing-SSE-revoked',passed=True,cutoff=cutoff,processesAlive=[p.poll() is None for p,path in live],testerKilledClient=False))
        before=len(events);blocked=[launch(0),launch(1)]
        until(lambda:all(any(e.get('event')=='connect-attempt' and e.get('authority')=='fixture'+str(4 if f==0 else 6)+'.invalid:443' and not e.get('active') for e in events[before:]) for f in (0,1)),10,False)
        if any(entry['at']>cutoff for entry in API):raise AssertionError('new API request accepted after revocation')
        records.append(dict(case='official-CLI-new-TLS-attempts-rejected-both-families',passed=True))
        permit();fresh=[launch(0),launch(1)]
        until(lambda:all('fixture-start' in path.read_text(errors='replace') or PUSH in path.read_text(errors='replace') for p,path in fresh),20)
        records.append(dict(case='official-CLI-fresh-validation-recovery',passed=True))
    except BaseException as failure:
        error=repr(failure)
    finally:
        STOP.set()
        for p,path,family in clients:
            if p.poll() is None:
                p.terminate()
                try:p.wait(timeout=3)
                except subprocess.TimeoutExpired:p.kill();p.wait(timeout=3)
        if control:control.close()
        if gate and gate.poll() is None:gate.terminate();gate.wait(timeout=3)
        for log in logs:log.close()
        cleanup=all(p.poll() is not None for p,path,family in clients) and (gate is None or gate.poll() is not None)
        tails=[dict(family=4 if f==0 else 6,tail=path.read_text(errors='replace')[-2200:]) for p,path,f in clients] if error else []
result=dict(layer='official-blank-CLI-TLS-through-confined-CONNECT-fixture',artifact=artifact,cases=records,
            experimentCompleted=error is None and cleanup,error=error,cleanup=cleanup,fixtureOnlyCredentials=True,
            realSubscriptionAuthentication='NOT_RUN',desktopCompatibility='NOT_RUN',preexistingUnwrappedProcessesCovered=False,
            systemTrustStoreModified=False,networkOrGuardConfigModified=False,productionIntegration='HOLD',failureLogTails=tails)
root_result.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2),flush=True)
sys.exit(0 if result['experimentCompleted'] else 1)
