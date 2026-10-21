#!/usr/bin/env python3
"""Run a disposable two-VBA-M native battle before testing RTC/UI integration.

The loopback relay forwards the production native command packets and test
observations. It supplies no ROM, RAM, credentials or gameplay commands.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import plistlib
import subprocess
import threading
import time
import socketserver
import uuid


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xctestrun',type=Path,required=True)
    parser.add_argument('--sim-a',required=True); parser.add_argument('--sim-b',required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--latency-ms',type=int,default=0,help='Controlled local one-way relay delay, 0–100 ms')
    parser.add_argument('--session-entry',action='store_true',help='Exercise the production activity coordinator through native entry and cancel/restore; requires --relay')
    parser.add_argument('--relay',action='store_true',help='Exercise production command transport through a local reliable-message relay')
    args=parser.parse_args()
    if not 0<=args.latency_ms<=100:parser.error('Latency must be 0–100 ms')
    if not args.relay:parser.error('The command transport harness requires --relay')
    if args.sim_a==args.sim_b: parser.error('Two distinct disposable simulators are required')
    args.output.mkdir(parents=True,exist_ok=False)
    peers={}; lock=threading.Lock()
    class Handler(BaseHTTPRequestHandler):
        def log_message(self,*_): pass
        def reply(self,body):
            data=json.dumps(body).encode(); self.send_response(200); self.send_header('Content-Length',str(len(data)))
            self.end_headers(); self.wfile.write(data)
        def do_GET(self):
            with lock: value=dict(peers)
            self.reply(dict(peers=value))
        def do_POST(self):
            peer=self.path.removeprefix('/'); length=int(self.headers.get('Content-Length','0'))
            if peer not in ('A','B') or not 0<length<=1000000: self.send_error(400); return
            value=json.loads(self.rfile.read(length))
            with lock: peers[peer]=value
            self.reply({})
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    relay=None; connections={}; condition=threading.Condition(); relay_id=str(uuid.uuid4())
    if args.relay:
        class Forward(socketserver.BaseRequestHandler):
            def handle(self):
                peer=self.request.recv(1).decode('ascii')
                if peer not in ('A','B'):return
                self.request.setsockopt(__import__('socket').IPPROTO_TCP,__import__('socket').TCP_NODELAY,1)
                with condition:
                    if peer in connections:return
                    connections[peer]=self.request; condition.notify_all()
                    if not condition.wait_for(lambda:len(connections)==2,timeout=120):return
                    other=connections['B' if peer=='A' else 'A']
                while True:
                    data=self.request.recv(16384)
                    if not data:return
                    if args.latency_ms:time.sleep(args.latency_ms/1000)
                    try:other.sendall(data)
                    except OSError:return
        class Relay(socketserver.ThreadingTCPServer): daemon_threads=True
        relay=Relay(('127.0.0.1',0),Forward)
        threading.Thread(target=relay.serve_forever,daemon=True).start()
    processes=[]; started=time.monotonic(); passed=False; error=None
    def clone(peer):
        root=str(args.xctestrun.resolve().parent)
        def visit(value):
            if isinstance(value,dict):
                copy={k:visit(v) for k,v in value.items()}
                if 'TestBundlePath' in copy:
                    copy.setdefault('EnvironmentVariables',{}).update(BOUND_NATIVE_BATTLE_PEER=peer,BOUND_NATIVE_BATTLE_PORT=str(server.server_port))
                    if relay:copy['EnvironmentVariables'].update(BOUND_NATIVE_BATTLE_RELAY_PORT=str(relay.server_address[1]),BOUND_NATIVE_BATTLE_RELAY_ID=relay_id)
                return copy
            if isinstance(value,list): return [visit(v) for v in value]
            return value.replace('__TESTROOT__',root) if isinstance(value,str) else value
        out=args.output/(peer+'.xctestrun'); out.write_bytes(plistlib.dumps(visit(plistlib.loads(args.xctestrun.read_bytes())))); return out
    try:
        for peer,sim in zip(('A','B'),(args.sim_a,args.sim_b)):
            log=(args.output/(peer+'.log')).open('wb')
            cmd=['/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild','test-without-building','-xctestrun',str(clone(peer)),
                '-destination','platform=iOS Simulator,id='+sim,'-parallel-testing-enabled','NO',
                '-only-testing:BoundIntegrationTests/NativeBattleRuntimeTests/'+('testNativeSessionForwardedEntry' if args.session_entry else 'testActualNativeLinkBattle'),
                '-collect-test-diagnostics','never','-resultBundlePath',str(args.output/(peer+'.xcresult'))]
            processes.append((subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT),log))
        deadline=time.monotonic()+800
        while time.monotonic()<deadline:
            states=[p.poll() for p,_ in processes]
            if any(code is not None and code!=0 for code in states): raise RuntimeError('A native battle test failed')
            if all(code==0 for code in states): break
            time.sleep(0.5)
        else: raise TimeoutError('Native battle test timed out')
        with lock: result=dict(peers)
        if set(result)!=set(('A','B')) or not all(v.get('stage')=='done' and v.get('battle') and (args.session_entry or v.get('damaged')) and v.get('restored') for v in result.values()):
            raise RuntimeError('Missing actual battle/damage/restoration evidence')
        outcomes={q['outcome'] for q in result.values()}
        if not args.session_entry and outcomes not in ({1,2},{3}): raise RuntimeError('Native outcomes disagree')
        passed=True
    except BaseException as exc:
        error=type(exc).__name__+': '+str(exc)
    finally:
        for process,log in processes:
            if process.poll() is None: process.terminate()
            log.close()
        with lock: result=dict(peers)
        (args.output/'summary.json').write_text(json.dumps(dict(passed=passed,error=error,relay=args.relay,latencyMs=args.latency_ms,entryOnly=args.session_entry,elapsed=time.monotonic()-started,peers=result,
            limits='Native command transport on two owned simulators over host loopback; separate from real Agora and normal-app interaction acceptance.'),indent=2)+'\n')
        server.shutdown(); server.server_close()
        if relay:relay.shutdown(); relay.server_close()
    print(json.dumps(dict(passed=passed,error=error,elapsed=time.monotonic()-started)))
    raise SystemExit(0 if passed else 1)


if __name__=='__main__': main()
