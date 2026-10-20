"""Two-process VBA-M presence acceptance harness; loopback only, no credentials.

Requires an already built BoundIntegrationQA xctestrun and two dedicated booted
Simulators with the private ROM/seed fixtures from Docs/BOUND-MULTIPLAYER.md.
The relay retains only the latest <=768-byte packet for each peer. Output is
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


def clone_run(source, destination, peer, port):
    root = str(source.resolve().parent)
    def rewrite(node):
        if isinstance(node, dict):
            result = {k: rewrite(v) for k, v in node.items()}
            if "TestBundlePath" in node:
                result.setdefault("EnvironmentVariables", {}).update(BOUND_PAIR_PEER=peer, BOUND_PAIR_PORT=str(port))
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
    args = parser.parse_args()
    if args.sim_a == args.sim_b:
        parser.error("Two separate Simulators are required")
    args.output.mkdir(parents=True, exist_ok=False)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    state = server.state = State()
    threading.Thread(target=server.serve_forever, daemon=True).start()
    processes = []
    passed = False
    stages = []
    try:
        for peer, simulator in zip(("A", "B"), (args.sim_a, args.sim_b)):
            run = args.output / (peer + ".xctestrun")
            clone_run(args.xctestrun, run, peer, server.server_port)
            log = (args.output / (peer + ".log")).open("wb")
            command = ["xcodebuild", "test-without-building", "-xctestrun", str(run),
                       "-destination", "platform=iOS Simulator,id=" + simulator,
                       "-parallel-testing-enabled", "NO", "-only-testing:BoundIntegrationTests/LivePresenceRuntimeTests",
                       "-resultBundlePath", str(args.output / (peer + ".xcresult"))]
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

        wait("walk", lambda r: r["positions"] > 10 and r["visibleTicks"] > 40 and not r["hidden"], 120)
        state.change("pauseA")
        wait("pauseA", lambda r: r["hidden"])
        state.change("resumed")
        wait("resumed", lambda r: not r["hidden"])
        state.change("offline", online=False)
        wait("offline", lambda r: r["hidden"])
        state.change("recovered")
        wait("recovered", lambda r: not r["hidden"])
        state.change("restore")
        wait("restore", lambda r: not r["hidden"])
        state.change("done")
        for process, _ in processes:
            if process.wait(timeout=40) != 0:
                raise RuntimeError("Paired XCTest failed; inspect A.log and B.log")
        passed = True
        print("Two-instance VBA-M live presence passed (test-only loopback transport).", flush=True)
    finally:
        state.change("done")
        for process, log in processes:
            if process.poll() is None:
                process.terminate()
            log.close()
        (args.output / "summary.json").write_text(json.dumps(dict(passed=passed, stages=stages,
            final=state.snapshot(), limits="Loopback transport and hosted game canvas; no live Agora, Internet, full app navigation or physical-device proof."), indent=2) + "\n")
        server.shutdown(); server.server_close()


if __name__ == "__main__":
    main()
