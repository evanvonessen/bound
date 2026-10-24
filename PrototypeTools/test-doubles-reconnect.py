#!/usr/bin/env python3
"""Two disposable simulator apps exercise native doubles recovery over loopback.

Runs the production VBA-M core/session/journal/wire with synthetic peer IDs.
Cuts both control and native delivery, reloads a fresh app session from disk,
then injects one stale wire packet. No accounts, service credentials or remote
transport are used. Inputs and detailed outputs stay in ignored .build/.
"""
import argparse,base64,hashlib,json,plistlib,subprocess,threading,time
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path

class Relay:
    def __init__(self,encounter):
        self.lock=threading.Lock();self.stage='boot';self.changed=time.monotonic();self.encounter=encounter
        self.reports={};self.queues={'A':[],'B':[]};self.stale={};self.stages=[];self.counts={'control':0,'native':0};self.replay=0;self.control={};self.progress_drop=False;self.local_catch_drop=False;self.play_cut=None;self.cut_key=None;self.cut_at=0
    def change(self,stage):
        self.stages.append({'stage':self.stage,'reports':self.reports.copy()});self.stage=stage;self.changed=time.monotonic();self.cut_key=None;self.cut_at=0
        if stage.startswith('offline'):self.queues={'A':[],'B':[]}
        if stage=='play' and not self.replay:
            self.play_cut={p:base64.b64decode(r['cut'])[8:10] for p,r in self.reports.items()}
            for p,packet in self.stale.items():self.queues[p].append(packet);self.replay+=1
        print(stage,flush=True)
    def compatible(self):
        try:a,b=[base64.b64decode(self.reports[p]['cut'],validate=True) for p in ('A','B')]
        except (KeyError,ValueError):return False
        if len(a)!=92 or len(b)!=92 or a[:4]!=b[:4] or a[24:28]==b[24:28]:return False
        if a[:4]==b'CLC1':return True
        half=lambda p,i:int.from_bytes(p[i:i+2],'little')
        return (a[:4]==b'CUT2' and half(a,4)==half(b,4)>0 and half(a,6)==half(b,10)
            and half(b,6)==half(a,10) and a[20:24]==b[20:24] and a[28:60]==b[60:92] and b[28:60]==a[60:92])
    def settled(self):
        if not self.compatible():self.cut_key=None;return False
        key=tuple(self.reports[p]['cut'] for p in ('A','B'))
        if key!=self.cut_key:self.cut_key=key;self.cut_at=time.monotonic();return False
        return time.monotonic()-self.cut_at>=.75
    def advance(self):
        if set(self.reports)!= {'A','B'}:return
        r=list(self.reports.values());both=lambda key:all(x.get(key) for x in r)
        phase=lambda n:all(x.get('phase')==n for x in r)
        if self.stage=='start' and any(x.get('status')=='Cooperative battle ended' for x in r):self.change('failed')
        elif self.stage=='boot' and both('prepared'):self.change('start')
        elif self.stage=='start' and phase(5) and all(x.get('ownCommand')==18 for x in r) and self.settled():self.change('offline')
        elif self.stage=='offline' and both('recovering') and self.compatible():self.change('rejoin')
        elif self.stage=='rejoin' and all(x.get('recovered',0)>=1 for x in r) and not any(x.get('recovering') for x in r) and phase(5) and all(x.get('ownCommand')==18 for x in r) and self.settled():self.change('play' if self.progress_drop else 'offline-reload')
        elif self.stage=='offline-reload' and both('recovering') and all(x.get('reloads')==1 for x in r) and self.compatible():self.change('rejoin-reload')
        elif self.stage=='rejoin-reload' and all(x.get('recovered',0)>=2 for x in r) and phase(5):self.change('play')
        elif self.stage=='play' and not self.progress_drop and phase(5) and all(x.get('ownCommand')==18 for x in r) and self.compatible() and self.play_cut and any(base64.b64decode(self.reports[p]['cut'])[8:10]!=self.play_cut[p] for p in ('A','B')):
            self.progress_drop=True;self.change('offline')
        elif self.stage=='play' and self.encounter==1 and all(x.get('localStage') in (1,2) for x in r) and self.compatible():self.change('offline-catch')
        elif self.stage=='offline-catch' and both('recovering') and self.compatible():self.change('catch-rejoin')
        elif self.stage=='offline-local-catch' and both('recovering') and self.compatible():self.change('catch-rejoin')
        elif self.stage=='catch-rejoin' and not any(x.get('recovering') for x in r) and all(x.get('localStage')==1 for x in r):
            if self.local_catch_drop:self.change('catch-play')
            else:self.local_catch_drop=True;self.change('offline-local-catch')
        elif self.stage in ('play','catch-play') and both('field') and all(x.get('status')=='Cooperative battle complete' for x in r) and all(x.get('outcome')==(7 if self.encounter==1 else 1) for x in r):self.change('done')
        elif time.monotonic()-self.changed>(420 if self.stage in ('play','catch-play') else 120):self.change('failed')
    def status(self):return {'stage':self.stage,'reports':self.reports,'counts':self.counts,'stale_packets_injected':self.replay,'midcombat_disconnect':self.progress_drop,'local_catch_disconnect':self.local_catch_drop,'stages':self.stages,'last_control':self.control}

class Handler(BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*_):pass
    def reply(self,code,body=b''):
        self.send_response(code);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
    def do_POST(self):
        parts=self.path.strip('/').split('/');n=int(self.headers.get('Content-Length','0'))
        if n>32768 or len(parts)<2 or parts[1] not in ('A','B'):self.reply(400);return
        body=self.rfile.read(n);state=self.server.relay;p=parts[1]
        with state.lock:
            if parts[0]=='packet' and len(parts)==3 and parts[2] in ('control','native') and 0<n<=4126:
                if state.stage.startswith('offline'):code=503
                else:
                    target='B' if p=='A' else 'A';packet={'kind':parts[2],'data':base64.b64encode(body).decode()}
                    if len(state.queues[target])>=512:self.reply(503);return
                    state.queues[target].append(packet);state.counts[parts[2]]+=1
                    if parts[2]=='control':state.control[f'{p}:{int.from_bytes(body[4:8],"little")}']=body.hex()
                    if parts[2]=='native' and state.stage in ('boot','start'):state.stale[target]=packet
                    code=200
                self.reply(code);return
            if parts[0]=='poll':
                state.reports[p]=json.loads(body);state.advance();packets=state.queues[p];state.queues[p]=[]
                self.reply(200,json.dumps({'stage':state.stage,'packets':packets}).encode());return
        self.reply(404)

def clone(source,target,role,port,encounter,fixture):
    root=str(source.resolve().parent)
    def walk(x):
        if isinstance(x,dict):
            result={k:walk(v) for k,v in x.items()}
            if 'TestBundlePath' in x:result.setdefault('EnvironmentVariables',{}).update(BOUND_DOUBLES_ROLE=role,BOUND_DOUBLES_PORT=str(port),BOUND_DOUBLES_ENCOUNTER=str(encounter),BOUND_DOUBLES_FIXTURES=str(fixture))
            return result
        if isinstance(x,list):return [walk(v) for v in x]
        return x.replace('__TESTROOT__',root) if isinstance(x,str) else x
    target.write_bytes(plistlib.dumps(walk(plistlib.loads(source.read_bytes()))))

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--xctestrun',type=Path,required=True);p.add_argument('--sim-a',required=True);p.add_argument('--sim-b',required=True);p.add_argument('--encounter',choices=('doubles','raid','facility'),required=True);p.add_argument('--fixtures',type=Path,required=True);p.add_argument('--output',type=Path,required=True);args=p.parse_args()
    assert args.sim_a!=args.sim_b
    devices=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','--json']))['devices']
    inventory={d['udid']:d for group in devices.values() for d in group}
    for sim in (args.sim_a,args.sim_b):
        if sim not in inventory or not inventory[sim]['name'].startswith('Doubles Recovery QA'):
            p.error('Use dedicated Doubles Recovery QA simulators; ordinary simulator saves are excluded.')
    args.output.mkdir(parents=True,exist_ok=False)
    rom_sha256=hashlib.sha256((args.fixtures/'rrbin-doubles.gba').read_bytes()).hexdigest()
    kind=('doubles','raid','facility').index(args.encounter);relay=Relay(kind);server=ThreadingHTTPServer(('127.0.0.1',0),Handler);server.daemon_threads=True;server.relay=relay
    threading.Thread(target=server.serve_forever,daemon=True).start();children=[]
    try:
        for role,sim in zip(('A','B'),(args.sim_a,args.sim_b)):
            run=args.output/f'{role}.xctestrun';clone(args.xctestrun,run,role,server.server_port,kind,args.fixtures.resolve())
            log=(args.output/f'{role}.log').open('wb')
            child=subprocess.Popen(['xcodebuild','test-without-building','-xctestrun',str(run),'-destination',f'platform=iOS Simulator,id={sim}','-parallel-testing-enabled','NO','-collect-test-diagnostics','never','-only-testing:BoundIntegrationTests/CooperativeDoublesReconnectTests','-resultBundlePath',str(args.output/f'{role}.xcresult')],stdout=log,stderr=subprocess.STDOUT);children.append((child,log))
        deadline=time.monotonic()+780
        while time.monotonic()<deadline:
            with relay.lock:report=relay.status();stage=relay.stage
            (args.output/'progress.json').write_text(json.dumps(report,indent=2)+'\n')
            if all(c.poll() is not None for c,_ in children):break
            if stage=='failed':break
            time.sleep(.25)
        for child,_ in children:
            if child.poll() is None:
                try:child.wait(timeout=20 if relay.stage=='done' else 1)
                except subprocess.TimeoutExpired:child.terminate()
        passed=relay.stage=='done' and all(c.poll()==0 for c,_ in children)
        report={'passed':passed,'encounter':args.encounter,'rom_sha256':rom_sha256,**relay.status(),'limits':'Two local simulator apps and production native session/recovery/wire with synthetic identities. No authenticated service or physical-device test.'}
        (args.output/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({'passed':passed,'stage':relay.stage,'reports':relay.reports},indent=2));return 0 if passed else 1
    finally:
        for child,log in children:
            if child.poll() is None:child.terminate()
            log.close()
        server.shutdown()
if __name__=='__main__':raise SystemExit(main())
