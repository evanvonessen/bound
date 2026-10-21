#!/usr/bin/env python3
"""Run real Dropbox acceptance tests on dedicated, already signed-in simulators.

Build BoundIntegrationQA for testing first. Install and open the normal Bound app
on two fresh simulators named 'Bound Dropbox QA ...', then sign in to the same
Bound account separately on each. Leave Dropbox syncing disabled. --link-only
opens native Dropbox consent on A; --pair proves consent-free restoration and a
Harmony ROM/save round trip between A and B using the linked account.

Only nonsecret, one-use test metadata is written to those app containers. The
native tests read their own saved sessions; this tool never reads Keychain or
accepts passwords/tokens. The loopback relay carries bounded fingerprints and
stages only. Child logs and results stay under the repository's ignored .build.
The native tests remove their generated records and unique remote QA folder;
neither this tool nor the tests unlink the account's Dropbox grant.
"""

import argparse
import copy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import threading
import time
import uuid


ROOT = Path(__file__).resolve().parents[1]
BUNDLE = "com.evanvonessen.bound"
FIXTURE = "BoundDropboxLiveSyncQA.json"
SELECTORS = {
    "link": "BoundIntegrationTests/BoundDropboxLiveSyncTests/testLinkDropboxUsingNativeConsent",
    "pair": "BoundIntegrationTests/BoundDropboxLiveSyncTests/testLiveTwoDeviceBrokerAndHarmonySaveRestore",
}
STAGES = {"link": {"A": ["linked"]},
          "pair": {"A": ["uploaded", "restored", "cleaned"], "B": ["updated", "finished"]}}
FINGERPRINT = re.compile(r"[0-9a-f]{64}\Z")


class Failure(Exception):
    """Fixed safe diagnostics only; never include a response or child output."""


def simctl(*arguments):
    try:
        result = subprocess.run(["xcrun", "simctl", *arguments], capture_output=True,
                                text=True, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise Failure("Simulator command unavailable or timed out") from None
    if result.returncode:
        raise Failure("Simulator command failed; verify the explicitly selected devices")
    return result.stdout.strip()


def validate_devices(identifiers):
    if len(set(identifiers)) != len(identifiers):
        raise Failure("Two distinct simulator IDs are required")
    try:
        if any(str(uuid.UUID(value)).lower() != value.lower() for value in identifiers):
            raise ValueError()
    except ValueError:
        raise Failure("Simulator IDs must be UUIDs") from None
    try:
        inventory = json.loads(simctl("list", "devices", "available", "--json"))
        devices = {item["udid"].lower(): item
                   for group in inventory["devices"].values() for item in group}
    except (KeyError, TypeError, ValueError):
        raise Failure("Could not validate simulator inventory") from None
    containers = {}
    for role, identifier in zip(("A", "B"), identifiers):
        device = devices.get(identifier.lower(), {})
        if not device.get("name", "").startswith("Bound Dropbox QA ") or device.get("state") != "Booted":
            raise Failure("Use booted, fresh simulators named 'Bound Dropbox QA ...'")
        app = Path(simctl("get_app_container", identifier, BUNDLE, "app"))
        try:
            info = plistlib.loads((app / "Info.plist").read_bytes())
        except (OSError, ValueError, plistlib.InvalidFileException):
            raise Failure("The normal Bound app must already be installed on each simulator") from None
        if info.get("CFBundleIdentifier") != BUNDLE:
            raise Failure("Unexpected app bundle on selected simulator")
        data = Path(simctl("get_app_container", identifier, BUNDLE, "data"))
        documents = data / "Documents"
        if not documents.is_dir() or documents.is_symlink():
            raise Failure("Open the normal Bound app before running this test")
        fixture = documents / FIXTURE
        if fixture.exists() or fixture.is_symlink():
            raise Failure("A QA fixture already exists; remove it from this disposable simulator before retrying")
        containers[role] = documents
    return containers


class State:
    def __init__(self, mode, run_id):
        self.mode = mode
        self.run_id = run_id
        self.lock = threading.Lock()
        self.reports = {}
        self.history = []
        self.requests = 0
        self.aborted = False

    def request_allowed(self):
        with self.lock:
            self.requests += 1
            return self.requests <= 20000

    def publish(self, role, report):
        fields = {"runID", "stage", "ownerFingerprint", "sessionFingerprint", "connectionFingerprint"}
        if not isinstance(report, dict) or set(report) != fields:
            return False
        if (not isinstance(report["runID"], str) or report["runID"].lower() != self.run_id
                or role not in STAGES[self.mode] or not isinstance(report["stage"], str)
                or any(not isinstance(report[key], str) or not FINGERPRINT.fullmatch(report[key])
                       for key in ("ownerFingerprint", "sessionFingerprint", "connectionFingerprint"))):
            return False
        with self.lock:
            prior = self.reports.get(role)
            stages = STAGES[self.mode][role]
            expected = stages[0] if prior is None else (
                stages[stages.index(prior["stage"]) + 1] if prior["stage"] in stages[:-1] else None)
            if self.aborted or report["stage"] not in (expected, "failed"):
                return False
            if prior and any(prior[key] != report[key] for key in ("ownerFingerprint", "sessionFingerprint")):
                return False
            if (prior and report["stage"] != "failed"
                    and prior["connectionFingerprint"] != report["connectionFingerprint"]):
                return False
            self.reports[role] = dict(report)
            self.history.append({"role": role, "stage": report["stage"]})
            return True

    def snapshot(self):
        with self.lock:
            return {"reports": copy.deepcopy(self.reports)}

    def abort(self):
        with self.lock:
            self.aborted = True
            for role in STAGES[self.mode]:
                report = self.reports.get(role, {"runID": self.run_id,
                    "ownerFingerprint": "0" * 64, "sessionFingerprint": "0" * 64,
                    "connectionFingerprint": "0" * 64})
                self.reports[role] = dict(report, stage="failed")

    def verified(self):
        with self.lock:
            if any(self.reports.get(role, {}).get("stage") != stages[-1]
                   for role, stages in STAGES[self.mode].items()):
                return False
            if self.mode == "link":
                return self.reports["A"]["connectionFingerprint"] != "0" * 64
            a, b = self.reports["A"], self.reports["B"]
            return (a["ownerFingerprint"] == b["ownerFingerprint"]
                    and a["sessionFingerprint"] != b["sessionFingerprint"]
                    and a["connectionFingerprint"] == b["connectionFingerprint"]
                    and all(value != "0" * 64 for report in (a, b)
                            for key, value in report.items() if key.endswith("Fingerprint")))

    def public_summary(self):
        with self.lock:
            return {"stages": list(self.history), "relayRequests": self.requests}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        self.connection.settimeout(5)

    def log_message(self, *_):
        pass

    def reply(self, code, value=None):
        body = b"" if value is None else json.dumps(value, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass

    def do_GET(self):
        if not self.server.state.request_allowed():
            self.reply(429)
        elif self.path != "/status":
            self.reply(404)
        else:
            self.reply(200, self.server.state.snapshot())

    def do_POST(self):
        if not self.server.state.request_allowed():
            self.reply(429)
            return
        if self.path not in ("/report/A", "/report/B") or self.headers.get("Transfer-Encoding"):
            self.reply(400)
            return
        try:
            count = int(self.headers.get("Content-Length", "0"))
            if not 0 < count <= 8192:
                raise ValueError()
            data = self.rfile.read(count)
            if len(data) != count:
                raise ValueError()
            report = json.loads(data)
            accepted = self.server.state.publish(self.path[-1], report)
        except (ValueError, UnicodeError, OSError):
            self.reply(400)
            return
        self.reply(200 if accepted else 400)


class RelayServer(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        # HTTP parsing errors must not print submitted report bodies.
        pass


def clone_run(source, destination, mode):
    test_root = str(source.parent)
    targets = 0

    def rewrite(node):
        nonlocal targets
        if isinstance(node, dict):
            result = {key: rewrite(value) for key, value in node.items()}
            if "TestBundlePath" in node and "BoundIntegrationTests.xctest" in str(node["TestBundlePath"]):
                targets += 1
                # Isolate these tests even if the source run includes other suites.
                result["OnlyTestIdentifiers"] = [SELECTORS[mode].split("/", 1)[1]]
            return result
        if isinstance(node, list):
            return [rewrite(value) for value in node]
        return node.replace("__TESTROOT__", test_root) if isinstance(node, str) else node

    try:
        cloned = rewrite(plistlib.loads(source.read_bytes()))
    except (OSError, ValueError, plistlib.InvalidFileException):
        raise Failure("Could not read the supplied xctestrun") from None
    if targets == 0:
        raise Failure("The supplied xctestrun does not contain BoundIntegrationTests")
    destination.write_bytes(plistlib.dumps(cloned))
    destination.chmod(0o600)


def stop_children(children):
    for child, _ in children:
        if child.poll() is None:
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
    deadline = time.monotonic() + 10
    for child, _ in children:
        try:
            child.wait(timeout=max(0.1, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait(timeout=10)
    for _, log in children:
        log.close()


def run(args, mode, run_id, output, containers):
    server = RelayServer(("127.0.0.1", 0), Handler)
    state = server.state = State(mode, run_id)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    children = []
    fixtures = []
    passed = False
    error = None
    interrupted = False
    try:
        for role, simulator in zip(STAGES[mode], (args.sim_a, args.sim_b)):
            fixture = containers[role] / FIXTURE
            metadata = {"mode": mode, "disposableSimulator": True, "runID": run_id, "role": role,
                "folderName": "Bound Dropbox QA " + run_id,
                "relayURL": "http://127.0.0.1:" + str(server.server_port)}
            # Exclusive creation protects preexisting metadata; no session secrets.
            descriptor = os.open(fixture, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "w") as stream:
                json.dump(metadata, stream)
            fixtures.append(fixture)
            cloned = output / (role + ".xctestrun")
            clone_run(args.xctestrun, cloned, mode)
            log = (output / (role + ".log")).open("xb")
            command = ["xcodebuild", "test-without-building", "-xctestrun", str(cloned),
                "-destination", "platform=iOS Simulator,id=" + simulator,
                "-parallel-testing-enabled", "NO", "-only-testing:" + SELECTORS[mode],
                "-collect-test-diagnostics", "never", "-resultBundlePath", str(output / (role + ".xcresult"))]
            try:
                child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            except OSError:
                log.close()
                raise Failure("Could not start Xcode test execution") from None
            children.append((child, log))
        deadline = time.monotonic() + args.timeout
        seen = 0
        while time.monotonic() < deadline:
            history = state.public_summary()["stages"]
            for report in history[seen:]:
                print("Device " + report["role"] + ": " + report["stage"], flush=True)
            seen = len(history)
            if any(report["stage"] == "failed" for report in history):
                raise Failure("A native test failed; cleanup was requested on both peers")
            results = [child.poll() for child, _ in children]
            if any(result is not None and result != 0 for result in results):
                raise Failure("Xcode test execution failed; inspect the ignored child result logs")
            if all(result is not None for result in results):
                if not state.verified():
                    raise Failure("Native tests did not provide complete matching account and distinct-session evidence")
                passed = True
                break
            time.sleep(0.25)
        if not passed:
            raise Failure("Live acceptance test exceeded its bounded deadline")
    except KeyboardInterrupt:
        interrupted = True
        error = "Interrupted; native cleanup requested"
    except (Failure, OSError) as failure:
        error = str(failure) if isinstance(failure, Failure) else "Local test setup or output failed"
    finally:
        if not passed:
            state.abort()
            # Peers observe failed status and attempt their scoped cleanup before
            # the coordinator ends child process groups. No remote cleanup here.
            deadline = time.monotonic() + 15
            while any(child.poll() is None for child, _ in children) and time.monotonic() < deadline:
                time.sleep(0.25)
        stop_children(children)
        for fixture in fixtures:
            try:
                if fixture.is_file() and not fixture.is_symlink():
                    value = json.loads(fixture.read_bytes())
                    if value.get("runID") == run_id:
                        fixture.unlink()
            except (OSError, ValueError, AttributeError):
                pass
        summary = {"passed": passed, "mode": mode, "runID": run_id,
            **state.public_summary(), "childExitCodes": [child.returncode for child, _ in children],
            "accountMatches": passed if mode == "pair" else None,
            "distinctSessions": passed if mode == "pair" else None,
            "sameDropboxConnection": passed if mode == "pair" else None,
            "remoteCleanupConfirmed": passed if mode == "pair" else None,
            "limits": ("Two native simulator installations over this Mac's network; physical devices, separate networks and full app navigation are not verified."
                       if mode == "pair" else "Native linking on one simulator only; two-device syncing and physical devices are not verified by this phase.")}
        if error:
            summary["error"] = error
        (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        server.shutdown()
        server.server_close()
    if error:
        print(error, file=sys.stderr)
    return 0 if passed else (130 if interrupted else 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--xctestrun", required=True, type=Path, help="Existing BoundIntegrationQA build-for-testing result")
    parser.add_argument("--sim-a", required=True, help="Dedicated booted simulator UUID; sign in through normal Bound first")
    parser.add_argument("--sim-b", help="Second dedicated simulator UUID, with a separate sign-in to the same Bound account")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--link-only", action="store_true", help="Open native Dropbox consent on A; requires interactive consent")
    mode.add_argument("--pair", action="store_true", help="Prove two-device broker restoration and Harmony ROM/save round trip")
    parser.add_argument("--output", type=Path, help="New output directory inside this repository's ignored .build")
    parser.add_argument("--timeout", type=int, help="Overall seconds (60–1800); defaults to 660 for link, 900 for pair")
    args = parser.parse_args()
    selected_mode = "link" if args.link_only else "pair"
    if args.pair and not args.sim_b:
        parser.error("--pair requires --sim-b")
    if args.link_only and args.sim_b:
        parser.error("--link-only uses only --sim-a")
    args.timeout = args.timeout if args.timeout is not None else (660 if args.link_only else 900)
    if not 60 <= args.timeout <= 1800:
        parser.error("--timeout must be between 60 and 1800 seconds")
    run_id = str(uuid.uuid4())
    try:
        args.xctestrun = args.xctestrun.resolve(strict=True)
        if not args.xctestrun.is_file() or args.xctestrun.suffix != ".xctestrun":
            raise Failure("--xctestrun must identify an existing test-run file")
        output = (args.output or ROOT / ".build" / "dropbox-live-sync" / run_id).resolve()
        if not output.is_relative_to((ROOT / ".build").resolve()):
            raise Failure("Output must remain under this repository's ignored .build directory")
        identifiers = [args.sim_a] + ([args.sim_b] if args.sim_b else [])
        containers = validate_devices(identifiers)
        output.mkdir(parents=True, exist_ok=False)
        output.chmod(0o700)
        return run(args, selected_mode, run_id, output, containers)
    except Failure as failure:
        print("Preflight failed: " + str(failure), file=sys.stderr)
        return 1
    except (OSError, ValueError):
        print("Preflight failed: require a valid xctestrun and unused .build output directory", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
