"""Pinned blank Desktop proxy/TLS-handshake test, disposable Mac only.
No fabricated Claude certificate, authentication, system install or real session.
Only CONNECT then ClientHello/EOF is observed; authenticated streams NOT_RUN.
"""
import hashlib,json,os,queue,socket,socketserver,subprocess,sys,tempfile,threading,time,urllib.request,uuid,plistlib
from pathlib import Path
if (not __debug__ or sys.platform!='darwin' or os.environ.get('GITHUB_ACTIONS')!='true' or
    os.environ.get('RUNNER_ENVIRONMENT')!='github-hosted' or os.environ.get('CS_PROXY_LAB')!='loopback-only'):
    raise SystemExit('Disposable hosted Mac only')

connections=[];events=[];eventq=queue.Queue();rows=[];clients=[];handles=[]
class Sink(socketserver.BaseRequestHandler):
    def handle(self):
        record=dict(openedAt=time.monotonic(),bytes=0,closedAt=None,tlsClientHello=False);connections.append(record)
        prefix=b''
        try:
            while data:=self.request.recv(4096):
                record['bytes']+=len(data);prefix=(prefix+data)[:6]
                record['tlsClientHello']=len(prefix)==6 and prefix[0]==22 and prefix[1]==3 and prefix[5]==1
        except OSError:pass
        finally:record['closedAt']=time.monotonic()
class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address=True;daemon_threads=True
def command(*args):return subprocess.run(args,capture_output=True,text=True,check=True,timeout=120)
gate=None;control=None;error=None;cleanup=False;artifact=None;tail='';app=None
def stop_own_clients():
    for p,path in clients:
        if p.poll() is None:
            p.terminate()
            try:p.wait(timeout=3)
            except subprocess.TimeoutExpired:p.kill();p.wait(timeout=3)
    if app is None:return []
    def own_helpers():
        found=[]
        for line in subprocess.check_output(['ps','-axww','-o','pid=,comm='],text=True).splitlines():
            values=line.strip().split(None,1)
            if len(values)==2 and values[1].startswith(str(app)+'/Contents/'):found.append(int(values[0]))
        return found
    for pid in own_helpers():
        try:os.kill(pid,15)
        except ProcessLookupError:pass
    for _ in range(20):
        remaining=own_helpers()
        if not remaining:return []
        time.sleep(.1)
    return remaining
with tempfile.TemporaryDirectory(prefix='cs-blank-desktop-proxy-',dir=os.environ['RUNNER_TEMP']) as temporary:
    root=Path(temporary)
    try:
        url='https://downloads.claude.ai/releases/darwin/universal/1.0.2768/Claude-21341c944a9d74880b52a77c4f1522f47f52d0da.pkg'
        data=urllib.request.urlopen(url,timeout=90).read();digest=hashlib.sha256(data).hexdigest()
        if digest!='895d1c4ee97fdb7a04585d00838eea85c5430140d8d0ef3e4a3b752fe59c6a8b':raise ValueError('pinned Desktop package mismatch')
        pkg=root/'Claude.pkg';pkg.write_bytes(data);command('/usr/sbin/pkgutil','--check-signature',str(pkg))
        expanded=root/'expanded';command('/usr/sbin/pkgutil','--expand-full',str(pkg),str(expanded))
        apps=list(expanded.rglob('Claude.app'))
        if len(apps)!=1:raise ValueError('unexpected package layout')
        app=apps[0];command('codesign','--verify','--deep','--strict',str(app))
        info=plistlib.loads((app/'Contents/Info.plist').read_bytes());binary=app/'Contents/MacOS'/info['CFBundleExecutable']
        artifact=dict(version=info['CFBundleShortVersionString'],SHA256Package=digest,signatureVerified=True,latestVersionClaim=False,installed=False)
        sink=Server(('127.0.0.1',0),Sink);threading.Thread(target=sink.serve_forever,daemon=True).start()
        authorities=['claude.ai:443','www.claude.ai:443','api.anthropic.com:443','claude.com:443']
        manifest=root/'manifest.json';manifest.write_text(json.dumps(dict(ttl=3,targets={host:['127.0.0.1',sink.server_address[1]] for host in authorities})))
        left,right=socket.socketpair()
        gate=subprocess.Popen([sys.executable,'-u',str(Path(__file__).with_name('gateway.py')),str(manifest),str(right.fileno())],pass_fds=(right.fileno(),),stdout=subprocess.PIPE,stderr=(root/'gateway.stderr').open('w'),text=True)
        right.close();control=left;control.settimeout(3)
        def read_events():
            for line in gate.stdout:
                value=json.loads(line);events.append(value);eventq.put(value)
        threading.Thread(target=read_events,daemon=True).start();ready=eventq.get(timeout=4)
        if ready['event']!='ready':raise AssertionError(ready)
        ports=ready['ports'];policy=root/'proxy-only.sb'
        policy.write_text('(version 1)\n(allow default)\n(deny network*)\n(allow network-outbound (remote ip "localhost:'+str(ports[0])+'") (remote ip "localhost:'+str(ports[1])+'"))\n')
        def permit(active=True):
            value=dict(op='permit' if active else 'revoke',country='SG',context='route-1',tunnelReady=True,sampledAt=time.monotonic(),id=uuid.uuid4().hex)
            control.sendall((json.dumps(value)+'\n').encode());buf=b''
            while b'\n' not in buf:buf+=control.recv(4096)
            reply=json.loads(buf)
            if reply['active']!=active or reply['id']!=value['id']:raise AssertionError(reply)
            return reply
        def launch():
            profile=root/('profile-'+uuid.uuid4().hex);profile.mkdir();home=root/('home-'+uuid.uuid4().hex);home.mkdir()
            path=root/('output-'+uuid.uuid4().hex);out=path.open('w');handles.append(out)
            env=dict(PATH='/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin',HOME=str(home),TMPDIR=str(root),LANG='en_US.UTF-8',DISABLE_TELEMETRY='1',DISABLE_ERROR_REPORTING='1')
            p=subprocess.Popen(['/usr/bin/sandbox-exec','-f',str(policy),str(binary),'--user-data-dir='+str(profile),'--proxy-server=http://127.0.0.1:'+str(ports[0]),'--no-first-run'],env=env,cwd=root,stdout=out,stderr=out)
            clients.append((p,path));return p
        def wait(check,seconds,renew):
            end=time.monotonic()+seconds
            while time.monotonic()<end:
                if check():return
                if renew:permit()
                time.sleep(.1)
            raise AssertionError('Desktop condition timed out')
        permit();p=launch()
        wait(lambda:any(c['tlsClientHello'] and c['closedAt'] is None for c in connections),25,True)
        held=[c for c in connections if c['tlsClientHello'] and c['closedAt'] is None]
        rows.append(dict(case='official-blank-Desktop-CONNECT-and-TLS-bytes-positive',passed=True,processAlive=p.poll() is None))
        cutoff=permit(False)['at'];wait(lambda:all(c['closedAt'] is not None for c in held),3,False)
        rows.append(dict(case='official-Desktop-existing-handshake-tunnel-closed',passed=True,cutoff=cutoff,processAlive=p.poll() is None,testerKilledClient=False))
        if stop_own_clients():raise AssertionError('old fixture helpers remained before new-client test')
        before=len(events);prior=len(connections);launch()
        wait(lambda:any(e.get('event')=='connect-attempt' and not e.get('active') for e in events[before:]),15,False)
        if len(connections)!=prior:raise AssertionError('Desktop upstream accepted while blocked')
        rows.append(dict(case='official-Desktop-new-CONNECT-denied',passed=True))
    except BaseException as failure:error=repr(failure)
    finally:
        remaining=stop_own_clients()
        if control:control.close()
        if gate and gate.poll() is None:gate.terminate();gate.wait(timeout=3)
        for handle in handles:handle.close()
        cleanup=not remaining and all(p.poll() is not None for p,path in clients) and (gate is None or gate.poll() is not None)
        if error:tail='\n'.join(path.read_text(errors='replace')[-1500:] for p,path in clients)
result=dict(layer='official-blank-Desktop-CONNECT-handshake-only',artifact=artifact,cases=rows,experimentCompleted=error is None and cleanup,error=error,cleanup=cleanup,
            fullTLSHandshake='NOT_RUN',authenticatedDesktopStreams='NOT_RUN',existingUnwrappedDesktopCovered=False,
            personalNetworkOrGuardModified=False,productionIntegration='HOLD',failureLogTail=tail)
Path(os.environ['CS_DESKTOP_PROXY_RESULT']).write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2),flush=True)
os._exit(0 if result['experimentCompleted'] else 1)
