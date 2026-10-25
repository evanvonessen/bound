"""Two-process VBA-M presence acceptance harness; loopback by default.

Requires an already built BoundIntegrationQA xctestrun and two dedicated booted
Simulators with the private ROM/seed fixtures from Docs/BOUND-MULTIPLAYER.md.
With --agora, the native tests use the real transport and consume one-use normal
QA access-session files from their private fixture directories. This coordinator
never reads credentials and disables both loopback pose endpoints in that mode.
The default relay retains only the latest <=768-byte packet for each peer. Output is
metadata only; it never writes packet bodies, ROMs, artwork, or saves.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import plistlib
import subprocess
import threading
import time
from urllib.parse import parse_qs, urlparse


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.stage = "walk"
        self.online = True
        self.latest = {}
        self.reports = {}
        self.sequence = 0
        self.packets = {"A": 0, "B": 0}
        self.maximum_bytes = 0
        self.agora = False

    def snapshot(self):
        with self.lock:
            return dict(stage=self.stage, online=self.online, reports=dict(self.reports),
                        packets=dict(self.packets), maximumPacketBytes=self.maximum_bytes)

    def change(self, stage, online=True):
        with self.lock:
            self.stage = stage
            self.online = online
            self.latest.clear()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def reply(self, code, data=b"", sequence=None):
        self.send_response(code)
        self.send_header("Content-Length", str(len(data)))
        if sequence is not None:
            self.send_header("X-Relay-Sequence", str(sequence))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        state = self.server.state
        url = urlparse(self.path)
        if url.path == "/status":
            self.reply(200, json.dumps(state.snapshot()).encode())
            return
        peer = url.path.removeprefix("/presence/")
        if state.agora:
            self.reply(403)
            return
        if peer not in ("A", "B"):
            self.reply(404)
            return
        try:
            after = int(parse_qs(url.query).get("after", ["0"])[0])
        except ValueError:
            self.reply(400)
            return
        with state.lock:
            online = state.online
            packet = state.latest.get("B" if peer == "A" else "A")
        if not online:
            self.reply(503)
        elif not packet or packet[0] <= after:
            self.reply(404)
        else:
            self.reply(200, packet[1], packet[0])

    def do_PUT(self):
        state = self.server.state
        if state.agora:
            self.close_connection = True
            self.reply(403)
            return
        peer = self.path.removeprefix("/presence/")
        count = int(self.headers.get("Content-Length", "0"))
        if peer not in ("A", "B") or not 0 < count <= 768:
            self.close_connection = True
            self.reply(400)
            return
        data = self.rfile.read(count)
        with state.lock:
            online = state.online
            if online:
                state.sequence += 1
                state.latest[peer] = (state.sequence, data)
                state.packets[peer] += 1
                state.maximum_bytes = max(state.maximum_bytes, count)
        self.reply(200 if online else 503)

    def do_POST(self):
        peer = self.path.removeprefix("/report/")
        count = int(self.headers.get("Content-Length", "0"))
        if peer not in ("A", "B") or not 0 < count <= 4096:
            self.close_connection = True
            self.reply(400)
            return
        value = json.loads(self.rfile.read(count))
        with self.server.state.lock:
            self.server.state.reports[peer] = value
        self.reply(200)


def clone_run(source, destination, peer, port, agora=False):
    root = str(source.resolve().parent)
    def rewrite(node):
        if isinstance(node, dict):
            result = {k: rewrite(v) for k, v in node.items()}
            if "TestBundlePath" in node:
                result.setdefault("EnvironmentVariables", {}).update(BOUND_PAIR_PEER=peer, BOUND_PAIR_PORT=str(port))
                if agora:
                    result["EnvironmentVariables"]["BOUND_PAIR_AGORA"] = "1"
            return result
        if isinstance(node, list):
            return [rewrite(v) for v in node]
        return node.replace("__TESTROOT__", root) if isinstance(node, str) else node
    destination.write_bytes(plistlib.dumps(rewrite(plistlib.loads(source.read_bytes()))))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xctestrun", required=True, type=Path)
    parser.add_argument("--sim-a", required=True)
    parser.add_argument("--sim-b", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--boundaries", action="store_true", help="Stationary peer / 3x native running across connected maps, then swap roles")
    parser.add_argument("--agora", action="store_true", help="Real authenticated Agora; requires one-use QA session fixtures. Loopback pose endpoints are disabled.")
    args = parser.parse_args()
    if args.boundaries and args.agora:
        parser.error("Boundary scenario currently uses the test-only presence relay")
    if args.sim_a == args.sim_b:
        parser.error("Two separate Simulators are required")
    args.output.mkdir(parents=True, exist_ok=False)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    state = server.state = State()
    state.agora = args.agora
    if args.boundaries:
        state.stage = "ready"
    threading.Thread(target=server.serve_forever, daemon=True).start()
    processes = []
    passed = False
    stages = []
    try:
        for peer, simulator in zip(("A", "B"), (args.sim_a, args.sim_b)):
            run = args.output / (peer + ".xctestrun")
            clone_run(args.xctestrun, run, peer, server.server_port, args.agora)
            log = (args.output / (peer + ".log")).open("wb")
            command = ["xcodebuild", "test-without-building", "-xctestrun", str(run),
                       "-destination", "platform=iOS Simulator,id=" + simulator,
                       "-parallel-testing-enabled", "NO", "-only-testing:BoundIntegrationTests/LivePresenceRuntimeTests/" + ("testConnectedBoundaryRunning" if args.boundaries else "testTwoVBAMInstancesExchangeLivePoses"),
                       "-resultBundlePath", str(args.output / (peer + ".xcresult"))]
            if args.agora or args.boundaries:
                # The native reports provide bounded connection evidence. Avoid
                # an unrelated verbose simulator diagnose blocking finalization;
                # native failures still produce a nonzero xcodebuild result.
                command += ["-collect-test-diagnostics", "never"]
            processes.append((subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT), log))

        def wait(stage, predicate, timeout=40):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                snapshot = state.snapshot()
                reports = snapshot["reports"]
                if all(reports.get(p, {}).get("stage") == stage and predicate(reports[p]) for p in ("A", "B")):
                    stages.append(snapshot)
                    print("Verified " + stage, flush=True)
                    return
                if any(p.poll() is not None for p, _ in processes):
                    raise RuntimeError("A test exited before " + stage)
                time.sleep(0.2)
            raise TimeoutError("Timed out at " + stage + ": " + json.dumps(state.snapshot()))

        if args.boundaries:
            wait("ready", lambda r: r["ready"], 120)
            for mover in ("A", "B"):
                if mover == "B":
                    state.change("reset")
                    wait("reset", lambda r: r["resetReady"], 30)
                stage = "run" + mover
                state.change(stage)
                wait(stage, lambda r: r["finished"] and r["frames"] > 60, 90)
                for report in state.snapshot()["reports"].values():
                    assert report["missingScenes"] == 0, report
                    assert report["missingProjectedPeers"] == 0, report
                    assert report["missingVisibleSprites"] == 0, report
                    assert report["missingPoseTicks"] == 0, report
                    assert report["clearVisibleFrames"] > 10, report
                    assert report["crossMapFrames"] > 10, report
                    if report["moving"]:
                        assert report["routeFrames"] > 10, report
                        assert report["stationaryWorldSpread"] <= 0.01, report
        else:
            wait("walk", lambda r: r["positions"] > 10 and r["visibleTicks"] > 40 and not r["hidden"], 120)
            # Keep walking long enough for both optional one-second diagnostic
            # samplers to observe native movement before testing interruptions.
            time.sleep(1.1)
            if args.agora:
                # Observe beyond the initial 120-second lease, with real renewals and
                # continuing visible native gameplay on both installations.
                after_expiry = time.monotonic() + 125
                wait("walk", lambda r: time.monotonic() >= after_expiry and not r["hidden"] and r["joined"] and r["tokenRenewals"] >= 2 and r["videoReceivedFrames"] > 30, 160)
            state.change("pauseA")
            wait("pauseA", lambda r: r["hidden"])
            state.change("resumed")
            wait("resumed", lambda r: not r["hidden"])
            state.change("offline", online=False)
            wait("offline", lambda r: r["hidden"])
            state.change("recovered")
            wait("recovered", lambda r: not r["hidden"] and (not args.agora or r["videoReceivedFrames"] > 30))
            state.change("restore")
            wait("restore", lambda r: not r["hidden"])
        state.change("done")
        for process, _ in processes:
            # Real SDK runs can take longer to finalize XCTest attachments and
            # simulator diagnostics after the native assertions have completed.
            deadline = time.monotonic() + (120 if args.agora else 40)
            while process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.2)
            if process.poll() is None:
                raise TimeoutError("Xcode test-result finalization exceeded its deadline")
            if process.returncode != 0:
                raise RuntimeError("Paired XCTest failed; inspect A.log and B.log")
        if args.agora:
            assert state.snapshot()["packets"] == {"A": 0, "B": 0}
        passed = True
        print("Two-instance VBA-M live presence passed (" + ("authenticated Agora" if args.agora else "test-only loopback transport") + ").", flush=True)
    finally:
        state.change("done")
        for process, log in processes:
            if process.poll() is None:
                process.terminate()
            log.close()
        limits = ("Real Agora on two hosted simulator game canvases; scripted disconnect/rejoin, not a network outage. No physical-device, separate-network or full app navigation proof." if args.agora else
                  "Loopback transport and hosted game canvas; no live Agora, Internet, full app navigation or physical-device proof.")
        (args.output / "summary.json").write_text(json.dumps(dict(passed=passed, stages=stages,
            final=state.snapshot(), limits=limits), indent=2) + "\n")
        server.shutdown(); server.server_close()


if __name__ == "__main__":
    main()
