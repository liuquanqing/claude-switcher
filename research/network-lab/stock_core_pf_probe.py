"""Independent stock sing-box TUN + PF executor failure experiment.
Disposable hosted Mac only. Synthetic TCP echoes, no subscriptions/accounts.
A green experiment includes reproducing PF's stale-grant vulnerability; HOLD.
"""
import hashlib,json,os,platform,queue,select,signal,socket,socketserver,subprocess,sys,tarfile,tempfile,threading,time,traceback,urllib.request,uuid
from pathlib import Path
assert sys.platform=='darwin' and os.geteuid()==0
assert os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'
assert os.environ.get('CS_STOCK_CORE_LAB')=='ephemeral-only'
PEERS=[(socket.AF_INET,'198.18.251.2'),(socket.AF_INET6,'fdff:cc77::2')]
IFACE='utun77';TTL=1.2;PORT=29600

def command(*args,check=True):return subprocess.run(args,text=True,capture_output=True,check=check)
def pf(*args,check=True):return command('/sbin/pfctl',*args,check=check)
def emit(event,**data):print(json.dumps(dict(event=event,at=time.monotonic(),**data)),flush=True)
def clear_states():
    for fam,host in PEERS:pf('-k','0.0.0.0/0' if fam==socket.AF_INET else '::/0','-k',host)
def apply(allow):
    lines=[]
    for fam,host in [('inet',PEERS[0][1]),('inet6',PEERS[1][1])]:
        if allow:lines += [f'pass out quick on {IFACE} {fam} proto tcp from any to {host} port {PORT} keep state (if-bound)',f'pass in quick on {IFACE} {fam} proto tcp from {host} port {PORT} to any keep state (if-bound)']
        lines += [f'block drop out quick {fam} proto tcp from any to {host} port {PORT}',f'block drop in quick {fam} proto tcp from {host} port {PORT} to any']
    path=Path(os.environ['CS_PF_DIR'])/'rules.conf';path.write_text('\n'.join(lines)+'\n')
    pf('-a','cs_stock_lab','-nf',str(path));pf('-a','cs_stock_lab','-f',str(path))

if len(sys.argv)>1 and sys.argv[1]=='--executor':
    control=socket.socket(fileno=int(sys.argv[2]));control.setblocking(False)
    deadline=0;allowed=False;buf=b'';apply(False);clear_states();emit('ready')
    while True:
        if allowed and time.monotonic()>=deadline:
            apply(False);clear_states();allowed=False;emit('revoked',reason='expired')
        if not select.select([control],[],[],.02)[0]:continue
        data=control.recv(65535)
        if not data:
            apply(False);clear_states();emit('revoked',reason='controller-eof')
            while True:time.sleep(1)
        buf+=data
        while b'\n' in buf:
            line,buf=buf.split(b'\n',1);msg=json.loads(line);sampled=msg['sampledAt']
            if msg['country']!='SG' or not 0<=time.monotonic()-sampled<TTL:
                apply(False);clear_states();allowed=False;emit('revoked',reason='invalid-evidence');continue
            if not allowed:apply(True);clear_states();allowed=True
            deadline=sampled+TTL;emit('permitted',deadline=deadline)
if len(sys.argv)>1 and sys.argv[1]=='--controller':
    control=socket.socket(fileno=int(sys.argv[2]))
    for line in sys.stdin:control.sendall(line.encode())
    sys.exit(0)

SEEN=set();OUTER_UP=True;CONNECTS=[]
class Outer(socketserver.StreamRequestHandler):
    def handle(self):
        first=self.rfile.readline()
        if not first.startswith(b'CONNECT '):return
        while self.rfile.readline() not in (b'\r\n',b'\n',b''):pass
        CONNECTS.append(first.decode().strip())
        if not OUTER_UP:return
        self.wfile.write(b'HTTP/1.1 200 Connection Established\r\n\r\n');self.wfile.flush()
        for line in self.rfile:
            if not OUTER_UP:return
            SEEN.add(line.decode().strip());self.wfile.write(line);self.wfile.flush()
class Server(socketserver.ThreadingTCPServer):allow_reuse_address=True;daemon_threads=True

original=Path('/etc/pf.conf').read_text();was_enabled='Status: Enabled' in pf('-s','info').stdout
core=executor=controller=capture=None;renew=None;done=None;events=None;error=None;cleanup=False;cases=[];held=[];physical_result=None;helper_crash_blocks='NOT_RUN'
def kill(p):
    if p is not None and p.poll() is None:p.kill();p.wait(timeout=5)
with tempfile.TemporaryDirectory(prefix='cs-stock-core-',dir=os.environ['RUNNER_TEMP']) as tmp:
    root=Path(tmp);os.environ['CS_PF_DIR']=str(root)
    def wait(event,after=0,reason=None):
        end=time.monotonic()+5
        while time.monotonic()<end:
            v=events.get(timeout=max(.01,end-time.monotonic()))
            if v['event']==event and v['at']>=after and (reason is None or v.get('reason')==reason):return v
        raise AssertionError((event,reason))
    def evidence(country='SG'):
        controller.stdin.write(json.dumps(dict(country=country,sampledAt=time.monotonic()))+'\n');controller.stdin.flush()
    def renew_start():
        global renew,done
        at=time.monotonic();evidence();wait('permitted',after=at);done=threading.Event()
        def healthy():
            while not done.wait(TTL/4):evidence()
        renew=threading.Thread(target=healthy,daemon=True);renew.start()
    def renew_stop():
        global renew
        if renew is not None:done.set();renew.join();renew=None
    def start_executor():
        global executor,controller,events
        left,right=socket.socketpair();events=queue.Queue()
        executor=subprocess.Popen([sys.executable,__file__,'--executor',str(right.fileno())],pass_fds=(right.fileno(),),stdout=subprocess.PIPE,text=True)
        right.close()
        def reader(p,q):
            for line in p.stdout:q.put(json.loads(line))
        threading.Thread(target=reader,args=(executor,events),daemon=True).start();wait('ready')
        controller=subprocess.Popen([sys.executable,__file__,'--controller',str(left.fileno())],pass_fds=(left.fileno(),),stdin=subprocess.PIPE,text=True,stdout=subprocess.DEVNULL);left.close()
    def stop_executor():
        renew_stop();kill(controller);kill(executor)
    def probe(name,expected,use_held=False):
        for index,(fam,host) in enumerate(PEERS):
            sock=held[index] if use_held else socket.socket(fam,socket.SOCK_STREAM)
            sock.settimeout(.5);token=uuid.uuid4().hex;ack=False
            try:
                if not use_held:sock.connect((host,PORT))
                sock.sendall((token+'\n').encode());ack=sock.recv(4096)==(token+'\n').encode()
            except OSError:pass
            finally:
                if not use_held:sock.close()
            reached=token in SEEN
            cases.append(dict(case=name,family=4 if fam==socket.AF_INET else 6,echo=ack,reachedOuter=reached))
            assert ack==expected and reached==expected,cases[-1]
    def open_streams():
        for fam,host in PEERS:
            s=socket.socket(fam,socket.SOCK_STREAM);s.settimeout(1);s.connect((host,PORT));held.append(s)
    def close_streams():
        for s in held:s.close()
        held.clear()
    try:
        data=urllib.request.urlopen('https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-darwin-amd64.tar.gz',timeout=90).read()
        digest=hashlib.sha256(data).hexdigest();assert digest=='eae86b9b033bba50b7c44ab719e4bfac0aca05efd28483390ed3aa510f32db25'
        archive=root/'core.tar.gz';archive.write_bytes(data)
        with tarfile.open(archive) as tar:
            member=tar.getmember('sing-box-1.14.4-darwin-amd64/sing-box');assert member.isfile()
            binary=root/'sing-box';binary.write_bytes(tar.extractfile(member).read());binary.chmod(0o755)
        version=command(str(binary),'version').stdout
        assert command('/sbin/ifconfig',IFACE,check=False).returncode!=0
        server=Server(('127.0.0.1',29601),Outer);threading.Thread(target=server.serve_forever,daemon=True).start()
        config=dict(log=dict(level='warn'),inbounds=[dict(type='tun',tag='tun',interface_name=IFACE,address=['198.18.252.1/30','fdff:cc66::1/126'],mtu=1500,auto_route=False,dns_mode='disabled',stack='gvisor')],outbounds=[dict(type='http',tag='outer',server='127.0.0.1',server_port=29601)],route=dict(final='outer'))
        conf=root/'config.json';conf.write_text(json.dumps(config));command(str(binary),'check','-c',str(conf))
        base=root/'pf.conf';base.write_text(original+'\nanchor "cs_stock_lab"\n');pf('-nf',str(base));pf('-f',str(base));apply(False);pf('-e',check=False)
        default_before=command('/sbin/route','-n','get','default').stdout
        physical=next(x.split(':',1)[1].strip() for x in default_before.splitlines() if x.strip().startswith('interface:'));assert physical.startswith('en')
        caplog=(root/'capture.log').open('w');capture=subprocess.Popen(['/usr/sbin/tcpdump','-n','-U','-i',physical,'-w',str(root/'physical.pcap'),'(dst host 198.18.251.2 or dst host fdff:cc77::2) and tcp and dst port 29600'],stderr=caplog,stdout=subprocess.DEVNULL)
        time.sleep(.5);assert capture.poll() is None and 'listening on '+physical in (root/'capture.log').read_text()
        corelog=(root/'core.log').open('w');core=subprocess.Popen([str(binary),'run','-c',str(conf)],stdout=corelog,stderr=corelog)
        end=time.monotonic()+10
        while time.monotonic()<end and command('/sbin/ifconfig',IFACE,check=False).returncode!=0:
            assert core.poll() is None,(root/'core.log').read_text();time.sleep(.1)
        assert command('/sbin/ifconfig',IFACE,check=False).returncode==0
        command('/sbin/route','-n','add','-host',PEERS[0][1],'-interface',IFACE)
        command('/sbin/route','-n','add','-inet6',PEERS[1][1],'-interface',IFACE)
        start_executor();probe('default-deny',False);renew_start();probe('stock-core-approved',True)
        open_streams();probe('existing-stock-core-positive',True,True);renew_stop()
        at=time.monotonic();evidence('JP');wait('revoked',after=at,reason='invalid-evidence')
        probe('wrong-country-existing-denied',False,True);probe('wrong-country-new-denied',False);close_streams()
        renew_start();probe('new-evidence-recovery',True);renew_stop();wait('revoked',reason='expired');probe('permit-expired-denied',False)
        renew_start();at=time.monotonic();renew_stop();kill(controller);wait('revoked',after=at,reason='controller-eof');probe('controller-crash-helper-survives-denied',False)
        stop_executor();start_executor();renew_start();open_streams();probe('before-executor-crash',True,True);renew_stop();kill(executor);time.sleep(TTL+.3)
        assert core.poll() is None and command('/sbin/ifconfig',IFACE,check=False).returncode==0
        probe('VULNERABILITY-executor-crash-old-flow-still-allowed',True,True)
        probe('VULNERABILITY-executor-crash-new-flow-still-allowed',True)
        helper_crash_blocks=False
        apply(False);clear_states();probe('manual-revoke-after-executor-crash',False);close_streams();kill(controller)
        start_executor();renew_start();probe('fresh-recovery-before-proxy-outage',True)
        OUTER_UP=False;probe('outer-proxy-outage-denied',False);OUTER_UP=True;probe('outer-proxy-recovery',True)
        kill(core);assert command('/sbin/ifconfig',IFACE,check=False).returncode!=0
        probe('stock-core-crash-no-direct-fallback',False)
        stop_executor();apply(False);clear_states()
        capture.send_signal(signal.SIGINT);capture.wait(timeout=5);caplog.close();assert capture.returncode==0
        packets=command('/usr/sbin/tcpdump','-n','-r',str(root/'physical.pcap')).stdout.splitlines()
        physical_result=dict(interface=physical,syntheticTargetPackets=len(packets));assert not packets
        default_after=command('/sbin/route','-n','get','default').stdout
        assert [x.strip() for x in default_before.splitlines() if x.strip().startswith(('gateway:','interface:'))]==[x.strip() for x in default_after.splitlines() if x.strip().startswith(('gateway:','interface:'))]
    except BaseException as e:
        error=traceback.format_exc()
        if (root/'core.log').exists():error+=' coreLog='+ (root/'core.log').read_text()[-3000:]
        if isinstance(e,subprocess.CalledProcessError):error+=' stderr='+e.stderr
    finally:
        try:
            close_streams();stop_executor();kill(core)
            if capture is not None and capture.poll() is None:capture.send_signal(signal.SIGINT);capture.wait(timeout=5)
            command('/sbin/route','-n','delete','-host',PEERS[0][1],check=False);command('/sbin/route','-n','delete','-inet6',PEERS[1][1],check=False)
        except BaseException:error=(error or '')+' cleanup='+traceback.format_exc()
        finally:
            a=pf('-a','cs_stock_lab','-F','rules',check=False);b=pf('-f','/etc/pf.conf',check=False);c=pf('-d',check=False) if not was_enabled else None
            cleanup=a.returncode==0 and b.returncode==0 and (c is None or c.returncode==0)
result=dict(layer='independent-stock-core-and-PF-executor',os=platform.mac_ver()[0],coreVersion=locals().get('version'),coreArchiveSHA256=locals().get('digest'),sourceTag='v1.14.4',sourceCommit='c005f35300ce76427dc285481ec5695f5b179cd2',count=len(cases),cases=cases,error=error,cleanup=cleanup,experimentPassed=error is None and cleanup,helperCrashBlocks=helper_crash_blocks,physicalCapture=physical_result,ShadowrocketCompatibility='NOT_RUN',officialClaudeClients='NOT_RUN_IN_THIS_EXPERIMENT',outerPhysicalException='NOT_RUN: loopback outer fixture only',realCountryChange=False,defaultRouteChanged=False,productionIntegration='HOLD')
print(json.dumps(result,indent=2),flush=True)
output=Path(os.environ['CS_STOCK_RESULT']);assert output.is_relative_to(Path(os.environ['RUNNER_TEMP']))
output.write_text(json.dumps(result,indent=2)+'\n')
os._exit(0 if result['experimentPassed'] else 1)
