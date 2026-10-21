#!/usr/bin/env python3
"""Coordinate two actual Bound UIs over real Agora using disposable simulators.

No credentials are read, no service settings change, and no gameplay commands
are injected into the app. XCTest performs every input and save/load through UI.
Private fixture/session preparation and test-friend cleanup belong to the caller.
"""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import plistlib
import subprocess
import threading
import time
import uuid

PEERS = ('A', 'B')


class Coordinator:
    def __init__(self, simulators):
        self.simulators = simulators
        self.directories = {}
        self.stage = 'waiting'
        self.ui = {}
        self.lock = threading.Lock()
        self.checkpoints = []
        self.snapshots = {}
        self.soak = {}

    def peer(self, peer):
        path = self.directories.get(peer)
        if path is None or not path.exists():
            # Xcode moves data containers during installation. Discover only our
            # named QA observation files in the explicitly supplied simulators;
            # do not serialize UI requests behind simctl registry operations.
            root = Path.home() / 'Library/Developer/CoreSimulator/Devices' / self.simulators[peer] / 'data/Containers/Data/Application'
            candidates = list(root.glob('*/Documents/FullAppGameplayQA/status.json'))
            if not candidates: return {}
            path = max(candidates, key=lambda p:p.stat().st_mtime)
            self.directories[peer] = path
        try:
            value = json.loads(path.read_text())
            value['observationAge'] = max(0, time.time() - path.stat().st_mtime)
            return value
        except (OSError, ValueError):
            return {}

    def status(self):
        with self.lock:
            stage, ui = self.stage, dict(self.ui)
        return dict(stage=stage, peers={p:self.peer(p) for p in PEERS}, ui=ui)

    def save_file(self, peer, identifier):
        identifier = str(uuid.UUID(identifier)).upper()
        container = self.directories[peer].parents[2]
        matches = list((container/'Documents/Database/Save States').glob('*/'+identifier))
        if len(matches)!=1 or matches[0].stat().st_size<1024:
            raise RuntimeError('A native save-state file is missing or empty')
        return matches[0]

    def change(self, stage):
        with self.lock:
            self.stage = stage
        print('Stage: ' + stage, flush=True)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status); self.send_header('Content-Length', str(len(data)))
        self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        self.reply(200, self.server.state.status()) if self.path == '/status' else self.reply(404, {})
    def do_POST(self):
        peer = self.path.removeprefix('/ui/')
        length = int(self.headers.get('Content-Length', 0))
        if peer not in PEERS or not 0 < length <= 16384:
            self.reply(400, {}); return
        value = json.loads(self.rfile.read(length))
        # The UI reports only native observations and stage names, never auth.
        allowed = {'stage','peer','run','elapsed','reader','frame','core','running','joined','active',
                   'transport','received','videoReceived','renewals','visiblePixels','restores','map','tile','elevation','saveState','savedTile',
                   'nativeBattle','battleReturned','battleOutcome','battleFlags','battlePlayerHP','battleEnemyHP','battleFailure','battlesCompleted','battlesRestored','interactionPhase'}
        value = {k:v for k,v in value.items() if k in allowed}
        with self.server.state.lock:
            self.server.state.ui[peer] = value
        self.reply(200, {})


def clone(source, destination, peer, port, trade=None):
    root = str(source.resolve().parent)
    def rewrite(node):
        if isinstance(node, dict):
            result = {k:rewrite(v) for k,v in node.items()}
            if 'TestBundlePath' in result:
                result.setdefault('EnvironmentVariables', {}).update(BOUND_GAMEPLAY_PEER=peer, BOUND_GAMEPLAY_PORT=str(port))
            if trade and 'TestBundlePath' in result:
                result['EnvironmentVariables']['BOUND_GAMEPLAY_TRADE']=trade
            return result
        if isinstance(node, list): return [rewrite(v) for v in node]
        return node.replace('__TESTROOT__', root) if isinstance(node, str) else node
    destination.write_bytes(plistlib.dumps(rewrite(plistlib.loads(source.read_bytes()))))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xctestrun', type=Path, required=True)
    parser.add_argument('--sim-a', required=True); parser.add_argument('--sim-b', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--duration', type=int, default=900)
    parser.add_argument('--smoke', action='store_true')
    parser.add_argument('--trade', choices=['complete','menu-disconnect','exchange-disconnect','saved-disconnect'], help='Normal walk-up native trade over Agora and disconnect recovery')
    parser.add_argument('--battles-only', action='store_true', help='Actual walk-up/A native battle over real Agora, damage, outcome and world restore')
    parser.add_argument('--interactions-only', action='store_true', help='Short walk-up/A and reliable invitation regression; does not launch a battle or trade')
    parser.add_argument('--native-only', action='store_true', help='Preflight maps and native states without an RTC connection')
    args = parser.parse_args()
    if args.sim_a == args.sim_b or args.duration < (1 if args.smoke or args.native_only or args.interactions_only or args.battles_only or args.trade else 900):
        parser.error('Use two distinct disposable simulators; acceptance requires at least 900 seconds')
    args.output.mkdir(parents=True, exist_ok=False)
    state = Coordinator(dict(zip(PEERS, (args.sim_a, args.sim_b))))
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler); server.state = state
    threading.Thread(target=server.serve_forever, daemon=True).start()
    processes = []; passed = False; failure = None
    started = time.monotonic()
    try:
        for peer in PEERS:
            run = args.output / (peer + '.xctestrun'); clone(args.xctestrun, run, peer, server.server_port, args.trade)
            log = (args.output / (peer + '.log')).open('wb')
            command = ['/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild','test-without-building','-xctestrun',str(run),
                '-destination','platform=iOS Simulator,id='+state.simulators[peer],'-parallel-testing-enabled','NO',
                '-only-testing:BoundCompanionUITests/FullAppGameplayUITests/'+('testNativeMapAndSaveRestore' if args.native_only else 'testActualFriendTrade' if args.trade else 'testActualFriendBattle' if args.battles_only else 'testFriendWorldInvitations' if args.interactions_only else 'testFullAppLiveGameplay'),
                '-collect-test-diagnostics','never','-resultBundlePath',str(args.output/(peer+'.xcresult'))]
            processes.append((subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT),log))

        def wait(label, predicate, timeout=90):
            deadline = time.monotonic()+timeout
            while time.monotonic()<deadline:
                value = state.status()
                if predicate(value):
                    state.checkpoints.append(dict(name=label,elapsed=time.monotonic()-started,**value))
                    print('Verified: '+label,flush=True); return value
                if args.battles_only and label=='battle-accept' and any(v.get('interactionPhase')=='ended' for v in value['peers'].values()):
                    raise RuntimeError('Battle startup ended: '+', '.join(v.get('battleFailure','') for v in value['peers'].values()))
                if any(p.poll() is not None and (not args.native_only or p.returncode!=0) for p,_ in processes):
                    raise RuntimeError('A UI test exited before '+label)
                time.sleep(0.3)
            raise TimeoutError('No native evidence for '+label)

        def visible(value):
            return all(v.get('reader')=='live' and v.get('core')=='com.rileytestut.GBADeltaCore'
                and v.get('transport')=='agora' and v.get('joined') and v.get('received',0)>10
                and v.get('visiblePixels',0)>20 and v.get('observationAge',100)<2 for v in value['peers'].values())
        def reported(value, stage): return all(value['ui'].get(p,{}).get('stage')==stage for p in PEERS)
        if args.trade:
            wait('positioned native players',lambda v:reported(v,'positioned') and visible(v),360)
            stages=['trade-invite','trade-accept']
            if args.trade!='menu-disconnect': stages.append('trade-exchange')
            stages += ['trade-exit' if args.trade=='complete' else 'trade-disconnect','trade-verify']
            for stage in stages:
                state.change(stage); result=wait(stage,lambda v:reported(v,stage),200)
            parties={p:result['peers'][p].get('tradeMarker') for p in PEERS}
            expected={'A':0xBB,'B':0xBC} if args.trade=='menu-disconnect' else {'A':0xBC,'B':0xBB}
            if args.trade=='exchange-disconnect':
                if parties not in ({'A':0xBB,'B':0xBC},{'A':0xBC,'B':0xBB}):
                    raise RuntimeError('Interrupted trade lost or duplicated an offered Pokemon')
            elif parties!=expected: raise RuntimeError('Trade party identities do not match the expected result')
            if not all(v.get('reader')=='live' and v.get('tradeUnofferedUnchanged') and not v.get('tradeRecoveryBlocked') for v in result['peers'].values()):
                raise RuntimeError('Trade recovery did not restore both playable worlds with intact unoffered parties')
        elif args.battles_only:
            wait('positioned native players',lambda v:reported(v,'positioned') and visible(v),360)
            for stage,timeout in [('battle-invite',90),('battle-accept',180)]:
                state.change(stage); result=wait(stage,lambda v:reported(v,stage),timeout)
            state.change('battle-play')
            wait('both players take native damage',lambda v:reported(v,'battle-damage'),300)
            result=wait('native knockout, outcome and restore',lambda v:reported(v,'battle-play'),360)
            if not all(v.get('battlesCompleted')==1 and v.get('battlesRestored')==1 and not v.get('battleFailure') for v in result['peers'].values()):
                raise RuntimeError('Native battle did not complete and restore both players')
            outcomes={v.get('battleOutcome') for v in result['peers'].values()}
            if outcomes not in ({1,2},{3}): raise RuntimeError('Native battle outcomes disagree')
        elif args.interactions_only:
            wait('positioned native players', lambda v:reported(v,'positioned') and visible(v),360)
            for stage in ['facing-away','open-interaction','battle-invite','battle-accept','close-battle','trade-invite','trade-decline']:
                state.change(stage)
                wait(stage,lambda v:reported(v,stage),90)
        elif args.native_only:
            result=wait('native map and save-state preflight',lambda v:reported(v,'native-done'),360)
            for peer in PEERS:
                observed=result['ui'][peer]
                if observed.get('reader')!='live' or observed.get('map')!=[4,3] or observed.get('tile')!=observed.get('savedTile') or observed.get('restores',0)<1:
                    raise RuntimeError('Native preflight did not restore the actual saved position')
                f=state.save_file(peer,observed['saveState'])
                state.snapshots[peer]=dict(sha256=hashlib.sha256(f.read_bytes()).hexdigest(),bytes=f.stat().st_size,tile=observed['savedTile'])
        else:
            wait('normal UI connection',lambda v:reported(v,'ready') and visible(v)
                 and v['peers']['A'].get('run')==v['peers']['B'].get('run')
                 and all(v['ui'][p].get('run')==v['peers'][p].get('run') for p in PEERS),360)
            connected = time.monotonic()
            state.change('lab-visible')
            wait('live lab movement',visible)
            state.change('save-lab'); saved=wait('native save-state creation',lambda v:reported(v,'save-lab'),120)
            files = {p:state.save_file(p,saved['ui'][p]['saveState']) for p in PEERS}
            file_hashes = {p:hashlib.sha256(f.read_bytes()).hexdigest() for p,f in files.items()}
            if file_hashes['A']==file_hashes['B'] or saved['ui']['A']['savedTile']==saved['ui']['B']['savedTile']:
                raise RuntimeError('The two native snapshots must preserve different player positions')
            state.snapshots = {p:dict(sha256=file_hashes[p],bytes=files[p].stat().st_size,
                                      tile=saved['ui'][p]['savedTile']) for p in PEERS}
            for stage, moving, other in [('exit-a','A','B'),('exit-b','B','A')]:
                state.change(stage)
                wait(stage,lambda v:reported(v,stage) and v['peers'][moving].get('map')!=[4,3]
                     and v['peers'][moving].get('reader')=='live' and
                     (moving=='B' or (v['peers'][other].get('map')==[4,3] and all(q.get('visiblePixels',0)==0 for q in v['peers'].values()))),120)
            state.change('outside');wait('outside reunion',lambda v:reported(v,'outside') and visible(v))
            before_restore=state.status()
            state.change('restore-a')
            restored_a=wait('actual A save-state restore',lambda v:reported(v,'restore-a') and v['peers']['A'].get('map')==[4,3]
                 and v['peers']['A'].get('restores',0)>saved['peers']['A'].get('restores',0)
                 and v['peers']['B'].get('map')!=[4,3] and all(q.get('visiblePixels',0)==0 for q in v['peers'].values()),120)
            if hashlib.sha256(files['B'].read_bytes()).hexdigest()!=file_hashes['B'] or restored_a['peers']['B'].get('frame',0)<=before_restore['peers']['B'].get('frame',0):
                raise RuntimeError('Restoring A must preserve B snapshot and continuing gameplay')
            state.snapshots['B']['unchangedAfterPeerRestore'] = True
            state.change('restore-b');wait('actual B restore and reunion',lambda v:reported(v,'restore-b') and visible(v),120)
            if hashlib.sha256(files['A'].read_bytes()).hexdigest()!=file_hashes['A']:
                raise RuntimeError('Restoring B must preserve A snapshot')
            state.snapshots['A']['unchangedAfterPeerRestore'] = True
            state.change('background-a')
            wait('background hides remote sprite',lambda v:v['ui'].get('A',{}).get('stage')=='background-start'
                 and v['peers']['B'].get('visiblePixels',0)==0 and v['peers']['B'].get('reader')=='live'
                 and v['peers']['B'].get('running') and v['peers']['B'].get('joined'),30)
            wait('foreground resumes fresh presence',lambda v:reported(v,'background-a') and visible(v),90)
            state.change('soak')
            baseline = state.status()['peers']
            seen = {p:set() for p in PEERS}
            visible_samples = {p:0 for p in PEERS}
            missing_since = {p:None for p in PEERS}
            samples = 0
            while time.monotonic()-connected<args.duration:
                if any(p.poll() is not None for p,_ in processes):raise RuntimeError('UI test exited during sustained gameplay')
                value = state.status(); samples += 1
                for p,q in value['peers'].items():
                    if q.get('reader')=='live' and q.get('joined') and q.get('observationAge',100)<2:
                        missing_since[p] = None
                        if q.get('tile'):seen[p].add(tuple(q['tile']))
                    else:
                        missing_since[p] = missing_since[p] or time.monotonic()
                        if time.monotonic()-missing_since[p]>10:
                            raise RuntimeError('Native gameplay stopped during the sustained interval')
                    if q.get('visiblePixels',0)>20:visible_samples[p] += 1
                time.sleep(1)
            sustained=wait('sustained real Agora gameplay',lambda v:visible(v) and all(q.get('renewals',0)>=2 for q in v['peers'].values()))
            state.soak = {p:dict(samples=samples,visibleSamples=visible_samples[p],distinctTiles=len(seen[p]),
                receivedGain=sustained['peers'][p].get('received',0)-baseline[p].get('received',0),
                videoGain=sustained['peers'][p].get('videoReceived',0)-baseline[p].get('videoReceived',0)) for p in PEERS}
            if not args.smoke and any(q['distinctTiles']<3 or q['receivedGain']<100 or q['videoGain']<100 or q['visibleSamples']<10 for q in state.soak.values()):
                raise RuntimeError('Sustained acceptance requires continuing movement, presence and video on both peers')
            state.change('stop');wait('normal UI stop',lambda v:reported(v,'stop') and all(not q.get('active') and q.get('visiblePixels',0)==0 for q in v['peers'].values()),120)
        state.change('done')
        for process,_ in processes:
            deadline=time.monotonic()+90
            while process.poll() is None and time.monotonic()<deadline:time.sleep(0.2)
            if process.poll() is None or process.returncode!=0:raise RuntimeError('Xcode did not finish the UI test successfully')
        passed=True
    except BaseException as error:
        failure=type(error).__name__+': '+str(error)
        print(failure,flush=True)
    finally:
        if not passed:state.change('failed')
        for process,log in processes:
            if process.poll() is None:process.terminate()
            log.close()
        (args.output/'summary.json').write_text(json.dumps(dict(passed=passed,trade=args.trade,smoke=args.smoke,nativeOnly=args.native_only,interactionsOnly=args.interactions_only,battlesOnly=args.battles_only,failure=failure,
            elapsed=time.monotonic()-started,checkpoints=state.checkpoints,final=state.status(),
            snapshots=state.snapshots,
            soak=state.soak,
            limits='Two full Bound simulator UIs on one host network; no physical devices, performance or separate-network proof.'),indent=2)+'\n')
        server.shutdown();server.server_close()
    raise SystemExit(0 if passed else 1)


if __name__=='__main__':main()
