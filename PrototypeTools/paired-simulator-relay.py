#!/usr/bin/env python3
"""Two-Simulator native-pixel relay. Loopback only; pixels stay in bounded memory.

Run --self-test, or --metadata-out /tmp/pair.json to start a manual relay.
The optional XCTest runner uses existing build output; it never builds or signs.
This verifies cross-instance app plumbing, not Agora encoding or Internet delivery.
"""
import argparse
from collections import deque
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import threading
import time
from urllib.error import HTTPError
from urllib.parse import parse_qs, urlsplit
from urllib.request import Request, urlopen

FRAME_BYTES = 240 * 160 * 4
PEERS = ("A", "B")
REPORT_FIELDS = {"peer", "epoch", "run", "generation", "reportSequence", "published", "publishedCounts", "presentedCounts", "lastPresentedSeq", "lastPresentedHash", "lastRemotePeer", "staleDrops", "canceledCallbacks", "visible"}
UI_FIELDS = {"peer", "stage", "orientation", "gameFrame", "friendFrame", "visible", "marker", "gameAspect", "friendAspect", "localHeight", "screenHeight", "validationPassed", "screenshot", "landscape", "notesOpen", "typesOpen"}


def bounded_value(value, depth=0):
    if depth > 3:
        raise ValueError("Metadata nesting too deep")
    if value is None or isinstance(value, bool):
        return value
    if isinstance(value, (int, float)) and math.isfinite(value):
        return value
    if isinstance(value, str) and len(value) <= 256:
        return value
    if isinstance(value, list) and len(value) <= 8:
        return [bounded_value(v, depth+1) for v in value]
    if isinstance(value, dict) and len(value) <= 12:
        return {str(k)[:40]: bounded_value(v, depth+1) for k, v in value.items()}
    raise ValueError("Invalid metadata value")


class RelayState:
    def __init__(self, presence_namespace=None, interaction_peers=PEERS):
        if not interaction_peers or not set(interaction_peers).issubset(PEERS):
            raise ValueError("Interaction peers must explicitly select A, B or both")
        self.lock = threading.RLock()
        self.epoch = 0
        self.online = True
        self.stage = "portrait"
        self.orientation = {p: "portrait" for p in PEERS}
        self.latest = {}
        self.presence_namespace = presence_namespace
        self.presence = {}
        self.presence_sequence = 0
        self.presence_counts = {peer: 0 for peer in PEERS}
        self.presence_producers = {peer: {} for peer in PEERS}
        self.host_ready = set()
        self.host_finished = set()
        self.interactions = {peer: deque() for peer in PEERS}
        self.interaction_peers = frozenset(interaction_peers)
        self.unrouted_interactions = {peer: 0 for peer in PEERS}
        self.interaction_sequence = 0
        self.interaction_counts = {peer: 0 for peer in PEERS}
        self.maximum_interactions = 0
        self.saved = None
        self.stale_peer = None
        self.stale_primed = False
        self.delay_next = 0.0
        self.reports = {}
        self.accepted_report_numbers = {}
        self.current_producers = {}
        self.producer_epochs = {}
        self.ui_reports = {}
        self.history = deque(maxlen=2048)
        self.publications = deque(maxlen=4096)
        self.counters = {"puts": 0, "gets": 0, "staleInjected": 0, "delayedAcksStarted": 0, "delayedAcksCompleted": 0, "crossPeerMatches": 0, "reportHashMismatches": 0, "maximumRetainedBuffers": 0}
        self.started = time.monotonic()

    def event(self, kind, **values):
        self.history.append({"event": kind, "elapsed": round(time.monotonic()-self.started, 3), "stage": self.stage, "epoch": self.epoch, **values})

    def buffers(self):
        count = len(self.latest) + int(self.saved is not None)
        assert count <= 2
        self.counters["maximumRetainedBuffers"] = max(count, self.counters["maximumRetainedBuffers"])

    def control(self, body):
        with self.lock:
            if "stage" in body:
                if body["stage"] not in ("portrait", "landscape", "offline", "background", "recovered", "done"):
                    raise ValueError("Invalid stage")
                self.stage = body["stage"]
            if "orientation" in body:
                for peer, value in body["orientation"].items():
                    if peer not in PEERS or value not in ("portrait", "landscape"):
                        raise ValueError("Invalid orientation")
                    self.orientation[peer] = value
            if "online" in body and bool(body["online"]) != self.online:
                requested = bool(body["online"])
                if not requested:
                    self.saved = self.latest.get("B") or self.latest.get("A")
                self.latest.clear()
                self.presence.clear()
                self.host_ready.clear()
                self.host_finished.clear()
                for queue in self.interactions.values():
                    queue.clear()
                self.epoch += 1
                self.online = requested
                self.stale_peer = None
                self.stale_primed = False
            if "delayNextPutSeconds" in body:
                delay = float(body["delayNextPutSeconds"])
                if not math.isfinite(delay) or not 0 <= delay <= 2:
                    raise ValueError("Invalid delay")
                self.delay_next = delay
            if body.get("injectStaleFor"):
                peer = body["injectStaleFor"]
                if peer not in PEERS or not self.saved or self.saved["peer"] == peer:
                    raise ValueError("No saved opposite-peer frame for stale injection")
                self.stale_peer = peer
                self.stale_primed = False
            self.buffers()
            self.event("control", online=self.online, orientation=dict(self.orientation))
            return self.status()

    def put(self, peer, sequence, run, epoch, pixels):
        with self.lock:
            if not self.online:
                return 503, 0.0
            if epoch != self.epoch:
                return 409, 0.0
            # Reserving one old-epoch buffer leaves only one current slot until
            # injection. Discard an older slot rather than grow a pixel queue.
            if self.saved and peer not in self.latest and self.latest:
                self.latest.clear()
            digest = hashlib.sha256(pixels).hexdigest()
            packet = {"peer": peer, "sequence": sequence, "run": run, "epoch": epoch, "hash": digest, "pixels": pixels}
            if self.current_producers.get(peer) != run:
                self.current_producers[peer] = run
                self.accepted_report_numbers.pop(peer, None)
            self.producer_epochs[peer] = epoch
            self.latest[peer] = packet
            metadata = {k: packet[k] for k in ("peer", "sequence", "run", "epoch", "hash")}
            self.publications.append(metadata)
            self.counters["puts"] += 1
            self.event("put", **metadata)
            delay, self.delay_next = self.delay_next, 0.0
            if delay:
                self.counters["delayedAcksStarted"] += 1
                self.event("delayedAckStart", peer=peer)
            self.buffers()
            return 200, delay

    def get(self, peer, after, run=""):
        with self.lock:
            self.counters["gets"] += 1
            if not self.online:
                return 503, None
            if self.stale_peer == peer:
                if not self.stale_primed:
                    # First announce the new epoch, THEN deliver the old packet;
                    # otherwise a client could legitimately still own old epoch.
                    self.stale_primed = True
                    return 404, None
                packet = self.saved
                self.saved = None; self.stale_peer = None
                self.counters["staleInjected"] += 1
                self.event("staleInjected", peer=peer, packetEpoch=packet["epoch"])
                return 200, packet
            opposite = "B" if peer == "A" else "A"
            packet = self.latest.get(opposite)
            if not packet or (packet["run"] == run and packet["sequence"] <= after):
                return 404, None
            return 200, packet

    def put_presence(self, namespace, peer, epoch, data, producer="unspecified"):
        with self.lock:
            if not self.presence_namespace or namespace != self.presence_namespace:
                return 403
            if not self.online:
                return 503
            if epoch != self.epoch:
                return 409
            # The fixture transports the unmodified shipping packet. Its peer
            # still owns codec, exact-ROM, epoch and sequence admission.
            if not 0 < len(data) <= 768:
                return 400
            if producer != "unspecified" and not re.fullmatch(r"[0-9A-Fa-f-]{36}", producer):
                return 400
            producers = self.presence_producers[peer]
            if producer not in producers and len(producers) >= 8:
                return 429
            producers[producer] = producers.get(producer, 0) + 1
            self.presence_sequence += 1
            self.presence[peer] = (self.presence_sequence, data)
            self.presence_counts[peer] += 1
            return 200

    def get_presence(self, namespace, peer, after):
        with self.lock:
            if not self.presence_namespace or namespace != self.presence_namespace:
                return 403, None
            if not self.online:
                return 503, None
            packet = self.presence.get("B" if peer == "A" else "A")
            return (200, packet) if packet and packet[0] > after else (404, None)

    def put_interaction(self, namespace, peer, epoch, data):
        with self.lock:
            if not self.presence_namespace or namespace != self.presence_namespace:
                return 403
            if not self.online:
                return 503
            if epoch != self.epoch:
                return 409
            if not 0 < len(data) <= 1024:
                return 400
            if peer not in self.interaction_peers:
                return 403
            recipient = "B" if peer == "A" else "A"
            if recipient not in self.interaction_peers:
                # An explicitly single-peer fixture has no receiving session.
                # Record send acceptance without retaining an undeliverable
                # ordered queue or inventing a peer/handshake acknowledgement.
                self.interaction_counts[peer] += 1
                self.unrouted_interactions[peer] += 1
                return 200
            queue = self.interactions[peer]
            if len(queue) >= 64:
                return 429
            self.interaction_sequence += 1
            queue.append((self.interaction_sequence, data))
            self.interaction_counts[peer] += 1
            self.maximum_interactions = max(self.maximum_interactions, len(queue))
            return 200

    def get_interaction(self, namespace, peer, after):
        with self.lock:
            if not self.presence_namespace or namespace != self.presence_namespace:
                return 403, None
            if not self.online:
                return 503, None
            if after < 0:
                return 400, None
            if peer not in self.interaction_peers:
                return 403, None
            queue = self.interactions["B" if peer == "A" else "A"]
            # The receiving fixture acknowledges only bytes already retained
            # in its bounded inbox; GET retries return the same next packet.
            while queue and queue[0][0] <= after:
                queue.popleft()
            return (200, queue[0]) if queue else (404, None)

    def report(self, peer, body, ui=False):
        with self.lock:
            fields = UI_FIELDS if ui else REPORT_FIELDS
            metadata = {k: bounded_value(v) for k, v in body.items() if k in fields}
            metadata["peer"] = peer
            if ui:
                if metadata.get("stage") != self.stage:
                    self.event("rejectedUIReport", peer=peer, reportStage=metadata.get("stage"))
                    return
                self.ui_reports[peer] = metadata
            else:
                report_epoch = metadata.get("epoch")
                report_number = metadata.get("reportSequence", 0)
                current_packet = self.latest.get(peer)
                if report_epoch != self.epoch or report_number <= self.accepted_report_numbers.get(peer, -1) or (self.producer_epochs.get(peer) == self.epoch and metadata.get("run") != self.current_producers.get(peer)):
                    self.event("rejectedReport", peer=peer, reportEpoch=report_epoch, reportSequence=report_number)
                    return
                self.accepted_report_numbers[peer] = report_number
                sequence, digest = metadata.get("lastPresentedSeq"), metadata.get("lastPresentedHash")
                sender = metadata.get("lastRemotePeer")
                if sequence and digest:
                    matched = sender in PEERS and sender != peer and any(p["peer"] == sender and p["sequence"] == sequence and p["hash"] == digest and p["epoch"] == metadata.get("epoch") for p in self.publications)
                    metadata["matchesOppositePublishedFrame"] = matched
                    self.counters["crossPeerMatches" if matched else "reportHashMismatches"] += 1
            target = self.ui_reports if ui else self.reports
            target[peer] = metadata
            self.event("report-ui" if ui else "report", **metadata)

    def status(self, history=False):
        with self.lock:
            result = {"epoch": self.epoch, "online": self.online, "stage": self.stage, "orientation": dict(self.orientation), "reports": dict(self.reports), "uiReports": dict(self.ui_reports), "counters": dict(self.counters), "elapsed": round(time.monotonic()-self.started, 3), "retainedFrameBuffers": len(self.latest)+int(self.saved is not None)}
            if history:
                result["history"] = list(self.history)
            result["presenceNamespace"] = self.presence_namespace
            result["presencePackets"] = dict(self.presence_counts)
            result["presenceProducers"] = {p: dict(ids) for p, ids in self.presence_producers.items()}
            result["retainedPresencePackets"] = len(self.presence)
            result["interactionPackets"] = dict(self.interaction_counts)
            result["interactionPeers"] = sorted(self.interaction_peers)
            result["unroutedInteractionPackets"] = dict(self.unrouted_interactions)
            result["retainedInteractionPackets"] = {p: len(q) for p, q in self.interactions.items()}
            result["maximumInteractionQueue"] = self.maximum_interactions
            return result


class RelayServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 16
    def __init__(self, state, port=0):
        self.state = state
        self.slots = threading.BoundedSemaphore(8)
        super().__init__(("127.0.0.1", port), RelayHandler)
    def process_request(self, request, address):
        self.slots.acquire()
        try:
            super().process_request(request, address)
        except Exception:
            self.slots.release()
            raise
    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.slots.release()


class RelayHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def log_message(self, *args):
        pass
    def setup(self):
        super().setup()
        self.connection.settimeout(3)
    def reply(self, code, data=b"", packet=None, presence=None, interaction=None):
        try:
            self._reply(code, data, packet, presence, interaction)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass # Cancellation is an intentional test stage, not a server failure.
    def _reply(self, code, data=b"", packet=None, presence=None, interaction=None):
        if isinstance(data, dict):
            data = json.dumps(data, sort_keys=True).encode()
        with self.server.state.lock:
            current = self.server.state.epoch
        self.send_response(code)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Content-Type", "application/octet-stream" if packet else "application/json")
        self.send_header("X-Epoch", str(packet["epoch"] if packet else current))
        self.send_header("X-Current-Epoch", str(current))
        if presence:
            self.send_header("X-Presence-Sequence", str(presence[0]))
            self.send_header("X-Peer", presence[1])
        if interaction:
            self.send_header("X-Interaction-Sequence", str(interaction[0]))
            self.send_header("X-Peer", interaction[1])
        if packet:
            for header, key in (("X-Sequence", "sequence"), ("X-Run", "run"), ("X-Peer", "peer"), ("X-Hash", "hash")):
                self.send_header(header, str(packet[key]))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass
    def body(self, maximum):
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 <= length <= maximum:
            raise ValueError("Invalid request size")
        data = self.rfile.read(length)
        if len(data) != length:
            raise ValueError("Incomplete request")
        return data
    def route(self):
        parsed = urlsplit(self.path)
        parts = parsed.path.strip("/").split("/")
        return parts, parsed
    def do_GET(self):
        try:
            parts, parsed = self.route()
            if parsed.path in ("/control/status", "/status"):
                return self.reply(200, self.server.state.status())
            if len(parts) == 3 and parts[0] in ("ready", "finished") and parts[2] in PEERS:
                with self.server.state.lock:
                    if not self.server.state.presence_namespace or parts[1] != self.server.state.presence_namespace:
                        return self.reply(403)
                    ready = sorted(self.server.state.host_ready if parts[0] == "ready" else self.server.state.host_finished)
                return self.reply(200, {"ready": ready})
            if len(parts) == 3 and parts[0] == "interaction" and parts[2] in PEERS:
                after = int(parse_qs(parsed.query).get("after", ["0"])[0])
                code, packet = self.server.state.get_interaction(parts[1], parts[2], after)
                return self.reply(code, packet[1] if packet else b"", interaction=(packet[0], "B" if parts[2] == "A" else "A") if packet else None)
            if len(parts) == 3 and parts[0] == "presence" and parts[2] in PEERS:
                after = int(parse_qs(parsed.query).get("after", ["0"])[0])
                code, packet = self.server.state.get_presence(parts[1], parts[2], after)
                return self.reply(code, packet[1] if packet else b"", presence=(packet[0], "B" if parts[2] == "A" else "A") if packet else None)
            if len(parts) != 2 or parts[0] != "frame" or parts[1] not in PEERS:
                return self.reply(404)
            query = parse_qs(parsed.query)
            after = int(query.get("after", ["0"])[0])
            run = query.get("run", [""])[0]
            code, packet = self.server.state.get(parts[1], after, run)
            self.reply(code, packet["pixels"] if packet else b"", packet)
        except (ValueError, TypeError, TimeoutError, ConnectionError):
            self.reply(400)
    def do_PUT(self):
        try:
            parts, _ = self.route()
            if len(parts) == 3 and parts[0] in ("ready", "finished") and parts[2] in PEERS:
                self.body(128)
                with self.server.state.lock:
                    if not self.server.state.presence_namespace or parts[1] != self.server.state.presence_namespace:
                        return self.reply(403)
                    target = self.server.state.host_ready if parts[0] == "ready" else self.server.state.host_finished
                    target.add(parts[2])
                return self.reply(200)
            if len(parts) == 3 and parts[0] == "interaction" and parts[2] in PEERS:
                data = self.body(1024)
                epoch = int(self.headers.get("X-Epoch", "-1"))
                return self.reply(self.server.state.put_interaction(parts[1], parts[2], epoch, data))
            if len(parts) == 3 and parts[0] == "presence" and parts[2] in PEERS:
                data = self.body(768)
                epoch = int(self.headers.get("X-Epoch", "-1"))
                return self.reply(self.server.state.put_presence(parts[1], parts[2], epoch, data, self.headers.get("X-Producer", "unspecified")))
            if len(parts) != 2 or parts[0] != "frame" or parts[1] not in PEERS:
                return self.reply(404)
            pixels = self.body(FRAME_BYTES)
            if len(pixels) != FRAME_BYTES:
                return self.reply(400)
            sequence = int(self.headers.get("X-Sequence", "0"))
            epoch = int(self.headers.get("X-Epoch", "-1"))
            run = self.headers.get("X-Run", "")
            if not 0 < sequence <= 2**64-1 or not re.fullmatch(r"[A-Za-z0-9-]{1,128}", run):
                return self.reply(400)
            code, delay = self.server.state.put(parts[1], sequence, run, epoch, pixels)
            del pixels
            if delay:
                time.sleep(delay)
                with self.server.state.lock:
                    self.server.state.counters["delayedAcksCompleted"] += 1
                    self.server.state.event("delayedAckCompleted", peer=parts[1])
            self.reply(code)
        except (ValueError, TypeError, TimeoutError, ConnectionError):
            self.reply(400)
    def do_POST(self):
        try:
            parts, parsed = self.route()
            body = json.loads(self.body(16384))
            if not isinstance(body, dict):
                raise ValueError("Object required")
            if parsed.path == "/control":
                return self.reply(200, self.server.state.control(body))
            if len(parts) == 2 and parts[0] in ("report", "report-ui") and parts[1] in PEERS:
                self.server.state.report(parts[1], body, parts[0] == "report-ui")
                return self.reply(200)
            self.reply(404)
        except (ValueError, TypeError, AttributeError, TimeoutError, ConnectionError):
            self.reply(400)


def call(port, path, body=None, method=None, headers=None):
    data = json.dumps(body).encode() if isinstance(body, dict) else body
    request = Request(f"http://127.0.0.1:{port}{path}", data=data, method=method or ("POST" if body is not None else "GET"), headers=headers or {})
    try:
        with urlopen(request, timeout=4) as response:
            return response.status, dict(response.headers), response.read()
    except HTTPError as error:
        return error.code, dict(error.headers), error.read()


def self_test():
    state = RelayState("00000000-0000-0000-0000-000000000001"); server = RelayServer(state)
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    port = server.server_port
    try:
        lane = "/presence/00000000-0000-0000-0000-000000000001/"
        assert call(port, lane+"A")[0] == 404
        producer = "00000000-0000-0000-0000-000000000002"
        assert call(port, lane+"B", b"fixture-packet", "PUT", {"X-Epoch":"0", "X-Producer":producer})[0] == 200
        assert state.presence_producers["B"] == {producer: 1}
        code, headers, packet = call(port, lane+"A")
        assert code == 200 and packet == b"fixture-packet" and headers["X-Peer"] == "B"
        assert call(port, lane+"A?after="+headers["X-Presence-Sequence"])[0] == 404
        assert call(port, lane+"B")[0] == 404
        assert call(port, lane+"A", b"x"*769, "PUT", {"X-Epoch":"0"})[0] == 400
        assert call(port, "/presence/wrong/A", b"x", "PUT", {"X-Epoch":"0"})[0] == 403
        control_lane = lane.replace("/presence/", "/interaction/")
        assert call(port, control_lane+"A")[0] == 404
        assert call(port, "/interaction/wrong/B", b"BMR1", "PUT", {"X-Epoch":"0"})[0] == 403
        assert call(port, control_lane+"B", b"x"*1025, "PUT", {"X-Epoch":"0"})[0] == 400
        assert call(port, control_lane+"B", b"BMR1", "PUT", {"X-Epoch":"1"})[0] == 409
        assert call(port, control_lane+"A?after=-1")[0] == 400
        for index in range(64):
            assert call(port, control_lane+"B", b"BMR1"+bytes([index]), "PUT", {"X-Epoch":"0"})[0] == 200
        assert call(port, control_lane+"B", b"BMR1-full", "PUT", {"X-Epoch":"0"})[0] == 429
        assert call(port, control_lane+"B")[0] == 404  # No self-delivery.
        cursor = 0
        for index in range(64):
            code, headers, packet = call(port, control_lane+"A?after="+str(cursor))
            assert code == 200 and packet == b"BMR1"+bytes([index]) and headers["X-Peer"] == "B"
            assert call(port, control_lane+"A?after="+str(cursor))[2] == packet  # Retry before ACK.
            cursor = int(headers["X-Interaction-Sequence"])
        assert call(port, control_lane+"A?after="+str(cursor))[0] == 404
        assert not state.interactions["B"] and state.maximum_interactions == 64
        single = RelayState(state.presence_namespace, interaction_peers=("A",))
        for _ in range(256):
            assert single.put_interaction(state.presence_namespace, "A", 0, b"BMR1") == 200
        assert single.interaction_counts == {"A": 256, "B": 0}
        assert single.unrouted_interactions == {"A": 256, "B": 0}
        assert not any(single.interactions.values()) and single.maximum_interactions == 0
        assert single.get_interaction(state.presence_namespace, "A", 0) == (404, None)
        assert single.get_interaction(state.presence_namespace, "B", 0) == (403, None)
        assert single.put_interaction(state.presence_namespace, "B", 0, b"BMR1") == 403
        assert single.put_interaction("wrong", "A", 0, b"BMR1") == 403
        assert single.put_interaction(state.presence_namespace, "A", 1, b"BMR1") == 409
        single.online = False
        assert single.put_interaction(state.presence_namespace, "A", 0, b"BMR1") == 503
        assert single.status()["interactionPeers"] == ["A"]
        for phase in ("ready", "finished"):
            route = lane.replace("/presence/", "/"+phase+"/")
            assert call(port, route+"A", b"", "PUT")[0] == 200
            assert json.loads(call(port, route+"B")[2])["ready"] == ["A"]
            assert call(port, route+"B", b"", "PUT")[0] == 200
            assert json.loads(call(port, route+"A")[2])["ready"] == ["A", "B"]
        pixels = bytes([19, 31, 41, 255]) * (240*160)
        headers = {"X-Sequence": "1", "X-Run": "self-test-B", "X-Epoch": "0"}
        assert call(port, "/frame/B", pixels, "PUT", headers)[0] == 200
        code, got, data = call(port, "/frame/A?after=0")
        assert code == 200 and data == pixels and got["X-Peer"] == "B"
        assert got["X-Hash"] == hashlib.sha256(pixels).hexdigest()
        assert call(port, "/frame/B?after=0")[0] == 404
        assert call(port, "/frame/A?after=1&run=self-test-B")[0] == 404
        assert call(port, "/frame/A", b"bad", "PUT", headers)[0] == 400
        call(port, "/report/A", {"epoch": 0, "reportSequence": 1, "lastPresentedSeq": 1, "lastPresentedHash": got["X-Hash"], "lastRemotePeer": "B"})
        assert state.reports["A"]["matchesOppositePublishedFrame"]
        call(port, "/report/A", {"epoch": 0, "reportSequence": 0, "visible": False})
        assert state.reports["A"]["matchesOppositePublishedFrame"]
        call(port, "/frame/A", pixels, "PUT", {"X-Sequence": "1", "X-Run": "self-test-A", "X-Epoch": "0"})
        assert state.counters["maximumRetainedBuffers"] == 2
        call(port, "/control", {"online": False, "stage": "offline"})
        assert not state.host_ready and not state.host_finished and not any(state.interactions.values())
        code, got, _ = call(port, "/frame/A?after=1")
        assert code == 503 and got["X-Epoch"] == "1"
        call(port, "/control", {"online": True, "stage": "recovered", "injectStaleFor": "A"})
        code, got, _ = call(port, "/frame/A?after=0")
        assert code == 404 and got["X-Epoch"] == "2"
        code, got, data = call(port, "/frame/A?after=0")
        assert code == 200 and got["X-Epoch"] == "0" and got["X-Current-Epoch"] == "2" and data == pixels
        assert call(port, "/frame/A?after=0")[0] == 404
        call(port, "/report/A", {"epoch": 0, "reportSequence": 99, "visible": True})
        assert state.reports["A"].get("epoch") == 0  # Older accepted report retained, never mislabeled fresh.
        assert any(e["event"] == "rejectedReport" for e in state.history)
        call(port, "/control", {"delayNextPutSeconds": 1.5})
        started = time.monotonic()
        headers["X-Epoch"] = "2"; headers["X-Sequence"] = "2"
        assert call(port, "/frame/B", pixels, "PUT", headers)[0] == 200
        assert time.monotonic() - started >= 1.45
        # A new producer run must deliver sequence1 even after a larger prior sequence.
        headers["X-Run"] = "replacement-B"; headers["X-Sequence"] = "1"
        assert call(port, "/frame/B", pixels, "PUT", headers)[0] == 200
        assert call(port, "/frame/A?after=999&run=self-test-B")[0] == 200
        assert call(port, "/frame/A?after=1&run=replacement-B")[0] == 404
        assert state.counters["staleInjected"] == 1
        assert state.counters["maximumRetainedBuffers"] <= 2
        print("Relay self-test passed: opposite-peer presence/control/video, ordered control retry/ACK, bounded queues, explicit absent recipient, start/finish barriers, epochs, stale injection and delayed ACK.")
    finally:
        server.shutdown(); server.server_close()


def write_summary(path, state, **extra):
    if path:
        Path(path).write_text(json.dumps({**state.status(history=True), **extra}, indent=2, sort_keys=True)+"\n")


def clone_run(source, output, peer, port):
    data = plistlib.loads(Path(source).read_bytes())
    test_root = str(Path(source).resolve().parent)
    def paths(node):
        if isinstance(node, dict):
            return {k: paths(v) for k, v in node.items()}
        if isinstance(node, list):
            return [paths(v) for v in node]
        return node.replace("__TESTROOT__", test_root) if isinstance(node, str) else node
    data = paths(data)
    env = {"BOUND_PAIR_PEER": peer, "BOUND_PAIR_PORT": str(port), "TEST_RUNNER_BOUND_PAIR_PEER": peer, "TEST_RUNNER_BOUND_PAIR_PORT": str(port)}
    def visit(node):
        if isinstance(node, dict):
            # Legacy and version2 xctestrun test-target dictionaries both have TestBundlePath.
            if "TestBundlePath" in node:
                for key in ("EnvironmentVariables", "UITargetAppEnvironmentVariables"):
                    node.setdefault(key, {}).update(env)
            for value in list(node.values()):
                visit(value)
        elif isinstance(node, list):
            for value in node:
                visit(value)
    visit(data)
    Path(output).write_bytes(plistlib.dumps(data))


def run_pair(args, server):
    state = server.state
    if args.sim_a == args.sim_b:
        raise ValueError("Two distinct dedicated Simulators are required")
    output = Path(args.run_directory); output.mkdir(parents=True, exist_ok=True)
    processes = []
    started = time.monotonic()
    failure = None
    try:
        for peer, device in zip(PEERS, (args.sim_a, args.sim_b)):
            run = output / (peer + ".xctestrun")
            clone_run(args.xctestrun, run, peer, server.server_port)
            log = (output / (peer + ".log")).open("wb")
            command = ["xcodebuild", "test-without-building", "-xctestrun", str(run), "-destination", "platform=iOS Simulator,id="+device, "-parallel-testing-enabled", "NO", "-only-testing:"+args.test_id, "-resultBundlePath", str(output/(peer+".xcresult"))]
            processes.append((peer, subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT), log))
        def wait_until(predicate, name, seconds=45):
            deadline = min(started+args.timeout, time.monotonic()+seconds)
            while time.monotonic() < deadline:
                if predicate(state.status()):
                    print("Verified " + name + ".", flush=True)
                    return
                if any(p.poll() is not None for _, p, _ in processes):
                    raise RuntimeError("XCTest exited before " + name)
                time.sleep(0.25)
            raise TimeoutError("Timed out waiting for " + name)
        def frames_and_ui(stage):
            return lambda status: all(status["reports"].get(p, {}).get("epoch") == status["epoch"] and status["reports"].get(p, {}).get("visible") and status["reports"].get(p, {}).get("matchesOppositePublishedFrame") and status["uiReports"].get(p, {}).get("stage") == stage for p in PEERS)
        wait_until(frames_and_ui("portrait"), "portrait cross-instance pixels and UI", 75)
        state.control({"stage": "landscape", "orientation": {p: "landscape" for p in PEERS}})
        wait_until(frames_and_ui("landscape"), "landscape cross-instance pixels and UI")
        state.control({"delayNextPutSeconds": 1.5})
        wait_until(lambda s: s["counters"]["delayedAcksStarted"] >= 1, "in-flight delayed ACK", 10)
        state.control({"online": False, "stage": "offline"})
        wait_until(lambda s: all(s["reports"].get(p, {}).get("epoch") == s["epoch"] and s["reports"].get(p, {}).get("visible") is False and s["uiReports"].get(p, {}).get("stage") == "offline" for p in PEERS), "offline cleared canvases", 20)
        state.control({"stage": "background"})
        wait_until(lambda s: all(s["uiReports"].get(p, {}).get("stage") == "background" for p in PEERS), "offline background/resume on both apps", 20)
        state.control({"online": True, "stage": "recovered", "injectStaleFor": "A"})
        wait_until(lambda s: frames_and_ui("recovered")(s) and s["reports"].get("A", {}).get("staleDrops", 0) >= 1 and sum(s["reports"].get(p, {}).get("canceledCallbacks", 0) for p in PEERS) >= 1, "recovery, stale rejection and canceled completion")
        state.control({"stage": "done"})
        for peer, process, _ in processes:
            if process.wait(timeout=max(1, started+args.timeout-time.monotonic())) != 0:
                raise RuntimeError(peer + " XCTest failed")
        print("Paired Simulator native-frame/lifecycle/UI verification passed.")
    except Exception as error:
        failure = str(error)
        state.control({"stage": "done"})
        raise
    finally:
        for _, process, log in processes:
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
            log.close()
        write_summary(args.metadata_out, state, passed=failure is None, failure=failure, simulatorLimits="Loopback raw RGBA fixture; no Agora codec, Internet signaling, microphone, accounts or physical scanout verified.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--metadata-out", default="/tmp/bound-pair-summary.json")
    parser.add_argument("--presence-namespace", help="Explicit task UUID for the optional bounded presence lane")
    parser.add_argument("--xctestrun")
    parser.add_argument("--sim-a")
    parser.add_argument("--sim-b")
    parser.add_argument("--test-id", default="BoundCompanionUITests/PairedFriendUITests/testNativeFramesAcrossLocalPeer")
    parser.add_argument("--run-directory", default="/tmp/bound-pair-run")
    parser.add_argument("--timeout", type=float, default=240)
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if args.xctestrun and not (args.sim_a and args.sim_b):
        parser.error("--xctestrun needs --sim-a and --sim-b")
    if args.presence_namespace and not re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", args.presence_namespace):
        parser.error("--presence-namespace must be a task UUID")
    state = RelayState(args.presence_namespace.upper() if args.presence_namespace else None); server = RelayServer(state, args.port)
    print(json.dumps({"url": "http://127.0.0.1:"+str(server.server_port), "port": server.server_port, "pixelsWrittenToDisk": False}), flush=True)
    try:
        if args.xctestrun:
            threading.Thread(target=server.serve_forever, daemon=True).start()
            run_pair(args, server)
        else:
            server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        if args.xctestrun:
            server.shutdown()
        server.server_close()
        if not args.xctestrun:
            write_summary(args.metadata_out, state)


if __name__ == "__main__":
    main()
