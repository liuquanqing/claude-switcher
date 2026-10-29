"""Isolated data-path gate experiment, NOT production or a Network Extension.
Default deny; monotonic permit; private inherited control FD; closes streams on revoke.
Only fake loopback echoes. Never run this on a personal Mac.
"""
import json,math,os,platform,queue,selectors,signal,socket,socketserver,subprocess,sys,threading,time,uuid
from pathlib import Path
TTL=1.2
TARGETS=[(socket.AF_INET,'127.0.0.1'),(socket.AF_INET6,'::1')]
def guard():
 if sys.platform=='darwin':
  assert os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'
  assert os.environ.get('CS_DISPOSABLE_NETWORK_LAB')=='github-hosted-loopback-only'
 else:assert sys.platform=='linux' and os.environ.get('CS_ISOLATED_LAB')=='network-none-container'
def emit(**x): print(json.dumps(x),flush=True)
def broker(fd):
 sel=selectors.DefaultSelector();control=socket.socket(fileno=fd);control.setblocking(False);sel.register(control,selectors.EVENT_READ,('control',None))
 streams=set();deadline=0;revision=None;buf=b'';permit=False
 def revoke(reason):
  nonlocal permit,deadline,revision
  permit=False;deadline=0;revision=None
  for s in list(streams):
   sel.unregister(s);s.close();streams.remove(s)
  emit(event='revoked',reason=reason)
 for family,host in TARGETS:
  for proto in ('tcp','udp'):
   s=socket.socket(family,socket.SOCK_STREAM if proto=='tcp' else socket.SOCK_DGRAM);s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind((host,29100+(proto=='udp')))
   if proto=='tcp':s.listen()
   s.setblocking(False);sel.register(s,selectors.EVENT_READ,(proto,family))
 emit(event='ready')
 while True:
  if permit and time.monotonic()>=deadline:revoke('permit-expired')
  events=sel.select(.02)
  # Process control messages before new client data in the same batch.
  for key,_ in sorted(events,key=lambda e:e[0].data[0]!='control'):
   kind,family=key.data;s=key.fileobj
   if kind=='control':
    data=control.recv(4096)
    if not data:
     revoke('controller-eof');sel.unregister(control);control.close();continue
    buf+=data
    while b'\n' in buf:
     line,buf=buf.split(b'\n',1)
     try:msg=json.loads(line)
     except ValueError:revoke('invalid-control');continue
     # This fixture's SG is fake verified evidence, not real geolocation.
     if msg.get('country')!='SG' or not isinstance(msg.get('revision'),str):revoke('country-or-evidence-invalid');continue
     sampled=msg.get('sampledAt');now=time.monotonic()
     if not isinstance(sampled,(int,float)) or not math.isfinite(sampled) or not 0<=now-sampled<TTL:
      revoke('stale-evidence');continue
     new_revision=msg['revision']
     if revision is not None and revision!=new_revision:revoke('context-changed')
     revision=new_revision;permit=True;deadline=sampled+TTL;emit(event='permitted',revision=revision)
   elif kind=='tcp':
    c,_=s.accept()
    if not permit or time.monotonic()>=deadline:c.close();continue
    c.setblocking(False);streams.add(c);sel.register(c,selectors.EVENT_READ,('stream',family))
   elif kind=='stream':
    if s not in streams:continue
    try:data=s.recv(4096)
    except OSError:data=b''
    if not data or not permit or time.monotonic()>=deadline:
     sel.unregister(s);streams.remove(s);s.close();continue
    host='127.0.0.1' if family==socket.AF_INET else '::1'
    try:
     with socket.socket(family,socket.SOCK_STREAM) as upstream:
      upstream.settimeout(.15);upstream.connect((host,29200));upstream.sendall(data);reply=upstream.recv(4096)
     s.sendall(reply)
    except OSError:
     sel.unregister(s);streams.remove(s);s.close()
   elif kind=='udp':
    data,peer=s.recvfrom(4096)
    if not permit or time.monotonic()>=deadline:continue
    host='127.0.0.1' if family==socket.AF_INET else '::1'
    try:
     with socket.socket(family,socket.SOCK_DGRAM) as upstream:
      upstream.settimeout(.15);upstream.sendto(data,(host,29201));reply,_=upstream.recvfrom(4096)
     s.sendto(reply,peer)
    except OSError:pass

def controller(fd):
 sock=socket.socket(fileno=fd)
 for line in sys.stdin:
  sock.sendall(line.encode())

SEEN=set()
class TCP(socketserver.BaseRequestHandler):
 def handle(self):
  data=self.request.recv(4096);SEEN.add(data.decode());self.request.sendall(data)
class UDP(socketserver.BaseRequestHandler):
 def handle(self):
  data,s=self.request;SEEN.add(data.decode());s.sendto(data,self.client_address)
class T4(socketserver.ThreadingTCPServer):allow_reuse_address=True;daemon_threads=True
class T6(T4):address_family=socket.AF_INET6
class U4(socketserver.ThreadingUDPServer):daemon_threads=True
class U6(U4):address_family=socket.AF_INET6

def main():
 for cls,host,proto in [(T4,'127.0.0.1','tcp'),(T6,'::1','tcp'),(U4,'127.0.0.1','udp'),(U6,'::1','udp')]:
  server=cls((host,29200+(proto=='udp')),TCP if proto=='tcp' else UDP)
  threading.Thread(target=server.serve_forever,daemon=True).start()
 results=[];processes=[]
 def start():
  left,right=socket.socketpair()
  b=subprocess.Popen([sys.executable,'-u',__file__,'broker',str(right.fileno())],pass_fds=(right.fileno(),),stdout=subprocess.PIPE,text=True)
  right.close();q=queue.Queue()
  def events():
   for line in b.stdout:q.put(json.loads(line))
  threading.Thread(target=events,daemon=True).start()
  c=subprocess.Popen([sys.executable,'-u',__file__,'controller',str(left.fileno())],pass_fds=(left.fileno(),),stdin=subprocess.PIPE,text=True)
  left.close();processes.extend([b,c])
  return b,c,q
 def wait(q,event,timeout=3,reason=None):
  end=time.monotonic()+timeout
  while time.monotonic()<end:
   x=q.get(timeout=max(.01,end-time.monotonic()))
   if x.get('event')==event and (reason is None or x.get('reason')==reason):return x
  raise AssertionError((event,reason))
 def command(c,country='SG',revision='one',sampled=None):
  c.stdin.write(json.dumps(dict(country=country,revision=revision,sampledAt=time.monotonic() if sampled is None else sampled))+'\n');c.stdin.flush()
 def client(family,host,proto):
  s=socket.socket(family,socket.SOCK_STREAM if proto=='tcp' else socket.SOCK_DGRAM);s.settimeout(.25)
  try:s.connect((host,29100+(proto=='udp')))
  except OSError:pass
  return s
 def check(name,allowed,streams=None):
  for family,host in TARGETS:
   for proto in ('tcp','udp'):
    s=streams[(family,proto)] if streams else client(family,host,proto);token=uuid.uuid4().hex
    try:s.sendall(token.encode());ack=s.recv(4096)==token.encode()
    except OSError:ack=False
    if not streams:s.close()
    reached=token in SEEN;assert ack==allowed and reached==allowed,(name,family,proto,ack,reached)
    results.append(dict(case=name,family=4 if family==socket.AF_INET else 6,protocol=proto,reachedSink=reached))
 def open_streams():return {(f,p):client(f,h,p) for f,h in TARGETS for p in ('tcp','udp')}
 def close_streams(streams):
  for s in streams.values():s.close()
 try:
  b,c,q=start();wait(q,'ready');check('start-default-deny',False)
  command(c);wait(q,'permitted');check('fresh-approved-permit',True)
  streams=open_streams();check('existing-flow-before-revoke',True,streams)
  command(c,'JP');wait(q,'revoked',reason='country-or-evidence-invalid')
  check('existing-flow-after-country-revoke',False,streams);close_streams(streams);check('wrong-country-new-denied',False)
  command(c);wait(q,'permitted');check('verified-recovery',True)
  streams=open_streams();check('existing-flow-before-controller-kill',True,streams)
  t=time.monotonic();c.kill();c.wait();wait(q,'revoked',reason='controller-eof');eof_ms=(time.monotonic()-t)*1000
  check('controller-kill-existing-denied',False,streams);close_streams(streams);check('controller-kill-new-denied',False)
  b.kill();b.wait()
  b,c,q=start();wait(q,'ready');check('broker-restart-does-not-reuse-permit',False)
  command(c);wait(q,'permitted');streams=open_streams();check('existing-before-controller-stop',True,streams)
  t=time.monotonic();c.send_signal(signal.SIGSTOP);wait(q,'revoked',reason='permit-expired');expiry_ms=(time.monotonic()-t)*1000
  check('controller-hang-expired-existing-denied',False,streams);close_streams(streams);check('controller-hang-expired-new-denied',False)
  c.send_signal(signal.SIGCONT);check('controller-resume-alone-stays-denied',False)
  command(c,sampled=time.monotonic()-TTL-1);wait(q,'revoked',reason='stale-evidence');check('cached-evidence-cannot-renew',False)
  command(c,sampled=time.monotonic()+10);wait(q,'revoked',reason='stale-evidence');check('future-evidence-cannot-renew',False)
  command(c,revision='two');wait(q,'permitted');check('fresh-evidence-after-resume',True)
  streams=open_streams();check('existing-before-data-plane-stop',True,streams)
  b.send_signal(signal.SIGSTOP);command(c);time.sleep(TTL+.15);b.send_signal(signal.SIGCONT)
  wait(q,'revoked',reason='stale-evidence')
  check('data-plane-resume-existing-denied',False,streams);close_streams(streams);check('data-plane-resume-new-denied',False)
  command(c,revision='three');wait(q,'permitted');check('fresh-evidence-after-data-plane-resume',True)
  streams=open_streams();check('existing-before-broker-kill',True,streams)
  b.kill();b.wait();check('broker-kill-existing-denied',False,streams);close_streams(streams);check('broker-kill-new-denied',False)
  return dict(layer='isolated-in-path-permit-prototype',platform=platform.system(),arch=platform.machine(),count=len(results),allAssertionsPassed=True,cases=results,
   controllerEOFObservedMs=round(eof_ms,2),leaseExpiryObservedMs=round(expiry_ms,2),leaseSeconds=TTL,
   kernelDirectDeny='NOT_TESTED_IN_THIS_SCRIPT: separate prior matrix',physicalTUN='NOT_RUN',NetworkExtension='NOT_RUN',
   actualCountryDetection=False,realClaudeCLI=False,productionReady=False)
 finally:
  for p in processes:
   if p.poll() is None:
    p.kill();p.wait()
guard()
if len(sys.argv)>1:
 (broker if sys.argv[1]=='broker' else controller)(int(sys.argv[2]))
else:
 print(json.dumps(main(),indent=2),flush=True);os._exit(0)
