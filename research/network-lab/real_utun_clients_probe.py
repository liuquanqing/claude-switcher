"""Official blank clients and synthetic TCP/UDP peer over actual disposable utun.
No default-route replacement or real credentials. UID isolation is a lab fixture,
not production app classification. Never run on a personal Mac.
"""
import os,sys,socket,struct,select,threading,subprocess,tempfile,json,time,platform,uuid,signal
from pathlib import Path
assert sys.platform=='darwin' and os.geteuid()==0
assert os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'
assert os.environ.get('CS_REAL_UTUN_LAB')=='ephemeral-only'
IFACE,FD=sys.argv[1],int(sys.argv[2]);assert IFACE.startswith('utun') and IFACE[4:].isdigit()
PEERS=[(socket.AF_INET,'198.18.250.2'),(socket.AF_INET6,'fdff:cc55::2')]
SEEN=set();UP=True;STOP=False;RESULTS=[];TCP_FLOWS={};HTTP_SEEN=[];TCP_SEEN=set();SYN_SEEN=[]
def command(*args,check=True):return subprocess.run(args,text=True,capture_output=True,check=check)
def pf(*args,check=True):return command('/sbin/pfctl',*args,check=check)
def checksum(data):
 if len(data)%2:data+=b'\0'
 total=sum(struct.unpack('!%dH'%(len(data)//2),data))
 while total>>16:total=(total&65535)+(total>>16)
 return (~total)&65535

def packet_out(version,src,dst,protocol,body):
 if version==6:header=struct.pack('!IHBB',6<<28,len(body),protocol,64)+src+dst
 else:
  header=struct.pack('!BBHHHBBH',0x45,0,len(body)+20,0,0,64,protocol,0)+src+dst
  header=header[:10]+struct.pack('!H',checksum(header))+header[12:]
 os.write(FD,struct.pack('!I',socket.AF_INET if version==4 else socket.AF_INET6)+header+body)
def tcp_reply(version,src,dst,sport,dport,seq,ack,flags,body=b''):
 segment=struct.pack('!HHIIBBHHH',sport,dport,seq&0xffffffff,ack&0xffffffff,5<<4,flags,65535,0,0)+body
 pseudo=src+dst+(struct.pack('!I3xB',len(segment),6) if version==6 else struct.pack('!BBH',0,6,len(segment)))
 segment=segment[:16]+struct.pack('!H',checksum(pseudo+segment))+segment[18:]
 packet_out(version,src,dst,6,segment)
def echo_peer():
 while not STOP:
  try:
   if not select.select([FD],[],[],.05)[0]:continue
   raw=os.read(FD,65535)
  except OSError:return
  if len(raw)<24:continue
  packet=raw[4:];version=packet[0]>>4
  if version==4:
   offset=(packet[0]&15)*4;protocol=packet[9];src,dst=packet[12:16],packet[16:20]
  elif version==6:offset=40;protocol=packet[6];src,dst=packet[8:24],packet[24:40]
  else:continue
  data=packet[offset:]
  if protocol==6 and len(data)>=20:
   sport,dport,seq,ack,off,flags,window,chk,urg=struct.unpack('!HHIIBBHHH',data[:20])
   if dport not in (29300,29301,29302):continue
   if flags&2:SYN_SEEN.append((version,dport))
   if not UP:continue
   key=(version,src,sport,dport)
   if flags&2:
    TCP_FLOWS[key]={'next':(seq+1)&0xffffffff,'serverNext':1001,'buffer':b'','sent':False}
    tcp_reply(version,dst,src,dport,sport,1000,seq+1,0x12);continue
   state=TCP_FLOWS.get(key)
   if not state:continue
   payload=data[(off>>4)*4:]
   if flags&4:TCP_FLOWS.pop(key,None);continue
   if payload:
    accepted=seq==state['next']
    if seq==state['next']:
     state['buffer']+=payload;state['next']=(seq+len(payload))&0xffffffff
    if dport==29302:
     if accepted:
      TCP_SEEN.add(payload.decode(errors='replace'))
      tcp_reply(version,dst,src,dport,sport,state['serverNext'],state['next'],0x18,payload)
      state['serverNext']=(state['serverNext']+len(payload))&0xffffffff
     else:tcp_reply(version,dst,src,dport,sport,state['serverNext'],state['next'],0x10)
     continue
    tcp_reply(version,dst,src,dport,sport,state['serverNext'],state['next'],0x10)
    if not state['sent'] and b'\r\n\r\n' in state['buffer']:
     headers,body=state['buffer'].split(b'\r\n\r\n',1);length=0
     for line in headers.split(b'\r\n')[1:]:
      if line.lower().startswith(b'content-length:'):length=int(line.split(b':',1)[1].strip())
     if len(body)<length:continue
     first=headers.split(b'\r\n',1)[0].decode(errors='replace');HTTP_SEEN.append({'family':version,'port':dport,'request':first.split('?',1)[0]})
     if first.startswith('GET /fixture'):
      reply=b'HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\nfixture'
     else:
      error=b'{"type":"error","error":{"type":"authentication_error","message":"isolated fixture invalid key"}}'
      reply=(b'HTTP/1.1 502 Fixture Proxy\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' if dport==29301 else b'HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: '+str(len(error)).encode()+b'\r\nConnection: close\r\n\r\n'+error)
     tcp_reply(version,dst,src,dport,sport,1001,state['next'],0x19,reply);state['sent']=True
   continue
  if protocol!=17 or len(data)<8:continue
  if not UP:continue
  sport,dport,length,_=struct.unpack('!HHHH',data[:8]);payload=data[8:length]
  if dport!=29300:continue
  SEEN.add(payload.decode(errors='replace'))
  reply=struct.pack('!HHHH',dport,sport,len(payload)+8,0)+payload
  if version==6:
   pseudo=dst+src+struct.pack('!I3xB',len(reply),17);value=checksum(pseudo+reply) or 65535
   reply=reply[:6]+struct.pack('!H',value)+reply[8:]
  try:packet_out(version,dst,src,17,reply)
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
error=None;cleanup=False;capture=None;physical_capture=None;held=[]
thread=threading.Thread(target=echo_peer,daemon=True)
with tempfile.TemporaryDirectory(prefix='cs-real-utun-',dir=os.environ['RUNNER_TEMP']) as tmp:
 root=Path(tmp);base=root/'pf.conf';base.write_text(original+'\nanchor "cs_utun_lab"\n');rules=root/'rules.conf'
 def apply(allow):
  lines=[]
  for proto,host in [('inet','198.18.250.2'),('inet6','fdff:cc55::2')]:
   if allow:lines.append(f'pass out quick on {IFACE} {proto} proto {{ tcp udp }} from any to {host} port {{ 29300 29301 29302 }} keep state (if-bound)')
   lines.append(f'block drop out quick {proto} proto {{ tcp udp }} from any to {host} port {{ 29300 29301 29302 }}')
  uid=os.environ.get('CS_TEST_UID')
  if uid:
   assert uid.isdigit()
   lines += ['pass out quick on lo0 all',f'block drop out quick inet proto {{ tcp udp }} all user {uid}',f'block drop out quick inet6 proto {{ tcp udp }} all user {uid}']
  rules.write_text('\n'.join(lines)+'\n');pf('-a','cs_utun_lab','-nf',str(rules));pf('-a','cs_utun_lab','-f',str(rules))
 def clear_states():
  for fam,host in PEERS:pf('-k','0.0.0.0/0' if fam==socket.AF_INET else '::/0','-k',host)
 try:
  # First establish persistent reject rules, before creating routes or sending any data.
  pf('-nf',str(base));pf('-f',str(base));apply(False);pf('-e',check=False)
  command('/sbin/ifconfig',IFACE,'inet','198.18.250.1','198.18.250.2','netmask','255.255.255.252','up')
  command('/sbin/ifconfig',IFACE,'inet6','fdff:cc55::1','prefixlen','64','up')
  command('/sbin/route','-n','add','-inet6','fdff:cc55::2','-interface',IFACE)
  # Observe only synthetic fixture destinations on the runner's physical interface.
  route=command('/sbin/route','-n','get','default').stdout
  physical=next(line.split(':',1)[1].strip() for line in route.splitlines() if line.strip().startswith('interface:'))
  assert physical.startswith('en'),physical
  capture_log=(root/'capture.log').open('w')
  capture=subprocess.Popen(['/usr/sbin/tcpdump','-n','-U','-i',physical,'-w',str(root/'physical.pcap'),'(dst host 198.18.250.2 or dst host fdff:cc55::2) and (tcp or udp) and dst portrange 29300-29302'],stdout=subprocess.DEVNULL,stderr=capture_log)
  time.sleep(.5);assert capture.poll() is None,'physical capture failed to start'
  thread.start();probe('default-deny-before-approval',False)
  apply(True);clear_states();probe('actual-utun-approved',True)
  UP=False;probe('peer-outage',False);UP=True;probe('peer-recovery',True)
  command('/sbin/ifconfig',IFACE,'down');probe('actual-utun-interface-down',False)
  command('/sbin/ifconfig',IFACE,'up');probe('actual-utun-interface-recovery',True)
  apply(False);clear_states();probe('revoked-while-utun-still-exists',False)
  apply(True);clear_states();probe('revalidated-utun-recovery',True)
  def tcp_exchange(name,expected):
   for fam,sock in held:
    token=uuid.uuid4().hex;ack=False
    try:sock.sendall(token.encode());ack=sock.recv(4096)==token.encode()
    except OSError:pass
    seen=token in TCP_SEEN
    RESULTS.append(dict(case=name,family=4 if fam==socket.AF_INET else 6,echo=ack,seenInUtun=seen))
    assert ack==expected and seen==expected,(name,fam,ack,seen)
  for fam,host in PEERS:
   sock=socket.socket(fam,socket.SOCK_STREAM);sock.settimeout(.5);sock.connect((host,29302));held.append((fam,sock))
  tcp_exchange('established-TCP-positive-control',True)
  apply(False)
  # Explicit vulnerability control: replacing PF rules alone leaves old states alive.
  tcp_exchange('negative-control-old-PF-state-survives-rule-replacement',True)
  clear_states();tcp_exchange('established-TCP-revoked-with-state-removal',False)
  for _,sock in held:sock.close()
  held=[];apply(True);clear_states()
  # Real kernel TCP handshake and HTTP over both actual utun routes.
  for fam,host in PEERS:
   with socket.socket(fam,socket.SOCK_STREAM) as sock:
    sock.settimeout(2);sock.connect((host,29300));sock.sendall(b'GET /fixture HTTP/1.1\r\nHost: fixture.invalid\r\nConnection: close\r\n\r\n')
    data=sock.recv(4096);assert b'200 OK' in data and b'fixture' in data
   RESULTS.append(dict(case='actual-utun-TCP-HTTP',family=4 if fam==socket.AF_INET else 6,echo=True))
  artifacts=json.loads(Path(os.environ['CS_CLIENT_ARTIFACT_JSON']).read_text());uid=int(os.environ['CS_TEST_UID'])
  clean={'PATH':'/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin','LANG':'en_US.UTF-8'}
  config=root/'cli';config.mkdir();os.chown(config,uid,-1)
  work=root/'work';work.mkdir();os.chown(work,uid,-1);root.chmod(0o755)
  def run_client(kind,phase,fam,expected):
   host='198.18.250.2' if fam==4 else '[fdff:cc55::2]'
   profile=root/('desktop-'+uuid.uuid4().hex);profile.mkdir();os.chown(profile,uid,-1)
   port=29300 if kind=='cli' else 29301;before=sum(x['port']==port for x in HTTP_SEEN)
   before_syn=sum(x==(fam,port) for x in SYN_SEEN)
   envArgs=['CLAUDE_CONFIG_DIR='+str(config),'ANTHROPIC_API_KEY=fixture-invalid-key','ANTHROPIC_BASE_URL=http://'+host+':29300','API_TIMEOUT_MS=1000','DISABLE_TELEMETRY=1','DISABLE_ERROR_REPORTING=1','CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1']
   if kind=='cli':
    args=['sudo','-n','-u','#'+str(uid),'-H','/usr/bin/env',*envArgs,artifacts['cli'],'--bare','-p','Return fixture only.','--max-turns','1','--tools','','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--disable-slash-commands']
   else:args=['/bin/launchctl','asuser',str(uid),'sudo','-n','-u','#'+str(uid),'-H',artifacts['desktop'],'--user-data-dir='+str(profile),'--proxy-server=http://'+host+':29301','--no-first-run']
   proc=subprocess.Popen(args,cwd=work,env=clean,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
   start=time.monotonic();deadline=start+(15 if expected else 7)
   while time.monotonic()<deadline:
    count=sum(x['port']==port for x in HTTP_SEEN)-before
    if expected and count>0:break
    if proc.poll() is not None:break
    time.sleep(.1)
   try:os.killpg(proc.pid,signal.SIGTERM)
   except ProcessLookupError:pass
   try:proc.wait(timeout=2)
   except subprocess.TimeoutExpired:os.killpg(proc.pid,signal.SIGKILL);proc.wait()
   count=sum(x['port']==port for x in HTTP_SEEN)-before
   syn=sum(x==(fam,port) for x in SYN_SEEN)-before_syn
   RESULTS.append(dict(case=kind+'-actual-utun-'+phase,family=fam,requestsInUtun=count,synInUtun=syn,observationSeconds=round(time.monotonic()-start,3)))
   assert (count>0 if expected else count==0),(kind,phase,fam,count)
  def client_matrix(phase,expected):
   for fam in (4,6):
    for kind in ('cli','desktop'):run_client(kind,phase,fam,expected)
  client_matrix('approved',True)
  apply(False);clear_states();client_matrix('revoked',False)
  apply(True);clear_states();client_matrix('revalidated-recovery',True)
  command('/sbin/ifconfig',IFACE,'down');client_matrix('interface-down',False)
  command('/sbin/ifconfig',IFACE,'up');clear_states();client_matrix('interface-recovery',True)
  UP=False;client_matrix('peer-outage',False)
  UP=True;clear_states();client_matrix('peer-recovery',True)
  apply(True);clear_states();probe('post-client-revalidated-recovery',True)
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
  capture.send_signal(signal.SIGINT);capture.wait(timeout=5);capture_log.close()
  assert capture.returncode==0,(capture.returncode,(root/'capture.log').read_text())
  decoded=command('/usr/sbin/tcpdump','-n','-r',str(root/'physical.pcap')).stdout.splitlines()
  physical_capture=dict(interface=physical,syntheticDestinationPackets=len(decoded),captureStarted=True,captureExit=0)
  assert not decoded,physical_capture
  pf_counters=pf('-a','cs_utun_lab','-vvsr').stdout
 except BaseException as e:
  error=repr(e)
  if isinstance(e,subprocess.CalledProcessError):error+=' stderr='+e.stderr
 finally:
  STOP=True
  for _,sock in held:sock.close()
  if capture is not None and capture.poll() is None:
   capture.send_signal(signal.SIGINT);capture.wait(timeout=5)
  command('/sbin/route','-n','delete','-host','198.18.250.2',check=False)
  command('/sbin/route','-n','delete','-inet6','fdff:cc55::2',check=False)
  if FD is not None:os.close(FD)
  a=pf('-a','cs_utun_lab','-F','rules',check=False);b=pf('-f','/etc/pf.conf',check=False)
  c=pf('-d',check=False) if not was_enabled else None
  cleanup=a.returncode==0 and b.returncode==0 and (c is None or c.returncode==0)
result=dict(layer='real-macos-utun-TCP-and-official-client-fixture',os=platform.mac_ver()[0],interface=IFACE,count=len(RESULTS),cases=RESULTS,error=error,cleanup=cleanup,allAssertionsPassed=error is None and cleanup,realClaudeCLI=True,actualNetworkExtension=False,defaultRouteChanged=False,physicalEgressCapture=physical_capture,pfCounters=locals().get('pf_counters'),productionReady=False)
print(json.dumps(result,indent=2),flush=True);os._exit(0 if result['allAssertionsPassed'] else 1)
