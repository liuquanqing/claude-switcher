"""Official client network smoke test on disposable hosted macOS only.
Blank profiles, synthetic invalid API key, local fixture services. No live user sessions.
PF temporarily isolates the runner UID; root orchestrator always restores the baseline.
"""
import os,sys,json,hashlib,urllib.request,subprocess,tempfile,threading,time,socketserver,signal,plistlib
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path
assert sys.platform=='darwin' and os.geteuid()==0
assert os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'
assert os.environ.get('CS_OFFICIAL_CLIENT_LAB')=='ephemeral-only'
UID=int(os.environ['CS_TEST_UID']);assert UID>0
API=[];PROXY=[]
class APIHandler(BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def do_POST(self):
  self.rfile.read(int(self.headers.get('Content-Length','0')));API.append(self.path)
  b=json.dumps({'type':'error','error':{'type':'authentication_error','message':'isolated fixture invalid key'}}).encode()
  self.send_response(401);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(b)));self.end_headers();self.wfile.write(b)
 def do_GET(self):self.do_POST()
class ProxyHandler(BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def handle_proxy(self):
  PROXY.append(self.path);self.send_response(502);self.send_header('Content-Length','0');self.end_headers()
 do_CONNECT=handle_proxy;do_GET=handle_proxy;do_POST=handle_proxy
for port,handler in [(29400,APIHandler),(29401,ProxyHandler)]:
 server=ThreadingHTTPServer(('127.0.0.1',port),handler);threading.Thread(target=server.serve_forever,daemon=True).start()
def command(*a,check=True):return subprocess.run(a,text=True,capture_output=True,check=check)
def pf(*a,check=True):return command('/sbin/pfctl',*a,check=check)
def download(url,path):
 with urllib.request.urlopen(url,timeout=90) as response,path.open('wb') as out:
  while chunk:=response.read(1024*1024):out.write(chunk)
 return hashlib.sha256(path.read_bytes()).hexdigest()
results={};original=Path('/etc/pf.conf').read_text();was_enabled='Status: Enabled' in pf('-s','info').stdout;cleanup=False;error=None
with tempfile.TemporaryDirectory(prefix='cs-official-client-',dir=os.environ['RUNNER_TEMP']) as tmp:
 root=Path(tmp);root.chmod(0o755)
 baseURL='https://downloads.claude.ai/claude-code-releases'
 version=urllib.request.urlopen(baseURL+'/latest',timeout=30).read().decode().strip()
 assert all(c.isdigit() or c in '.-' or c.isalpha() for c in version) and version[0].isdigit()
 manifest=json.loads(urllib.request.urlopen(baseURL+'/'+version+'/manifest.json',timeout=30).read())
 cli=root/'claude';digest=download(baseURL+'/'+version+'/darwin-x64/claude',cli);assert digest==manifest['platforms']['darwin-x64']['checksum'];cli.chmod(0o755)
 command('/usr/bin/codesign','--verify','--strict',str(cli))
 results['cliArtifact']={'version':version,'SHA256':digest,'officialManifestMatched':True}
 desktop=None
 desktopURL='https://downloads.claude.ai/releases/darwin/universal/1.0.2768/Claude-21341c944a9d74880b52a77c4f1522f47f52d0da.pkg'
 try:
  pkg=root/'Claude.pkg';pkgsha=download(desktopURL,pkg)
  command('/usr/sbin/pkgutil','--check-signature',str(pkg))
  expanded=root/'expanded';command('/usr/sbin/pkgutil','--expand-full',str(pkg),str(expanded))
  apps=list(expanded.rglob('Claude.app'));assert len(apps)==1
  app=root/'Claude.app';command('/usr/bin/ditto',str(apps[0]),str(app));command('/usr/bin/codesign','--verify','--deep','--strict',str(app))
  info=plistlib.loads((app/'Contents/Info.plist').read_bytes());desktop=app/'Contents/MacOS'/info['CFBundleExecutable']
  results['desktopArtifact']={'version':info.get('CFBundleShortVersionString'),'SHA256Package':pkgsha,'signatureVerified':True,'installedSystemPackage':False,'sourceURL':desktopURL,'latestVersionClaim':False}
 except Exception as e:
  results['desktopArtifact']={'state':'NOT_RUN','reason':repr(e),'sourceURL':desktopURL}
 config=root/'cli-config';config.mkdir();os.chown(config,UID,-1)
 work=root/'empty-project';work.mkdir();os.chown(work,UID,-1)
 profile=root/'desktop-profile';profile.mkdir();os.chown(profile,UID,-1)
 # Do not forward CI secrets into official clients. sudo supplies the disposable user's login home.
 clean={'PATH':'/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin','LANG':'en_US.UTF-8'}
 envArgs=['CLAUDE_CONFIG_DIR='+str(config),'ANTHROPIC_API_KEY=fixture-not-a-real-key','ANTHROPIC_BASE_URL=http://127.0.0.1:29400','API_TIMEOUT_MS=1500','DISABLE_TELEMETRY=1','DISABLE_ERROR_REPORTING=1','CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1']
 cliCmd=['sudo','-n','-u','#'+str(UID),'-H','/usr/bin/env',*envArgs,str(cli),'--bare','-p','Return fixture only.','--max-turns','1','--tools','','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--disable-slash-commands']
 def run_cli():
  p=subprocess.Popen(cliCmd,cwd=work,env=clean,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
  try:
   stdout,stderr=p.communicate(timeout=10)
   return {'exitCode':p.returncode,'timedOut':False,'fixtureAuthenticationError':'fixture invalid key' in stdout+stderr}
  except subprocess.TimeoutExpired:
   os.killpg(p.pid,signal.SIGKILL);p.communicate()
   return {'exitCode':p.returncode,'timedOut':True}
 def run_desktop(seconds=8):
  if desktop is None:return {'state':'NOT_RUN','reason':'official artifact unavailable'}
  # Only this freshly extracted app and process group are launched/stopped.
  args=['/bin/launchctl','asuser',str(UID),'sudo','-n','-u','#'+str(UID),'-H',str(desktop),'--user-data-dir='+str(profile),'--proxy-server=http://127.0.0.1:29401','--no-first-run']
  log=root/('desktop-'+str(time.monotonic())+'.log')
  with log.open('w') as out:
   p=subprocess.Popen(args,cwd=work,env=clean,stdout=out,stderr=out,start_new_session=True)
   time.sleep(seconds);alive=p.poll() is None
   if alive:
    try:os.killpg(p.pid,signal.SIGTERM);p.wait(timeout=3)
    except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
  return {'aliveAtObservation':alive,'exitCode':p.returncode,'logTail':log.read_text(errors='replace')[-1600:]}
 base=root/'pf.conf';base.write_text(original+'\nanchor "cs_official_lab"\n');rules=root/'rules.conf'
 def apply(blockFixtures):
  lines=[]
  if blockFixtures:
   for fam,host in [('inet','127.0.0.1'),('inet6','::1')]:lines.append(f'block drop out quick on lo0 {fam} proto tcp from any to {host} port {{ 29400 29401 }} user {UID}')
  lines += [f'pass out quick on lo0 all',f'block drop out quick inet proto {{ tcp udp }} all user {UID}',f'block drop out quick inet6 proto {{ tcp udp }} all user {UID}']
  rules.write_text('\n'.join(lines)+'\n');pf('-a','cs_official_lab','-nf',str(rules));pf('-a','cs_official_lab','-f',str(rules))
 try:
  pf('-nf',str(base));pf('-f',str(base));apply(False);pf('-e',check=False)
  first=run_cli();results['cliPositive']={**first,'requestsToLocalFixture':len(API)}
  start=len(PROXY);d=run_desktop();results['desktopPositive']={**d,'proxyRequests':len(PROXY)-start}
  apply(True)
  for host in ('127.0.0.1','::1'):pf('-k',host,'-k',host)
  start=len(API);second=run_cli();results['cliBlocked']={**second,'requestsToLocalFixture':len(API)-start}
  start=len(PROXY);d=run_desktop();results['desktopBlocked']={**d,'proxyRequests':len(PROXY)-start}
  results['apiRequestPaths']=API
  results['pfCounters']=pf('-a','cs_official_lab','-vvsr').stdout
 except BaseException as e:
  error=repr(e)
  if isinstance(e,subprocess.CalledProcessError):error+=' stderr='+e.stderr
 finally:
  a=pf('-a','cs_official_lab','-F','rules',check=False);b=pf('-f','/etc/pf.conf',check=False);c=pf('-d',check=False) if not was_enabled else None
  cleanup=a.returncode==0 and b.returncode==0 and (c is None or c.returncode==0)
 if desktop is not None and cleanup:
  artifactFile=root/'artifacts.json';artifactFile.write_text(json.dumps({'cli':str(cli),'desktop':str(desktop)}))
  try:
   child=command('/usr/bin/env','GITHUB_ACTIONS=true','RUNNER_ENVIRONMENT=github-hosted','CS_REAL_UTUN_LAB=ephemeral-only','CS_TEST_UID='+str(UID),'CS_CLIENT_ARTIFACT_JSON='+str(artifactFile),str(Path(__file__).with_name('utun-launch')),sys.executable,str(Path(__file__).with_name('real_utun_clients_probe.py')))
   results['actualUtunClients']=json.loads(child.stdout)
  except subprocess.CalledProcessError as e:
   results['actualUtunClients']={'state':'FAILED','exitCode':e.returncode,'stdout':e.stdout,'stderr':e.stderr}
 cliOK=results.get('cliPositive',{}).get('requestsToLocalFixture',0)>0 and results.get('cliBlocked',{}).get('requestsToLocalFixture')==0
 desktopOK=results.get('desktopPositive',{}).get('proxyRequests',0)>0 and results.get('desktopBlocked',{}).get('proxyRequests')==0
 result=dict(layer='official-blank-client-local-service-observation',results=results,error=error,cleanup=cleanup,cliNetworkObservationPassed=cliOK,desktopNetworkObservationPassed=desktopOK,realAccountUsed=False,subscriptionAuthFlow='NOT_RUN',actualNetworkExtension=False,actualTUNInThisJob=False,productionReady=False)
 print(json.dumps(result,indent=2),flush=True)
 os._exit(0 if error is None and cleanup and cliOK and desktopOK and results.get('actualUtunClients',{}).get('allAssertionsPassed') else 1)
