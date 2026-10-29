"""Research only, NEVER run on a personal Mac. Disposable hosted runner loopback PF test.
No production app, login, proxy, real domain or physical network interface is used.
"""
import json,os,platform,socket,socketserver,subprocess,sys,tempfile,threading,time,uuid
from pathlib import Path
assert sys.platform=='darwin'
assert os.environ.get('GITHUB_ACTIONS')=='true'
assert os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'
assert os.environ.get('CS_DISPOSABLE_NETWORK_LAB')=='github-hosted-loopback-only'
assert os.environ.get('GITHUB_REPOSITORY')=='liuquanqing/claude-switcher'
SEEN=set();RESULTS=[]
class TCP(socketserver.StreamRequestHandler):
 def handle(self):
  while data:=self.rfile.readline():
   SEEN.add(data.strip().decode())
   try:self.wfile.write(data);self.wfile.flush()
   except OSError:return
class UDP(socketserver.BaseRequestHandler):
 def handle(self):
  data,sock=self.request;SEEN.add(data.strip().decode());sock.sendto(data,self.client_address)
class T4(socketserver.ThreadingTCPServer):allow_reuse_address=True;daemon_threads=True
class T6(T4):address_family=socket.AF_INET6
class U4(socketserver.ThreadingUDPServer):daemon_threads=True
class U6(U4):address_family=socket.AF_INET6
TARGETS=[(4,'127.0.0.2'),(6,'::1')]
def pf(*args,check=True):
 return subprocess.run(['sudo','-n','/sbin/pfctl',*args],text=True,capture_output=True,check=check)
def send(fam,host,proto,sock=None):
 token=uuid.uuid4().hex;own=sock is None
 if own:sock=socket.socket(socket.AF_INET if fam==4 else socket.AF_INET6,socket.SOCK_STREAM if proto=='tcp' else socket.SOCK_DGRAM)
 sock.settimeout(.4)
 try:
  if own:sock.connect((host,28100+(proto=='udp')))
  sock.sendall((token+'\n').encode());ack=sock.recv(4096)==(token+'\n').encode()
 except OSError:ack=False
 finally:
  if own:sock.close()
 return ack,token in SEEN

def check(name,allowed):
 for fam,host in TARGETS:
  for proto in ('tcp','udp'):
   ack,reached=send(fam,host,proto)
   RESULTS.append(dict(case=name,family=fam,protocol=proto,ack=ack,reachedSink=reached))
   assert ack==allowed and reached==allowed,(name,fam,proto,ack,reached)

for cls,host,proto in [(T4,'127.0.0.2','tcp'),(T6,'::1','tcp'),(U4,'127.0.0.2','udp'),(U6,'::1','udp')]:
 server=cls((host,28100+(proto=='udp')),TCP if proto=='tcp' else UDP)
 threading.Thread(target=server.serve_forever,daemon=True).start()
check('before-filter-positive-control',True)
original=Path('/etc/pf.conf').read_text()
was_enabled='Status: Enabled' in pf('-s','info').stdout
error=None;cleanup=False
with tempfile.TemporaryDirectory(prefix='cs-macos-pf-') as tmp:
 root=Path(tmp);base=root/'base.conf';base.write_text(original+'\nanchor "cs_validation"\n')
 rules=root/'rules.conf'
 def apply(allow):
  action='pass' if allow else 'block drop'
  rules.write_text('\n'.join(f'{action} out quick on lo0 inet{6 if fam==6 else ""} proto {{ tcp udp }} from any to {host} port {{ 28100 28101 }}'+(' keep state' if allow else '') for fam,host in TARGETS)+'\n')
  pf('-a','cs_validation','-f',str(rules))
 def clear_fixture_states():
  for _,host in TARGETS:pf('-k',host,'-k',host)
 try:
  pf('-nf',str(base));pf('-f',str(base));pf('-e',check=False)
  apply(True);check('approved-before-revocation',True)
  streams=[]
  for fam,host in TARGETS:
   for proto in ('tcp','udp'):
    sock=socket.socket(socket.AF_INET if fam==4 else socket.AF_INET6,socket.SOCK_STREAM if proto=='tcp' else socket.SOCK_DGRAM)
    sock.settimeout(.4);sock.connect((host,28100+(proto=='udp')))
    assert send(fam,host,proto,sock)==(True,True);streams.append((fam,host,proto,sock))
  apply(False)
  for fam,host,proto,sock in streams:
   ack,reached=send(fam,host,proto,sock)
   RESULTS.append(dict(case='observation-existing-flow-before-state-clear',family=fam,protocol=proto,ack=ack,reachedSink=reached))
  clear_fixture_states()
  for fam,host,proto,sock in streams:
   ack,reached=send(fam,host,proto,sock);sock.close()
   RESULTS.append(dict(case='existing-flow-after-state-clear',family=fam,protocol=proto,ack=ack,reachedSink=reached))
   assert not reached and not ack
  check('new-flow-denied',False)
  # pfctl loaders have exited; deny persists in kernel without a live loader process.
  check('loader-exited-deny-persists',False)
  before=pf('-a','cs_validation','-sr').stdout
  rules.write_text('not a valid pf rule\n');bad=pf('-a','cs_validation','-f',str(rules),check=False)
  assert bad.returncode!=0 and pf('-a','cs_validation','-sr').stdout==before
  check('failed-update-retains-deny',False)
  apply(True);clear_fixture_states();check('revalidation-recovery',True)
 except BaseException as e:error=repr(e)
 finally:
  a=pf('-a','cs_validation','-F','rules',check=False);b=pf('-f','/etc/pf.conf',check=False)
  c=pf('-d',check=False) if not was_enabled else None
  cleanup=a.returncode==0 and b.returncode==0 and (c is None or c.returncode==0)
result=dict(layer='macOS-PF-loopback-only',os=platform.mac_ver()[0],arch=platform.machine(),count=len(RESULTS),cases=RESULTS,
 allAssertionsPassed=error is None and cleanup,error=error,cleanup=cleanup,realClaudeOrCLI=False,physicalTUN='NOT_RUN',
 actualNetworkExtension='NOT_RUN',countryDetection='NOT_RUN',executorCrashWhilePermitted='NOT_RUN',productionReady=False)
print(json.dumps(result,indent=2),flush=True)
os._exit(0 if result['allAssertionsPassed'] else 1)
