"""Compose the in-path fixture with real dual-stack UID direct-deny, on an ephemeral hosted Mac only.
Extracts the frozen fixture functions and replaces the client factory with a UID client. No host mounts.
"""
import hashlib,json,os,subprocess,sys,tempfile,uuid
from pathlib import Path
assert sys.platform=='darwin'
assert os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'
assert os.environ.get('CS_DISPOSABLE_NETWORK_LAB')=='github-hosted-loopback-only'
assert os.environ.get('GITHUB_REPOSITORY')=='liuquanqing/claude-switcher'
TEMP=tempfile.TemporaryDirectory(prefix='cs-gate-pf-')
def pf(*args,check=True):return subprocess.run(['sudo','-n','/sbin/pfctl',*args],text=True,capture_output=True,check=check)
ORIGINAL=Path('/etc/pf.conf').read_text()
WAS_ENABLED='Status: Enabled' in pf('-s','info').stdout
CLEANUP=False
p=Path(__file__).with_name('gate_lease_lab.py');source=p.read_text();assert source.count('\nguard()\n')==1
ns={'__file__':str(p),'__name__':'isolated_composition'}
prefix=source.rsplit('\nguard()\n',1)[0]
start=prefix.index(' def client(');end=prefix.index(' def check(',start)
prefix=prefix[:start]+' def client(family,host,proto):\n  return ProtectedClient(family,host,proto)\n'+prefix[end:]
# Healthy setup obtains fresh synthetic evidence after sudo identity preparation.
old=" def open_streams():return {(f,p):client(f,h,p) for f,h in TARGETS for p in ('tcp','udp')}"
new=" def open_streams():\n  command(c);wait(q,'permitted')\n  return {(f,p):client(f,h,p) for f,h in TARGETS for p in ('tcp','udp')}"
assert old in prefix
prefix=prefix.replace(old,new)
exec(compile(prefix,str(p),'exec'),ns)
CLIENT=r'''
import socket,sys
s=socket.socket(int(sys.argv[1]),int(sys.argv[2]));s.settimeout(.25)
try:
 s.connect((sys.argv[3],int(sys.argv[4])));print('READY',flush=True)
 for line in sys.stdin:
  data=line.strip().encode();s.sendall(data);print('OK' if s.recv(4096)==data else 'BLOCKED',flush=True)
except OSError:print('BLOCKED',flush=True)
'''
DIRECT=[];installed=False
class RawClient:
 def __init__(self,family,host,proto,port):
  self.p=subprocess.Popen(['sudo','-n','-u','nobody',sys.executable,'-u','-c',CLIENT,str(family),str(ns['socket'].SOCK_STREAM if proto=='tcp' else ns['socket'].SOCK_DGRAM),host,str(port)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
  self.ready=self.p.stdout.readline().strip()=='READY';self.last=None
 def sendall(self,data):
  if not self.ready:raise OSError('not connected')
  self.last=data;self.p.stdin.write(data.decode()+'\n');self.p.stdin.flush()
 def recv(self,size):
  if self.p.stdout.readline().strip()!='OK':raise OSError('no echo')
  return self.last
 def close(self):
  self.p.stdin.close()
  self.p.wait(timeout=1)
def direct(family,host,proto,expected):
 s=RawClient(family,host,proto,29200+(proto=='udp'));token=uuid.uuid4().hex
 try:s.sendall(token.encode());ack=s.recv(4096)==token.encode()
 except OSError:ack=False
 finally:s.close()
 reached=token in ns['SEEN'];assert ack==expected and reached==expected,(family,proto,ack,reached)
 DIRECT.append(dict(family=4 if family==ns['socket'].AF_INET else 6,protocol=proto,reachedSink=reached,expected=expected))
def install():
 global installed
 if installed:return
 for family,host in ns['TARGETS']:
  for proto in ('tcp','udp'):direct(family,host,proto,True)
 base=Path(TEMP.name)/'pf.conf';base.write_text(ORIGINAL+'\nanchor "cs_gate_compound"\n')
 rules=Path(TEMP.name)/'rules.conf'
 rules.write_text('\n'.join('block drop out quick on lo0 '+fam+' proto { tcp udp } from any to '+host+' port { 29200 29201 } user nobody' for fam,host in [('inet','127.0.0.1'),('inet6','::1')])+'\n')
 pf('-nf',str(base));pf('-a','cs_gate_compound','-nf',str(rules))
 pf('-f',str(base));pf('-a','cs_gate_compound','-f',str(rules));pf('-e',check=False)
 for host in ('127.0.0.1','::1'):pf('-k',host,'-k',host)
 installed=True
class ProtectedClient(RawClient):
 def __init__(self,family,host,proto):
  install();self.family,self.host,self.proto=family,host,proto
  super().__init__(family,host,proto,29100+(proto=='udp'))
 def close(self):
  super().close();direct(self.family,self.host,self.proto,False)
ns['ProtectedClient']=ProtectedClient
try:
 result=ns['main']();assert len(DIRECT)>4 and sum(x['expected'] for x in DIRECT)==4
finally:
 a=pf('-a','cs_gate_compound','-F','rules',check=False);b=pf('-f','/etc/pf.conf',check=False)
 c=pf('-d',check=False) if not WAS_ENABLED else None
 CLEANUP=a.returncode==0 and b.returncode==0 and (c is None or c.returncode==0)
 TEMP.cleanup()
assert CLEANUP
result.update(layer='macOS-composed-data-gate-and-kernel-direct-deny',kernelDirectDeny='PF rules scoped to fixture origin ports and nobody UID only',directProbeCount=len(DIRECT),directProbes=DIRECT,fixtureSourceSHA256=hashlib.sha256(p.read_bytes()).hexdigest(),cleanup=CLEANUP,productionReady=False)
print(json.dumps(result,indent=2),flush=True);os._exit(0)
