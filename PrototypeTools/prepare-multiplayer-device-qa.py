#!/usr/bin/env python3
"""Prepare or verify a side-by-side Bound QA app; never sign, install or deploy.

Build through the ordinary Bound.xcodeproj / Bound entry with the generated
xcconfig. Only app-specific build variables change. Cloud configuration and
upstream framework identities use their existing sources and settings.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parent.parent
QA_ID = "com.evanvonessen.bound.multiplayerqa"
QA_NAME = "Bound Multiplayer QA"


def prepare(output):
    output = output.resolve()
    output.relative_to(ROOT / ".build")
    if any(c in str(output) for c in ('\n', '\r', '"', '#')):
        raise ValueError("Unsupported output path")
    info = plistlib.loads((ROOT / "Delta/Supporting Files/Info.plist").read_bytes())
    # OAuth/deep-link schemes must stay owned by the user's current Bound app.
    # QA supports normal in-app email/password sign-in and Files ROM import.
    info.pop("CFBundleURLTypes", None)
    info["CFBundleDisplayName"] = QA_NAME
    info["BoundMultiplayerDeviceQA"] = True
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT))
    info["BoundPresenceSourceRevision"] = revision
    info["BoundPresenceSourceDirty"] = dirty
    output.mkdir(parents=True, exist_ok=False)
    (output / "Info.plist").write_bytes(plistlib.dumps(info))
    (output / "QA.entitlements").write_bytes(plistlib.dumps({}))
    config = ("// App-only overrides. No backend, SDK or dependency overrides.\n"
              f"BOUND_APP_BUNDLE_IDENTIFIER = {QA_ID}\n"
              f"BOUND_APP_INFO_PLIST = {output / 'Info.plist'}\n"
              f"BOUND_APP_ENTITLEMENTS = {output / 'QA.entitlements'}\n")
    (output / "DeviceQA.xcconfig").write_text(config)
    manifest = dict(bundleIdentifier=QA_ID, displayName=QA_NAME, sourceRevision=revision, sourceDirty=dirty,
                    signingCreated=False, installed=False, cloudConfigurationChanged=False)
    (output / "preparation.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return output / "DeviceQA.xcconfig"


def verify(app, production_app=None):
    app = app.resolve()
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != QA_ID or info.get("CFBundleDisplayName") != QA_NAME:
        raise ValueError("Refusing a build that could replace the current Bound app")
    if info.get("CFBundleURLTypes"):
        raise ValueError("QA app must not claim production URL callbacks")
    if info.get("BoundMultiplayerDeviceQA") is not True:
        raise ValueError("Missing QA identity marker")
    # Signed artifacts must retain private app-specific keychain access only.
    signed = (app / "_CodeSignature").exists()
    if signed:
        subprocess.run(["codesign", "--verify", "--deep", "--strict", "-R=anchor apple generic", str(app)],
                       check=True, capture_output=True)
        result = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(app)], check=True, capture_output=True)
        entitlements = plistlib.loads(result.stdout)
        identity = entitlements.get("application-identifier", "")
        if not identity.endswith("." + QA_ID):
            raise ValueError("Signed application identifier is not QA-specific")
        if entitlements.get("com.apple.security.application-groups") or entitlements.get("aps-environment"):
            raise ValueError("QA must not share app groups or production push registration")
        if any(group != identity for group in entitlements.get("keychain-access-groups", [])):
            raise ValueError("QA keychain access must be confined to its own app identifier")
    comparison = "not supplied"
    if production_app is not None:
        for resource in ("cloud-configuration.json",):
            normal = production_app / resource
            candidate = app / resource
            if normal.exists() != candidate.exists() or (normal.exists() and normal.read_bytes() != candidate.read_bytes()):
                raise ValueError("QA cloud configuration differs from the normal app")
        comparison = "identical" if (production_app / "cloud-configuration.json").exists() else "absent in both builds"
    return dict(bundleIdentifier=QA_ID, signed=signed, productionCloudConfiguration=comparison,
                infoPlistSHA256=hashlib.sha256((app / "Info.plist").read_bytes()).hexdigest())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)
    stage = sub.add_parser("prepare")
    stage.add_argument("--output", type=Path, required=True)
    check = sub.add_parser("verify")
    check.add_argument("--app", type=Path, required=True)
    check.add_argument("--production-app", type=Path)
    args = parser.parse_args()
    try:
        if args.mode == "prepare":
            print(prepare(args.output))
        else:
            print(json.dumps(verify(args.app, args.production_app), indent=2))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()
