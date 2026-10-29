"""Official blank clients + actual utun + expiring in-path permit.
Disposable hosted macOS only. Static PF rejects other fixture paths. Neither
this synthetic packet peer nor the runner-UID rules are a production backend.
"""
import ctypes, ipaddress, json, math, os, platform, queue, selectors, signal, socket, subprocess, sys, tempfile, threading, time, traceback, uuid
from pathlib import Path
from leased_utun_peer import Peer

assert sys.platform == 'darwin' and os.geteuid() == 0
assert os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'
assert os.environ.get('CS_REAL_UTUN_LAB') == 'ephemeral-only'
TTL = 1.2
PEERS = [(socket.AF_INET, '198.18.250.2'), (socket.AF_INET6, 'fdff:cc55::2')]


def emit(event, **data):
    print(json.dumps(dict(event=event, at=time.monotonic(), **data)), flush=True)


def executor(iface, fd):
    control = socket.socket(fileno=int(os.environ['CS_CONTROL_FD']))
    control.setblocking(False); os.set_blocking(fd, False)
    sel = selectors.DefaultSelector()
    sel.register(control, selectors.EVENT_READ, 'control'); sel.register(fd, selectors.EVENT_READ, 'data')
    deadline = 0; last_sample = -1; buf = b''; snapshot = False; push = False
    peer = Peer(fd, lambda: deadline > time.monotonic())

    def drain():
        while True:
            try: os.read(fd, 65535)
            except BlockingIOError: break

    def revoke(reason):
        nonlocal deadline
        previous=deadline
        deadline = 0; peer.flows.clear(); drain()
        emit('revoked', reason=reason,deadlineWas=previous)

    def notification(sig, frame):
        nonlocal snapshot, push
        if sig == signal.SIGUSR1: snapshot = True
        else: push = True

    signal.signal(signal.SIGUSR1, notification); signal.signal(signal.SIGUSR2, notification)
    emit('ready', interface=iface, permit=False, soleUtunOwner=True)
    while True:
        if deadline and time.monotonic() >= deadline: revoke('permit-expired')
        events = sel.select(.02)
        for key, _ in sorted(events, key=lambda item: item[0].data != 'control'):
            if key.data == 'control':
                try: data = control.recv(65535)
                except BlockingIOError: continue
                if not data:
                    revoke('controller-eof'); sel.unregister(control); control.close(); continue
                buf += data
                while b'\n' in buf:
                    line, buf = buf.split(b'\n', 1)
                    try: msg = json.loads(line)
                    except ValueError: revoke('invalid-control'); continue
                    sampled = msg.get('sampledAt'); now = time.monotonic()
                    if msg.get('country') != 'SG' or not isinstance(msg.get('revision'), str):
                        revoke('invalid-evidence'); continue
                    if not isinstance(sampled, (int, float)) or not math.isfinite(sampled) or not 0 <= now - sampled < TTL or sampled <= last_sample:
                        revoke('stale-evidence'); continue
                    # Resuming an expired executor must discard queued data before
                    # a new permit; old TCP state is never restored from disk.
                    if not deadline or deadline <= now:
                        peer.flows.clear(); drain()
                    last_sample = sampled; deadline = sampled + TTL
                    emit('permitted', deadline=deadline, sampledAt=sampled)
            else:
                try: raw = os.read(fd, 65535)
                except BlockingIOError: continue
                peer.consume(raw)
        if snapshot:
            emit('snapshot', stats=peer.snapshot(), permitted=deadline > time.monotonic(), deadline=deadline)
            snapshot = False
        if push:
            peer.push(); push = False


if len(sys.argv) == 3 and sys.argv[1].startswith('utun'):
    executor(sys.argv[1], int(sys.argv[2])); sys.exit(0)
if len(sys.argv) == 3 and sys.argv[1] == '--controller':
    control = socket.socket(fileno=int(sys.argv[2]))
    for line in sys.stdin: control.sendall(line.encode())
    sys.exit(0)


def command(*args, check=True):
    return subprocess.run(args, capture_output=True, text=True, check=check)


def progress(name):
    print('COMPOSITION '+name, file=sys.stderr, flush=True)


def pf(*args, check=True):
    return command('/sbin/pfctl', *args, check=check)


def kill(proc):
    if proc is None: return
    try: os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError: pass
    proc.wait(timeout=5)


artifacts = json.loads(Path(os.environ['CS_CLIENT_ARTIFACT_JSON']).read_text())
UID = int(os.environ['CS_TEST_UID']); assert UID > 0
original = Path('/etc/pf.conf').read_text(); was_enabled = 'Status: Enabled' in pf('-s', 'info').stdout
RESULTS = []; backend = controller = capture = None; interface = None; renewal = None; renewal_done = None
clients = []; streams = []; events = None; error = None; cleanup = False; physical_result = None
clean = {'PATH': '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin', 'LANG': 'en_US.UTF-8'}
cli_path=Path(artifacts['cli']).resolve(); desktop_path=Path(artifacts['desktop']).resolve()
assert cli_path.is_relative_to(Path(os.environ['RUNNER_TEMP']).resolve())
assert desktop_path.is_relative_to(Path(os.environ['RUNNER_TEMP']).resolve())
desktop_bundle=next(p for p in desktop_path.parents if p.name=='Claude.app')
libproc=ctypes.CDLL('/usr/lib/libproc.dylib'); cleaned_vendor_processes=[]

def owned_vendor_pids():
    owned=[]
    for value in command('/bin/ps','-axo','pid=').stdout.split():
        pid=int(value); path=ctypes.create_string_buffer(4096)
        if libproc.proc_pidpath(pid,path,4096)<=0: continue
        executable=Path(os.fsdecode(path.value)).resolve()
        if executable==cli_path or executable.is_relative_to(desktop_bundle): owned.append(pid)
    return owned

def cleanup_vendor_processes():
    # sudo/launchctl may give the launched command a different process group.
    # Match verified temporary executable paths, never a generic process name.
    owned=owned_vendor_pids()
    for pid in owned:
        try: os.kill(pid,signal.SIGKILL)
        except ProcessLookupError: pass
    time.sleep(.15)
    remaining=owned_vendor_pids(); assert not remaining,remaining
    cleaned_vendor_processes.append(len(owned))
# The GUI login UID is also the hosted runner UID. Preserve only the runner's
# already-observed HTTPS control destinations; never the synthetic test peers.
# Otherwise a long test can strand its own CI log/cancellation channel.
control_hosts=set(); runner_process=False
for line in command('/usr/sbin/lsof','-nP','-iTCP','-sTCP:ESTABLISHED','-Fpcn',check=False).stdout.splitlines():
    if line.startswith('p'): runner_process=False
    elif line.startswith('c'): runner_process=line[1:].startswith('Runner.')
    elif runner_process and line.startswith('n') and '->' in line:
        dest=line.split('->',1)[1]
        host,port=dest.rsplit(':',1)
        if port=='443':
            address=ipaddress.ip_address(host.strip('[]'))
            assert str(address) not in ('198.18.250.2','fdff:cc55::2')
            control_hosts.add(str(address))
assert control_hosts,'No observable CI control HTTPS destinations; refuse to isolate the runner UID'

with tempfile.TemporaryDirectory(prefix='cs-leased-tun-', dir=os.environ['RUNNER_TEMP']) as tmp:
    root = Path(tmp); root.chmod(0o755)
    work = root/'work'; work.mkdir(); os.chown(work, UID, -1)
    base = root/'pf.conf'; base.write_text(original + '\nanchor "cs_leased_lab"\n')
    rules = root/'rules.conf'

    def clear_states():
        for fam, host in PEERS: pf('-k', '0.0.0.0/0' if fam == socket.AF_INET else '::/0', '-k', host)

    def apply(iface=None):
        lines = []
        for fam, host in [('inet', '198.18.250.2'), ('inet6', 'fdff:cc55::2')]:
            if iface:
                lines += [f'pass out quick on {iface} {fam} proto {{ tcp udp }} from any to {host} port {{ 29300 29301 29302 }} keep state (if-bound)',
                          f'pass in quick on {iface} {fam} proto {{ tcp udp }} from {host} port {{ 29300 29301 29302 }} to any keep state (if-bound)']
            lines += [f'block drop out quick {fam} proto {{ tcp udp }} from any to {host} port {{ 29300 29301 29302 }}',
                      f'block drop in quick {fam} proto {{ tcp udp }} from {host} port {{ 29300 29301 29302 }} to any']
        lines += ['pass out quick on lo0 all']
        for host in sorted(control_hosts):
            fam='inet6' if ':' in host else 'inet'
            lines.append(f'pass out quick {fam} proto tcp from any to {host} port 443 user {UID} keep state')
        lines += [f'block drop out quick inet proto {{ tcp udp }} all user {UID}', f'block drop out quick inet6 proto {{ tcp udp }} all user {UID}']
        rules.write_text('\n'.join(lines)+'\n'); pf('-a','cs_leased_lab','-nf',str(rules)); pf('-a','cs_leased_lab','-f',str(rules))

    def wait(event, after=0, reason=None, timeout=5):
        end = time.monotonic()+timeout
        while time.monotonic() < end:
            value = events.get(timeout=max(.01,end-time.monotonic()))
            if value['event']==event and value['at'] >= after and (reason is None or value.get('reason')==reason): return value
        raise AssertionError((event, reason))

    def stats():
        at=time.monotonic(); backend.send_signal(signal.SIGUSR1)
        return wait('snapshot',after=at)

    def evidence(sampled=None, country='SG'):
        msg=dict(country=country,revision='fixture-path-one',sampledAt=time.monotonic() if sampled is None else sampled)
        controller.stdin.write(json.dumps(msg)+'\n'); controller.stdin.flush()

    def renew_start():
        global renewal, renewal_done
        at=time.monotonic(); evidence(); wait('permitted',after=at)
        renewal_done=threading.Event()
        def healthy():
            while not renewal_done.wait(TTL/4): evidence()
        renewal=threading.Thread(target=healthy,daemon=True); renewal.start()

    def renew_stop():
        global renewal
        if renewal is not None: renewal_done.set(); renewal.join(); renewal=None

    def stop_clients():
        for item in clients: kill(item['process']); item['log'].close()
        cleanup_vendor_processes()
        clients.clear()
        for _, sock in streams: sock.close()
        streams.clear()

    def stop_backend():
        global backend, controller
        progress('stop-backend')
        renew_stop(); kill(controller); controller=None; kill(backend); backend=None
        command('/sbin/route','-n','delete','-host','198.18.250.2',check=False)
        command('/sbin/route','-n','delete','-inet6','fdff:cc55::2',check=False)

    def start_backend():
        global backend, controller, events, interface
        progress('start-backend')
        apply(); clear_states()
        left,right=socket.socketpair(); events=queue.Queue()
        env={**os.environ,'CS_CONTROL_FD':str(right.fileno())}
        backend=subprocess.Popen([str(Path(__file__).with_name('utun-launch')),sys.executable,__file__],env=env,pass_fds=(right.fileno(),),stdout=subprocess.PIPE,stderr=(root/'executor.stderr').open('a'),text=True,start_new_session=True)
        right.close()
        def reader(proc, target):
            for line in proc.stdout: target.put(json.loads(line))
        threading.Thread(target=reader,args=(backend,events),daemon=True).start()
        interface=wait('ready')['interface']; assert interface.startswith('utun')
        controller=subprocess.Popen([sys.executable,__file__,'--controller',str(left.fileno())],pass_fds=(left.fileno(),),stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,text=True,start_new_session=True)
        left.close()
        command('/sbin/ifconfig',interface,'inet','198.18.250.1','198.18.250.2','netmask','255.255.255.252','up')
        command('/sbin/ifconfig',interface,'inet6','fdff:cc55::1','prefixlen','64','up')
        command('/sbin/route','-n','add','-inet6','fdff:cc55::2','-interface',interface)
        apply(interface); clear_states()

    def launch(kind, fam):
        profile=root/(kind+'-'+uuid.uuid4().hex); profile.mkdir(); os.chown(profile,UID,-1)
        host='198.18.250.2' if fam==4 else '[fdff:cc55::2]'
        if kind=='cli':
            env=['CLAUDE_CONFIG_DIR='+str(profile),'ANTHROPIC_API_KEY=isolated-invalid-fixture','ANTHROPIC_BASE_URL=http://'+host+':29300','API_TIMEOUT_MS=60000','DISABLE_TELEMETRY=1','DISABLE_ERROR_REPORTING=1','CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1']
            args=['sudo','-n','-u','#'+str(UID),'-H','/usr/bin/env',*env,artifacts['cli'],'--bare','-p','Fixture only.','--output-format','stream-json','--verbose','--include-partial-messages','--max-turns','1','--tools','','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--disable-slash-commands']
        else: args=['/bin/launchctl','asuser',str(UID),'sudo','-n','-u','#'+str(UID),'-H',artifacts['desktop'],'--user-data-dir='+str(profile),'--proxy-server=http://'+host+':29301','--no-first-run']
        path=root/('log-'+uuid.uuid4().hex); out=path.open('w')
        proc=subprocess.Popen(args,cwd=work,env=clean,stdout=out,stderr=out,start_new_session=True)
        clients.append(dict(kind=kind,family=fam,process=proc,path=path,log=out))

    def matrix(name, allowed):
        progress('matrix-start '+name)
        before=stats()['stats'] if backend.poll() is None else None
        start=len(clients)
        for fam in (4,6):
            for kind in ('cli','desktop'): launch(kind,fam)
        current=clients[start:]; began=time.monotonic(); deadline=began+30
        while time.monotonic()<deadline:
            now=stats()['stats'] if backend.poll() is None else None
            ready=True
            for item in current:
                key=str(item['family'])+(':'+str(29300 if item['kind']=='cli' else 29301))
                count=(now['http'].get(key,0)-before['http'].get(key,0)) if now else 0
                output=item['path'].read_text(errors='replace')
                ok=count>0 and item['process'].poll() is None
                if item['kind']=='cli': ok=ok and 'fixture-start' in output
                else: ok=ok and now['tls'].get(key,0)>before['tls'].get(key,0) if now else False
                ready=ready and ok
            attempted=now is not None and all(now['syn'].get(str(c['family'])+':'+str(29300 if c['kind']=='cli' else 29301),0)>before['syn'].get(str(c['family'])+':'+str(29300 if c['kind']=='cli' else 29301),0) for c in current)
            if allowed and ready: break
            if not allowed and time.monotonic()-began>=7 and (attempted or now is None): break
            time.sleep(.15)
        now=stats()['stats'] if backend.poll() is None else None
        for item in current:
            key=str(item['family'])+(':'+str(29300 if item['kind']=='cli' else 29301))
            count=(now['http'].get(key,0)-before['http'].get(key,0)) if now else 0
            alive=item['process'].poll() is None
            output=item['path'].read_text(errors='replace')
            marker='fixture-start' in output
            row=dict(case=name,kind=item['kind'],family=item['family'],requests=count,alive=alive,cliPartialReceived=marker if item['kind']=='cli' else None)
            if now is not None:
                row['synAttempts']=now['syn'].get(key,0)-before['syn'].get(key,0)
                if not allowed and row['synAttempts']==0: row['logTail']=output[-1800:]
                if not allowed: assert row['synAttempts']>0,row
            if allowed and (not alive or not count or (item['kind']=='cli' and not marker)):
                row['logTail']=output[-1800:]
            RESULTS.append(row)
            assert count>0 and alive and (marker if item['kind']=='cli' else now['tls'].get(key,0)>before['tls'].get(key,0)) if allowed else count==0,row
        if not allowed:
            for item in current: kill(item['process'])
        progress('matrix-done '+name)

    def open_streams():
        for fam,host in PEERS:
            for proto in ('tcp','udp'):
                sock=socket.socket(fam,socket.SOCK_STREAM if proto=='tcp' else socket.SOCK_DGRAM); sock.settimeout(.5); sock.connect((host,29302 if proto=='tcp' else 29300))
                token=uuid.uuid4().hex.encode(); sock.sendall(token); assert sock.recv(4096)==token
                streams.append((proto,sock))

    def stopped_streams(name):
        for proto,sock in streams:
            token=uuid.uuid4().hex.encode(); received=False
            try: sock.sendall(token); received=sock.recv(4096)==token
            except OSError: pass
            RESULTS.append(dict(case=name,protocol=proto,family=4 if sock.family==socket.AF_INET else 6,echo=received))
            assert not received

    def fault_observation(name, trigger):
        progress('fault-start '+name)
        before=stats()['stats']; assert all(c['process'].poll() is None for c in clients)
        backend.send_signal(signal.SIGUSR2); end=time.monotonic()+3
        while time.monotonic()<end:
            current=stats()['stats']
            received=all('fixture-push' in c['path'].read_text(errors='replace') for c in clients if c['kind']=='cli')
            if current['pushes']>=before['pushes']+2 and received: break
            time.sleep(.1)
        assert current['pushes']>=before['pushes']+2 and received,'live CLI push positive control missing'
        RESULTS.append(dict(case=name+'-live-CLI-push-positive-control',bothFamiliesReceived=True))
        before=current; renew_stop()
        fault=trigger()
        at=time.monotonic(); backend.send_signal(signal.SIGUSR2); time.sleep(.2)
        after=stats()
        cutoff=fault['deadlineWas'] if fault['reason']=='permit-expired' else fault['at']
        late=[e for e in after['stats']['httpEvents'] if e['at']>cutoff]
        assert not after['permitted'] and not late,(after['permitted'],late,fault)
        assert after['stats']['pushes']==before['pushes'] and after['stats']['deniedPushes']>before['deniedPushes']
        RESULTS.append(dict(case=name+'-live-client-revocation',noRequestsAfterRevocation=True,pushDenied=True,clientProcessesAlive=sum(c['process'].poll() is None for c in clients),cutoff=cutoff))
        stopped_streams(name+'-existing-flow-denied'); matrix(name+'-new-clients-denied',False)
        progress('fault-done '+name)

    try:
        pf('-nf',str(base)); pf('-f',str(base)); apply(); pf('-e',check=False)
        route=command('/sbin/route','-n','get','default').stdout
        physical=next(s.split(':',1)[1].strip() for s in route.splitlines() if s.strip().startswith('interface:')); assert physical.startswith('en')
        capture_log=(root/'capture.log').open('w')
        capture=subprocess.Popen(['/usr/sbin/tcpdump','-n','-U','-i',physical,'-w',str(root/'physical.pcap'),'(dst host 198.18.250.2 or dst host fdff:cc55::2) and (tcp or udp) and dst portrange 29300-29302'],stdout=subprocess.DEVNULL,stderr=capture_log)
        time.sleep(.5); assert capture.poll() is None and 'listening on '+physical in (root/'capture.log').read_text()
        start_backend(); matrix('initial-default-deny',False); stop_clients()
        renew_start(); matrix('healthy-before-expiry',True); open_streams()
        fault_observation('permit-expiry',lambda:wait('revoked',reason='permit-expired'))
        stop_clients(); matrix('expired-without-new-evidence',False); stop_clients()
        at=time.monotonic(); evidence(sampled=at-TTL-2); wait('revoked',after=at,reason='stale-evidence')
        matrix('old-evidence-denied',False); stop_clients()
        renew_start(); matrix('fresh-recovery-before-controller-kill',True); open_streams()
        def controller_killed():
            at=time.monotonic(); kill(controller); return wait('revoked',after=at,reason='controller-eof')
        fault_observation('controller-kill',controller_killed)
        stop_clients(); stop_backend(); start_backend(); matrix('restart-default-deny',False); stop_clients()
        renew_start(); matrix('fresh-recovery-before-executor-stop',True); open_streams()
        def executor_stopped():
            backend.send_signal(signal.SIGSTOP); evidence(); time.sleep(TTL+.25); at=time.monotonic(); backend.send_signal(signal.SIGCONT)
            return wait('revoked',after=at,reason='stale-evidence')
        fault_observation('executor-stop-expired-queued-evidence',executor_stopped)
        stop_clients(); renew_start(); matrix('fresh-recovery-before-executor-kill',True); open_streams(); renew_stop()
        kill(backend); assert command('/sbin/ifconfig',interface,check=False).returncode!=0,'utun survived sole-owner exit'
        stopped_streams('executor-kill-existing-flow-denied'); matrix('executor-kill-new-clients-denied',False)
        RESULTS.append(dict(case='executor-kill-removes-utun',interfaceAbsent=True))
        stop_clients(); stop_backend(); start_backend(); matrix('executor-restart-default-deny',False); stop_clients()
        renew_start(); matrix('fresh-evidence-after-executor-restart',True); stop_clients(); stop_backend()
        capture.send_signal(signal.SIGINT); capture.wait(timeout=5); capture_log.close(); assert capture.returncode==0
        packets=command('/usr/sbin/tcpdump','-n','-r',str(root/'physical.pcap')).stdout.splitlines()
        physical_result=dict(interface=physical,syntheticTargetPackets=len(packets),captureReady=True); assert not packets
    except BaseException as e:
        error=repr(e)+' traceback='+traceback.format_exc()
        if isinstance(e,subprocess.CalledProcessError): error+=' stderr='+e.stderr
        if (root/'executor.stderr').exists(): error+=' executorStderr='+ (root/'executor.stderr').read_text(errors='replace')[-2000:]
    finally:
        stop_clients(); stop_backend()
        if capture is not None and capture.poll() is None: capture.send_signal(signal.SIGINT); capture.wait(timeout=5)
        a=pf('-a','cs_leased_lab','-F','rules',check=False); b=pf('-f','/etc/pf.conf',check=False)
        c=pf('-d',check=False) if not was_enabled else None
        cleanup=a.returncode==0 and b.returncode==0 and (c is None or c.returncode==0)
result=dict(layer='official-clients-real-utun-expiring-permit-composition',os=platform.mac_ver()[0],arch=platform.machine(),leaseSeconds=TTL,count=len(RESULTS),cases=RESULTS,error=error,cleanup=cleanup,allAssertionsPassed=error is None and cleanup,physicalCapture=physical_result,ciControlHTTPSDestinations=len(control_hosts),temporaryVendorProcessesKilled=cleaned_vendor_processes,actualTUN=True,actualOfficialClients=True,syntheticAPI=True,realAccountUsed=False,NetworkExtension='NOT_RUN',productionReady=False)
print(json.dumps(result,indent=2),flush=True);os._exit(0 if result['allAssertionsPassed'] else 1)
