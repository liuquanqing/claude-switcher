"""Actual utun + fake UDP peer on ephemeral hosted macOS. No real Claude credentials.
No default-route replacement. PF restricts only 198.18.250.2/fdff:cc55::2 UDP29300.
"""
import os,sys,socket,struct,select,threading,subprocess,tempfile,json,time,platform,uuid
from pathlib import Path
assert sys.platform=='darwin' and os.geteuid()==0
assert os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'
assert os.environ.get('CS_REAL_UTUN_LAB')=='ephemeral-only'
IFACE,FD=sys.argv[1],int(sys.argv[2]);assert IFACE.startswith('utun') and IFACE[4:].isdigit()
PEERS=[(socket.AF_INET,'198.18.250.2'),(socket.AF_INET6,'fdff:cc55::2')]
SEEN=set();UP=True;STOP=False;RESULTS=[]
def command(*args,check=True):return subprocess.run(args,text=True,capture_output=True,check=check)
def pf(*args,check=True):return command('/sbin/pfctl',*args,check=check)
def checksum(data):
 if len(data)%2:data+=b'\0'
 total=sum(struct.unpack('!%dH'%(len(data)//2),data))
 while total>>16:total=(total&65535)+(total>>16)
 return (~total)&65535

def echo_peer():
 while not STOP:
  try:
   if not select.select([FD],[],[],.05)[0]:continue
   raw=os.read(FD,65535)
  except OSError:return
  if len(raw)<24:continue
  packet=raw[4:];version=packet[0]>>4
  if version==4:
   ihl=(packet[0]&15)*4
   if packet[9]!=17 or len(packet)<ihl+8:continue
   src,dst=packet[12:16],packet[16:20];udp=packet[ihl:];family=socket.AF_INET
  elif version==6:
   if packet[6]!=17 or len(packet)<48:continue
   src,dst=packet[8:24],packet[24:40];udp=packet[40:];family=socket.AF_INET6
  else:continue
  sport,dport,length,_=struct.unpack('!HHHH',udp[:8]);payload=udp[8:length]
  if dport!=29300:continue
  SEEN.add(payload.decode(errors='replace'))
  if not UP:continue
  reply=struct.pack('!HHHH',dport,sport,len(payload)+8,0)+payload
  if version==6:
   pseudo=dst+src+struct.pack('!I3xB',len(reply),17)
   value=checksum(pseudo+reply) or 65535
   reply=reply[:6]+struct.pack('!H',value)+reply[8:]
   header=struct.pack('!IHBB',6<<28,len(reply),17,64)+dst+src
  else:
   header=struct.pack('!BBHHHBBH',0x45,0,len(reply)+20,0,0,64,17,0)+dst+src
   header=header[:10]+struct.pack('!H',checksum(header))+header[12:]
  try:os.write(FD,struct.pack('!I',family)+header+reply)
  except OSError:return

def probe(name,expected):
 for fam,host in PEERS:
  token=uuid.uuid4().hex;ack=False
  with socket.socket(fam,socket.SOCK_DGRAM) as s:
   s.settimeout(.3)
   try:s.sendto(token.encode(),(host,29300));ack=s.recv(4096)==token.encode()
   except OSError:pass
  RESULTS.append(dict(case=name,family=4 if fam==socket.AF_INET else 6,echo=ack,seenInUtun=token in SEEN))
  assert ack==expected,(name,fam,ack)
original=Path('/etc/pf.conf').read_text();was_enabled='Status: Enabled' in pf('-s','info').stdout
error=None;cleanup=False
thread=threading.Thread(target=echo_peer,daemon=True)
with tempfile.TemporaryDirectory(prefix='cs-real-utun-') as tmp:
 root=Path(tmp);base=root/'pf.conf';base.write_text(original+'\nanchor "cs_utun_lab"\n');rules=root/'rules.conf'
 def apply(allow):
  lines=[]
  for proto,host in [('inet','198.18.250.2'),('inet6','fdff:cc55::2')]:
   if allow:lines.append(f'pass out quick on {IFACE} {proto} proto udp from any to {host} port 29300 keep state (if-bound)')
   lines.append(f'block drop out quick {proto} proto udp from any to {host} port 29300')
   if allow:lines.append(f'pass in quick on {IFACE} {proto} proto udp from {host} port 29300 to any keep state (if-bound)')
   lines.append(f'block drop in quick {proto} proto udp from {host} port 29300 to any')
  rules.write_text('\n'.join(lines)+'\n');pf('-a','cs_utun_lab','-nf',str(rules));pf('-a','cs_utun_lab','-f',str(rules))
 def clear_states():
  for fam,host in PEERS:pf('-k','0.0.0.0/0' if fam==socket.AF_INET else '::/0','-k',host)
 try:
  # First establish persistent reject rules, before creating routes or sending any data.
  pf('-nf',str(base));pf('-f',str(base));apply(False);pf('-e',check=False)
  command('/sbin/ifconfig',IFACE,'inet','198.18.250.1','198.18.250.2','netmask','255.255.255.252','up')
  command('/sbin/ifconfig',IFACE,'inet6','fdff:cc55::1','prefixlen','64','up')
  command('/sbin/route','-n','add','-inet6','fdff:cc55::2','-interface',IFACE)
  thread.start();probe('default-deny-before-approval',False)
  apply(True);clear_states();probe('actual-utun-approved',True)
  UP=False;probe('peer-outage',False);UP=True;probe('peer-recovery',True)
  command('/sbin/ifconfig',IFACE,'down');probe('actual-utun-interface-down',False)
  command('/sbin/ifconfig',IFACE,'up');probe('actual-utun-interface-recovery',True)
  apply(False);clear_states();probe('revoked-while-utun-still-exists',False)
  apply(True);clear_states();probe('revalidated-utun-recovery',True)
  # Keep established UDP sockets; destroying the utun must not reuse floating PF states.
  streams=[]
  for fam,host in PEERS:
   sock=socket.socket(fam,socket.SOCK_DGRAM);sock.settimeout(.3);sock.connect((host,29300))
   token=uuid.uuid4().hex;sock.send(token.encode());assert sock.recv(4096)==token.encode();streams.append((fam,sock))
  STOP=True;os.close(FD);FD=None;thread.join(timeout=1)
  for fam,sock in streams:
   token=uuid.uuid4().hex;ack=False
   try:sock.send(token.encode());ack=sock.recv(4096)==token.encode()
   except OSError:pass
   finally:sock.close()
   RESULTS.append(dict(case='utun-owner-exited-existing-socket',family=4 if fam==socket.AF_INET else 6,echo=ack,seenInUtun=token in SEEN))
   assert not ack and token not in SEEN
  probe('utun-owner-exited-new-socket',False)
  pf_counters=pf('-a','cs_utun_lab','-vvsr').stdout
 except BaseException as e:
  error=repr(e)
  if isinstance(e,subprocess.CalledProcessError):error+=' stderr='+e.stderr
 finally:
  STOP=True
  command('/sbin/route','-n','delete','-host','198.18.250.2',check=False)
  command('/sbin/route','-n','delete','-inet6','fdff:cc55::2',check=False)
  if FD is not None:os.close(FD)
  a=pf('-a','cs_utun_lab','-F','rules',check=False);b=pf('-f','/etc/pf.conf',check=False)
  c=pf('-d',check=False) if not was_enabled else None
  cleanup=a.returncode==0 and b.returncode==0 and (c is None or c.returncode==0)
result=dict(layer='real-macos-utun-UDP-fixture',os=platform.mac_ver()[0],interface=IFACE,count=len(RESULTS),cases=RESULTS,error=error,cleanup=cleanup,allAssertionsPassed=error is None and cleanup,realClaudeCLI=False,actualNetworkExtension=False,defaultRouteChanged=False,physicalEgressCapture='NOT_RUN',pfCounters=locals().get('pf_counters'),productionReady=False)
print(json.dumps(result,indent=2),flush=True);os._exit(0 if result['allAssertionsPassed'] else 1)
