#!/usr/bin/env python3
"""Archive a published Bound revision and optionally upload it for internal testing."""

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
REMOTE_URLS = {
    "https://github.com/evanvonessen/bound.git",
    "git@github.com:evanvonessen/bound.git",
}
BUNDLE_ID = "com.evanvonessen.bound"
TEAM_ID = "3N83BX5M9G"
GROUP_ID = "165fa14a-3c1a-4c4c-ae90-0189de227adc"
GROUP_NAME = "Evan Only Internal Testing"


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def published_revision(root, revision):
    for args in (("remote", "get-url", "origin"), ("remote", "get-url", "--push", "origin")):
        if git(root, *args) not in REMOTE_URLS:
            raise ValueError("origin must point to evanvonessen/bound; no build or upload started")
    commit = git(root, "rev-parse", "--verify", "--end-of-options", revision + "^{commit}")
    remote = git(root, "ls-remote", "--exit-code", "origin", "refs/heads/main").split()[0]
    if commit != remote:
        raise ValueError("Revision must equal the current origin/main; no build or upload started")
    return commit


def export_options():
    return {
        "method": "app-store-connect",
        "destination": "upload",
        "teamID": TEAM_ID,
        "signingStyle": "automatic",
        "manageAppVersionAndBuildNumber": True,
        "testFlightInternalTestingOnly": True,
        "uploadSymbols": True,
    }


@contextmanager
def source_snapshot(root, commit, output):
    with tempfile.TemporaryDirectory(prefix="source-", dir=output) as directory:
        source = Path(directory)
        tar = output / "source.tar"
        try:
            subprocess.run(["git", "-C", str(root), "archive", "--format=tar", "--output=" + str(tar), commit], check=True)
            subprocess.run(["/usr/bin/tar", "-xf", str(tar), "-C", str(source)], check=True)
            yield source
        finally:
            tar.unlink(missing_ok=True)


def run_logged(command, cwd, log):
    print(f"Running {command[0]} {command[1]} — log: {log}", flush=True)
    with log.open("w") as stream:
        result = subprocess.run(command, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}). Inspect {log}; delivery is incomplete.")


def write_json(path, data):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(data, indent=2) + "\n")
    temporary.replace(path)


def archive_info(archive, source):
    app = archive / "Products/Applications/Bound.app"
    with (app / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    with (archive / "Info.plist").open("rb") as stream:
        properties = plistlib.load(stream)["ApplicationProperties"]
    if info.get("CFBundleIdentifier") != BUNDLE_ID or properties.get("Team") != TEAM_ID:
        raise ValueError("Archive does not match Bound's approved bundle ID and signing team")
    pin = json.loads((source / "PrototypeTools/bundled-rom.json").read_text())
    contract = re.search(r'romSHA256 = "([a-f0-9]{64})"',
                         (source / "Delta/Bound/BoundSharedProgression.swift").read_text())
    if not contract or pin.get("sha256") != contract[1]:
        raise ValueError("Archived ROM pin does not match the published source contract")
    rom = app / "multiplayer.gba"
    if rom.is_symlink() or not rom.is_file() or rom.stat().st_size != 32 * 1024 * 1024:
        raise ValueError("Archive is missing the complete multiplayer.gba resource")
    digest = hashlib.sha256(rom.read_bytes()).hexdigest()
    if digest != pin["sha256"]:
        raise ValueError("Archived multiplayer.gba does not match the published source pin")
    return {"version": info["CFBundleShortVersionString"], "archive_build": info["CFBundleVersion"],
            "rom_resource": rom.name, "rom_sha256": digest, "rom_bytes": rom.stat().st_size,
            "rom_release_tag": pin.get("tag")}


def deliver(root, commit, upload):
    base = root / ".build/testflight-delivery"
    base.mkdir(parents=True, exist_ok=True)
    with (base / "delivery.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another local TestFlight delivery is already running") from None
        output = base / commit
        output.mkdir(exist_ok=True)
        receipt = output / "upload-accepted.json"
        if receipt.exists():
            saved = json.loads(receipt.read_text())
            if saved.get("commit") != commit or saved.get("bundle_id") != BUNDLE_ID:
                raise ValueError("Existing upload receipt does not match the requested revision")
            print(f"Upload was already accepted for {commit}. Verify processing and group availability in App Store Connect.")
            return

        # A temporary Git snapshot keeps unrelated edits and personal files out of the archive.
        # The original project/scheme and committed dependency sources are used unchanged.
        with source_snapshot(root, commit, output) as source:
            for tool in ("verify_sources.py", "verify_privacy_manifests.py"):
                run_logged([sys.executable, str(source / "PrototypeTools" / tool)], source, output / (tool + ".log"))

            # Each attempt is retained. Failed exports can be inspected without overwriting evidence.
            attempt = Path(tempfile.mkdtemp(prefix="attempt-", dir=output))
            archive = attempt / "Bound.xcarchive"
            run_logged([
                "xcodebuild", "-project", "Bound.xcodeproj", "-scheme", "Bound",
                "-configuration", "Release", "-destination", "generic/platform=iOS",
                "-derivedDataPath", str(base / "DerivedData"), "-archivePath", str(archive),
                "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile",
                "CLANG_ENABLE_EXPLICIT_MODULES=NO", "SWIFT_ENABLE_EXPLICIT_MODULES=NO", "archive",
            ], source, attempt / "archive.log")
            info = archive_info(archive, source)
            run_logged(["codesign", "--verify", "--deep", "--strict", str(archive / "Products/Applications/Bound.app")], source, attempt / "signature.log")
            run_logged([sys.executable, str(source / "PrototypeTools/verify_privacy_manifests.py"), "--archive", str(archive)], source, attempt / "archive-privacy.log")
            write_json(attempt / "archive.json", {"commit": commit, "bundle_id": BUNDLE_ID, **info})
            if not upload:
                print(f"Signed Release iPhone archive verified: {archive}. No upload requested.")
                return

            # Refuse an obsolete revision if another publication occurred during the archive.
            published_revision(root, commit)
            options = attempt / "ExportOptions.plist"
            with options.open("wb") as stream:
                plistlib.dump(export_options(), stream)
            run_logged([
                "xcodebuild", "-exportArchive", "-archivePath", str(archive),
                "-exportOptionsPlist", str(options), "-exportPath", str(attempt / "export"),
                "-allowProvisioningUpdates",
            ], source, attempt / "upload.log")
            summary_path = attempt / "export/DistributionSummary.plist"
            uploaded_build = None
            if summary_path.exists():
                with summary_path.open("rb") as stream:
                    summary = plistlib.load(stream)
                uploaded_build = next((item.get("buildNumber") for items in summary.values()
                                       for item in items if item.get("name") == "Bound.app"), None)
            write_json(receipt, {
                "commit": commit, "bundle_id": BUNDLE_ID, "group_id": GROUP_ID,
                "group_name": GROUP_NAME, "accepted_at": datetime.now(timezone.utc).isoformat(),
                "status": "upload accepted; processing and TestFlight availability not yet verified",
                "attempt": str(attempt), "uploaded_build": uploaded_build, **info,
            })
            print(f"Apple accepted the upload for {commit}. This is not a TestFlight processing confirmation.")
            if uploaded_build:
                print(f"Exported build: {info['version']} ({uploaded_build}).")
            print(f"Verify the processed build in {GROUP_NAME}. Apple processing is separate from upload acceptance.")
            print(f"Receipt: {receipt}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", required=True, help="Exact commit already pushed to origin/main")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="Read-only remote/revision check")
    mode.add_argument("--archive-only", action="store_true", help="Validate a signed Release archive without uploading")
    mode.add_argument("--upload", action="store_true", help="Archive and upload for internal TestFlight testing")
    args = parser.parse_args()
    try:
        commit = published_revision(ROOT, args.revision)
        if args.check:
            print(f"Verified origin/main: {commit}. No build, signing update or upload performed.")
        else:
            deliver(ROOT, commit, args.upload)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"TestFlight delivery incomplete: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
