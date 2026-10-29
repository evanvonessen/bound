#!/usr/bin/env python3
"""Archive a published Bound revision and optionally upload it for TestFlight."""

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parent.parent
REMOTE_URLS = {
    "https://github.com/evanvonessen/bound.git",
    "git@github.com:evanvonessen/bound.git",
}
BUNDLE_ID = "com.evanvonessen.bound"
TEAM_ID = "3N83BX5M9G"
GROUP_ID = "165fa14a-3c1a-4c4c-ae90-0189de227adc"
GROUP_NAME = "Evan Only Internal Testing"


def configure_xcode(environ=None, selected=None):
    """Use a full Xcode installation without changing global tool selection."""
    environ = os.environ if environ is None else environ
    explicit = environ.get("DEVELOPER_DIR")
    if explicit:
        if not (Path(explicit) / "usr/bin/xcodebuild").is_file():
            raise ValueError("DEVELOPER_DIR must point to a full Xcode installation")
        return explicit
    if selected is None:
        selected = subprocess.check_output(["xcode-select", "-p"], text=True).strip()
    for candidate in ["/Applications/Developer/Xcode.app/Contents/Developer",
                      selected, "/Applications/Xcode.app/Contents/Developer"]:
        if (Path(candidate) / "usr/bin/xcodebuild").is_file():
            environ["DEVELOPER_DIR"] = candidate
            return candidate
    raise ValueError("Install Xcode and select its developer directory; Command Line Tools cannot export this app")


def signing_preflight():
    """Inspect public signing metadata; let Xcode establish account access at upload."""
    configure_xcode()
    identities = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
    fingerprints = set(re.findall(r'[0-9]+\)\s+([A-Fa-f0-9]{40})\s+"Apple Distribution: [^"\n]+ \(' + re.escape(TEAM_ID) + r'\)"', identities))
    if not fingerprints:
        raise ValueError("No usable Apple Distribution identity/private key exists for the Bound team. "
                         "Use Xcode Manage Certificates to install an authorized identity; preserve existing certificates.")
    folders = [Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
               Path.home() / "Library/MobileDevice/Provisioning Profiles"]
    for folder in folders:
        for path in folder.glob("*.mobileprovision"):
            result = subprocess.run(["security", "cms", "-D", "-i", str(path)], capture_output=True)
            if result.returncode:
                continue
            try:
                if profile_can_sign(plistlib.loads(result.stdout), fingerprints):
                    return
            except (ValueError, TypeError, plistlib.InvalidFileException):
                continue
    raise ValueError("No unexpired App Store provisioning profile includes an installed Bound distribution private key "
                     "and production push entitlement. Refresh the profile in Xcode before archiving; "
                     "do not revoke certificates or delete saved credentials.")


def profile_can_sign(profile, fingerprints, now=None):
    entitlements = profile.get("Entitlements", {})
    expiry = profile.get("ExpirationDate")
    now = now or datetime.now(timezone.utc)
    if not isinstance(expiry, datetime):
        return False
    return (expiry.replace(tzinfo=timezone.utc) > now
            and TEAM_ID in profile.get("TeamIdentifier", [])
            and entitlements.get("application-identifier") == TEAM_ID + "." + BUNDLE_ID
            and entitlements.get("get-task-allow") is False
            and entitlements.get("aps-environment") == "production"
            and not profile.get("ProvisionedDevices") and not profile.get("ProvisionsAllDevices")
            and bool({hashlib.sha1(cert).hexdigest().upper() for cert in profile.get("DeveloperCertificates", [])}
                     & {fingerprint.upper() for fingerprint in fingerprints}))


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


def export_options(destination="upload", external_testing=False):
    if destination not in ("upload", "export"):
        raise ValueError("Distribution destination must be upload or export")
    return {
        "method": "app-store-connect",
        "destination": destination,
        "teamID": TEAM_ID,
        "signingStyle": "automatic",
        "manageAppVersionAndBuildNumber": True,
        "testFlightInternalTestingOnly": not external_testing,
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
        diagnosis = failure_diagnosis(log.read_text(errors="replace"))
        write_json(log.with_suffix(".failure.json"), {
            "exit_code": result.returncode, "diagnosis": diagnosis,
            "upload_acceptance_confirmed": False, "log": str(log),
        })
        raise RuntimeError(f"Command failed ({result.returncode}). {diagnosis} Inspect {log}; delivery is incomplete.")


def failure_diagnosis(text):
    if "Failed to Use Accounts" in text or "App Store Connect access for" in text:
        return ("Xcode could not select an account with App Store Connect access for the Bound team. "
                "This is an account-access failure, not an Apple binary rejection. "
                "This error alone does not establish sign-out, an expired session, or missing permissions. Inspect the IDEDistribution logs and verify team/app access without removing accounts or saved credentials.")
    if "No profiles for" in text or "requires a provisioning profile" in text:
        return "Xcode could not find a matching signing profile; no accepted upload is confirmed."
    if "Validation failed" in text or "ERROR ITMS-" in text:
        return "Apple distribution validation failed; inspect the retained validation log before retrying."
    return "The command did not finish successfully; no accepted upload is confirmed."


def api_key_arguments(environ=None, root=ROOT):
    """Validate explicit team-key metadata without reading or copying the secret."""
    environ = os.environ if environ is None else environ
    names = ('ASC_API_KEY_PATH', 'ASC_API_KEY_ID', 'ASC_API_ISSUER_ID')
    values = [environ.get(name, '').strip() for name in names]
    if not all(values):
        raise ValueError('Set all three ASC_API_KEY_PATH, ASC_API_KEY_ID, and ASC_API_ISSUER_ID; no account fallback attempted')
    path, key_id, issuer = values
    if not re.fullmatch(r'[A-Z0-9]{10}', key_id) or not re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', issuer):
        raise ValueError('API authentication requires a 10-character Key ID and team Issuer UUID; use a Team Key')
    path = Path(path).expanduser().resolve()
    if path.is_relative_to(Path(root).resolve()):
        raise ValueError('Store the API private key outside the Bound repository')
    if not path.is_file() or not os.access(path, os.R_OK):
        raise ValueError('API private key file is missing or unreadable; no account fallback attempted')
    if path.stat().st_mode & 0o077:
        raise ValueError('API private key must be owner-only: chmod 600 the .p8 file')
    return ['-authenticationKeyPath', str(path), '-authenticationKeyID', key_id,
            '-authenticationKeyIssuerID', issuer]


def export_command(archive, options, output, upload=False, authentication=()):
    command = ["xcodebuild", "-exportArchive", "-archivePath", str(archive),
               "-exportOptionsPlist", str(options), "-exportPath", str(output)]
    # Local validation uses only already installed signing material. Only the
    # explicitly requested upload may let Xcode manage provisioning assets.
    if upload:
        command.append("-allowProvisioningUpdates")
        command.extend(authentication)
    return command


def distribution_info(ipa, source=None):
    """Inspect the actual exported binary without accessing the keychain/account."""
    prefix = "Payload/Bound.app/"
    with zipfile.ZipFile(ipa) as package:
        if len(package.namelist()) != len(set(package.namelist())):
            raise ValueError("Exported IPA has duplicate ZIP entries")
        info = plistlib.loads(package.read(prefix + "Info.plist"))
        executable = info.get("CFBundleExecutable", "")
        if info.get("CFBundleIdentifier") != BUNDLE_ID or not re.fullmatch(r"[A-Za-z0-9_-]+", executable):
            raise ValueError("Exported IPA does not match Bound's bundle identity")
        with tempfile.TemporaryDirectory(prefix="bound-export-inspection-") as directory:
            binary = Path(directory) / executable
            binary.write_bytes(package.read(prefix + executable))
            result = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(binary)],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
            entitlements = plistlib.loads(result.stdout)
        if (entitlements.get("application-identifier") != TEAM_ID + "." + BUNDLE_ID
                or entitlements.get("com.apple.developer.team-identifier") != TEAM_ID
                or entitlements.get("get-task-allow") is not False
                or entitlements.get("aps-environment") != "production"):
            raise ValueError("Exported IPA must have Bound distribution entitlements: production APNs and get-task-allow=false")
        if any(name.startswith(prefix) and Path(name).name in {"multiplayer.gba", "rrbin-integrated.gba", "RRv4.1M.gba"}
               for name in package.namelist()):
            raise ValueError("Exported IPA contains a multiplayer ROM; distribute it through the approved server updater")
    return {"version": info["CFBundleShortVersionString"], "archive_build": info["CFBundleVersion"],
            "rom_distribution": "developer-approved-server", "distribution_entitlements_verified": True}


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
    if any(path.name in {"multiplayer.gba", "rrbin-integrated.gba", "RRv4.1M.gba"} for path in app.rglob("*.gba")):
        raise ValueError("Archive contains a multiplayer ROM; distribute it through the approved server updater")
    return {"version": info["CFBundleShortVersionString"], "archive_build": info["CFBundleVersion"],
            "rom_distribution": "developer-approved-server"}


def deliver(root, commit, upload, external_testing=False):
    authentication = api_key_arguments(root=root) if upload else []
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
            if upload:
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
            # A development-signed archive can pass codesign and still fail at
            # the distribution export stage. Exercise that stage before calling
            # archive-only validation complete or attempting an upload.
            local_options = attempt / "LocalExportOptions.plist"
            with local_options.open("wb") as stream:
                plistlib.dump(export_options("export", external_testing=external_testing), stream)
            local_export = attempt / "local-export"
            run_logged(export_command(archive, local_options, local_export, upload=upload, authentication=authentication), source, attempt / "local-export.log")
            exported = distribution_info(local_export / "Bound.ipa", source)
            write_json(attempt / "local-export.json", {"commit": commit, "upload_performed": False, **exported})
            if not upload:
                print(f"Signed Release iPhone archive and local distribution export verified: {archive}. No upload requested.")
                return

            # Refuse an obsolete revision if another publication occurred during the archive.
            published_revision(root, commit)
            options = attempt / "ExportOptions.plist"
            with options.open("wb") as stream:
                plistlib.dump(export_options(external_testing=external_testing), stream)
            run_logged(export_command(archive, options, attempt / "export", upload=True, authentication=authentication), source, attempt / "upload.log")
            summary_path = attempt / "export/DistributionSummary.plist"
            uploaded_build = None
            if summary_path.exists():
                with summary_path.open("rb") as stream:
                    summary = plistlib.load(stream)
                uploaded_build = next((item.get("buildNumber") for items in summary.values()
                                       for item in items if item.get("name") == "Bound.app"), None)
            write_json(receipt, {
                "commit": commit, "bundle_id": BUNDLE_ID,
                "group_id": None if external_testing else GROUP_ID,
                "group_name": "iPhone Group" if external_testing else GROUP_NAME,
                "external_testing_eligible": external_testing,
                "accepted_at": datetime.now(timezone.utc).isoformat(),
                "status": "upload accepted; processing and TestFlight availability not yet verified",
                "attempt": str(attempt), "uploaded_build": uploaded_build, **info,
            })
            print(f"Apple accepted the upload for {commit}. This is not a TestFlight processing confirmation.")
            if uploaded_build:
                print(f"Exported build: {info['version']} ({uploaded_build}).")
            if external_testing:
                print("After processing, manually add this build to iPhone Group in App Store Connect and submit for beta review if required. No external group assignment was performed.")
            else:
                print(f"Verify the processed build in {GROUP_NAME}. Apple processing is separate from upload acceptance.")
            print(f"Receipt: {receipt}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", required=True, help="Exact commit already pushed to origin/main")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="Read-only remote/revision check")
    mode.add_argument("--archive-only", action="store_true", help="Validate a signed Release archive without uploading")
    mode.add_argument("--upload", action="store_true", help="Archive and upload to TestFlight (internal-only by default)")
    parser.add_argument("--external-testing", action="store_true",
                        help="Allow external testing; assign to iPhone Group manually after processing")
    args = parser.parse_args()
    try:
        commit = published_revision(ROOT, args.revision)
        if args.check:
            print(f"Verified origin/main: {commit}. No build, signing update or upload performed.")
        else:
            signing_preflight()
            deliver(ROOT, commit, args.upload, external_testing=args.external_testing)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"TestFlight delivery incomplete: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
