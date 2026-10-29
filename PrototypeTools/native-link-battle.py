#!/usr/bin/env python3
"""Exercise native friend battles or trades on two disposable VBA-M instances.

The loopback relay forwards the production native command packets and test
observations. It supplies no ROM, RAM, credentials or gameplay commands.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
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
    parser.add_argument('--disconnect-seconds',type=float,default=0,help='Drop the actual active cable, wait, then replace both channels and finish; 0–120 seconds')
    parser.add_argument('--disconnect-stage',choices=['menu','exchange','saved'],default='menu',help='Native trade stage to interrupt; battles always interrupt after entry')
    parser.add_argument('--silent-disconnect',action='store_true',help='Blackhole packets without a transport error; native liveness detection must suspend automatically')
    parser.add_argument('--rate-a',type=float,default=1);parser.add_argument('--rate-b',type=float,default=1)
    parser.add_argument('--local-menus',action='store_true')
    parser.add_argument('--field-services',action='store_true',help='Keep the resident game UI host updated during native entry and battle, as in the app')
    parser.add_argument('--initiator',choices=['A','B'],default='A',help='Player who initiates the friendly battle')
    parser.add_argument('--battle-run',action='store_true',help='Peer A chooses the native Run action; both peers must return and restore their parties')
    parser.add_argument('--battle-party',choices=['healthy','fainted','soul-denied'],default='healthy',help='Disposable party: healthy, ordinary 0HP, or a permanently denied lead plus a living damaged mon')
    parser.add_argument('--trade-cancel',action='store_true',help='Cancel from the native trade menu before offering; both original parties must persist')
    parser.add_argument('--trade',action='store_true',help='Exercise the actual native trade menu, exchange, save and server-state/battery persistence')
    parser.add_argument('--session-entry',action='store_true',help='Exercise the production activity coordinator through native entry and cancel/restore; requires --relay')
    parser.add_argument('--relay',action='store_true',help='Exercise production command transport through a local reliable-message relay')
    parser.add_argument('--shared-world',action='store_true',help='Exercise both native Nugget Bridge first wins and all four shared-prerequisite states')
    args=parser.parse_args()
    args.trade = args.trade or args.trade_cancel
    if (args.battle_run or args.battle_party!='healthy') and (args.trade or args.shared_world or args.session_entry):parser.error('Battle Run and party fixtures require a full native battle')
    if not 0<=args.latency_ms<=100:parser.error('Latency must be 0–100 ms')
    if not 0<=args.disconnect_seconds<=120:parser.error('Disconnect duration must be 0–120 seconds')
    if args.silent_disconnect and not args.disconnect_seconds:parser.error('Silent disconnect requires a positive disconnect duration')
    if args.shared_world and args.disconnect_seconds:parser.error('Disconnect mode covers native battles and trades, not shared-world fixtures')
    if not args.relay:parser.error('The command transport harness requires --relay')
    if not all(1<=x<=8 for x in (args.rate_a,args.rate_b)):parser.error('Rates must be 1–8')
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
            with lock: peers[peer]={**peers.get(peer,{}),**value}
            self.reply({})
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    relay=None; connections={}; condition=threading.Condition(); relay_id=str(uuid.uuid4())
    write_locks={peer:threading.Lock() for peer in ('A','B')}
    packet_times={peer:[] for peer in ('A','B')}
    if args.relay:
        class Forward(socketserver.BaseRequestHandler):
            def handle(self):
                peer=self.request.recv(1).decode('ascii')
                if peer not in ('A','B'):return
                other_peer='B' if peer=='A' else 'A'
                self.request.setsockopt(__import__('socket').IPPROTO_TCP,__import__('socket').TCP_NODELAY,1)
                with condition:
                    old=connections.get(peer)
                    connections[peer]=self.request; condition.notify_all()
                if old is not None:
                    try:old.shutdown(__import__('socket').SHUT_RDWR)
                    except OSError:pass
                buffered=bytearray()
                try:
                    while True:
                        data=self.request.recv(16384)
                        if not data:return
                        buffered.extend(data)
                        if len(buffered)>131072:return
                        if args.latency_ms:time.sleep(args.latency_ms/1000)
                        while len(buffered)>=4:
                            count=int.from_bytes(buffered[:4],'big')
                            if not 38<=count<=4134:return
                            if len(buffered)<count+4:break
                            packet=bytes(buffered[:count+4]);del buffered[:count+4]
                            packet_times[peer].append(time.monotonic())
                            with condition:
                                if not condition.wait_for(lambda:other_peer in connections,timeout=120):return
                                other=connections[other_peer]
                            # Forward complete frames only: a replaced socket
                            # can lose one, but never splice partial streams.
                            # Production retransmission must recover that loss.
                            try:
                                with write_locks[other_peer]:other.sendall(packet)
                            except OSError:continue
                except OSError:pass
                finally:
                    with condition:
                        if connections.get(peer) is self.request:del connections[peer]
                        condition.notify_all()
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
                    copy.setdefault('EnvironmentVariables',{}).update(BOUND_NATIVE_BATTLE_PEER=peer,BOUND_NATIVE_BATTLE_PORT=str(server.server_port),BOUND_NATIVE_TRADE_CANCEL='1' if args.trade_cancel else '0',BOUND_SHARED_WORLD_PAIR='1' if args.shared_world else '0',BOUND_NATIVE_DISCONNECT_SECONDS=str(args.disconnect_seconds),BOUND_NATIVE_DISCONNECT_STAGE=args.disconnect_stage,BOUND_NATIVE_SILENT_DISCONNECT='1' if args.silent_disconnect else '0',BOUND_NATIVE_BATTLE_RUN='1' if args.battle_run else '0',BOUND_NATIVE_BATTLE_PARTY=str(['healthy','fainted','soul-denied'].index(args.battle_party)))
                    copy['EnvironmentVariables'].update(BOUND_NATIVE_BATTLE_RATE=str(args.rate_a if peer=='A' else args.rate_b),BOUND_NATIVE_LOCAL_MENUS='1' if args.local_menus else '0')
                    copy['EnvironmentVariables']['BOUND_NATIVE_FIELD_SERVICES']='1' if args.field_services else '0'
                    copy['EnvironmentVariables']['BOUND_NATIVE_INITIATOR']=args.initiator
                    if relay:copy['EnvironmentVariables'].update(BOUND_NATIVE_BATTLE_RELAY_PORT=str(relay.server_address[1]),BOUND_NATIVE_BATTLE_RELAY_ID=relay_id)
                return copy
            if isinstance(value,list): return [visit(v) for v in value]
            return value.replace('__TESTROOT__',root) if isinstance(value,str) else value
        out=args.output/(peer+'.xctestrun'); out.write_bytes(plistlib.dumps(visit(plistlib.loads(args.xctestrun.read_bytes())))); return out
    try:
        for peer,sim in zip(('A','B'),(args.sim_a,args.sim_b)):
            log=(args.output/(peer+'.log')).open('wb')
            developer=Path(os.environ.get('DEVELOPER_DIR','/Applications/Developer/Xcode.app/Contents/Developer'))
            cmd=[str(developer/'usr/bin/xcodebuild'),'test-without-building','-xctestrun',str(clone(peer)),
                '-destination','platform=iOS Simulator,id='+sim,'-parallel-testing-enabled','NO',
                '-only-testing:BoundIntegrationTests/NativeBattleRuntimeTests/'+('testTwoPlayerNuggetBridgePrerequisite' if args.shared_world else 'testActualNativeTrade' if args.trade else 'testNativeSessionForwardedEntry' if args.session_entry else 'testActualNativeLinkBattle'),
                '-collect-test-diagnostics','never','-resultBundlePath',str(args.output/(peer+'.xcresult'))]
            processes.append((subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT),log))
        deadline=time.monotonic()+800
        while time.monotonic()<deadline:
            states=[p.poll() for p,_ in processes]
            if any(code is not None and code!=0 for code in states): raise RuntimeError('A native activity test failed')
            if all(code==0 for code in states): break
            time.sleep(0.5)
        else: raise TimeoutError('Native activity test timed out')
        with lock: result=dict(peers)
        if args.shared_world:
            expected=['neither-won','only-a-won','only-b-won','both-won']
            if set(result)!={'A','B'} or not all(v.get('stage')=='done' and v.get('sharedWorld') and
                    [c['case'] for c in v.get('cases',[])]==expected and
                    [c['trainer2Battle'] for c in v['cases']]==[False,False,False,True] and
                    v.get('nativeBattleEntries')==[0x6e,0x7b] for v in result.values()):
                raise RuntimeError('Missing paired native progression evidence')
        elif set(result)!=set(('A','B')) or not all(v.get('stage')=='done' and ((v.get('canceled') if args.trade_cancel else v.get('trade')) and v.get('persisted') if args.trade else v.get('battle') and (args.session_entry or args.battle_run or v.get('damaged')) and v.get('restored')) for v in result.values()):
            raise RuntimeError('Missing native activity or persistence/restoration evidence')
        outcomes={q.get('outcome') for q in result.values()}
        if not args.shared_world and not args.trade_cancel and not all(v.get('ownerRestored') for v in result.values()):
            raise RuntimeError('Missing cold-core/new-owner durable continuation evidence')
        if args.disconnect_seconds and not all(v.get('disconnectResumed') and v.get('disconnectSeconds')==args.disconnect_seconds for v in result.values()):raise RuntimeError('Missing native same-activity disconnect/resume evidence')
        if args.silent_disconnect and not all(v.get('silentDisconnect') for v in result.values()):raise RuntimeError('Missing automatic native liveness suspension evidence')
        if not args.shared_world and not args.trade and not args.session_entry:
            if not args.battle_run and {q & 0x7f for q in outcomes} not in ({1,2},{3}): raise RuntimeError('Native outcomes disagree')
            if args.battle_run and not result['A'].get('nativeRunIntent'): raise RuntimeError('Actual native Run selection missing')
            if not all(v.get('partyUnchanged') for v in result.values()): raise RuntimeError('Original party was not restored')
        passed=True
    except BaseException as exc:
        error=type(exc).__name__+': '+str(exc)
    finally:
        for process,log in processes:
            if process.poll() is None: process.terminate()
            log.close()
        with lock: result=dict(peers)
        peaks={peer:max((sum(t-1 < other <= t for other in times) for t in times),default=0) for peer,times in packet_times.items()}
        (args.output/'summary.json').write_text(json.dumps(dict(passed=passed,error=error,relay=args.relay,latencyMs=args.latency_ms,entryOnly=args.session_entry,initiator=args.initiator,fieldServices=args.field_services,peakPacketsPerSecond=peaks,trade=args.trade,cancel=args.trade_cancel,sharedWorld=args.shared_world,battleRun=args.battle_run,battleParty=args.battle_party,disconnectSeconds=args.disconnect_seconds,disconnectStage=args.disconnect_stage,silentDisconnect=args.silent_disconnect,elapsed=time.monotonic()-started,peers=result,
            rates=[args.rate_a,args.rate_b],localMenus=args.local_menus,limits='Native command transport on two owned simulators over host loopback; separate from authenticated internet transport and normal-app interaction acceptance.'),indent=2)+'\n')
        server.shutdown(); server.server_close()
        if relay:relay.shutdown(); relay.server_close()
    print(json.dumps(dict(passed=passed,error=error,elapsed=time.monotonic()-started)))
    raise SystemExit(0 if passed else 1)


if __name__=='__main__': main()
