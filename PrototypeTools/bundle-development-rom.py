#!/usr/bin/env python3
"""Embed the private cartridge pinned to this app's committed contract.

Never commit the ROM to the public Bound repository. Supply BOUND_DEVELOPMENT_ROM,
an authenticated gh CLI, or BOUND_ROM_GITHUB_TOKEN in the private build environment.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import urllib.request
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
BUNDLED_ROM_NAME = 'multiplayer.gba'

class PrivateReleaseRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        redirected = super().redirect_request(request, fp, code, message, headers, newurl)
        if redirected is not None and urlparse(request.full_url).hostname != urlparse(newurl).hostname:
            redirected.remove_header('Authorization')
        return redirected

def verify(path, expected):
    return path.is_file() and path.stat().st_size == 33554432 and hashlib.sha256(path.read_bytes()).hexdigest() == expected

def download_private_release(manifest, destination):
    if source := os.environ.get('BOUND_DEVELOPMENT_ROM'):
        shutil.copyfile(source, destination)
        return
    if manifest.get('local_only'):
        raise SystemExit('Supply BOUND_DEVELOPMENT_ROM pointing to the exact pinned cartridge for this build.')
    asset_name = manifest.get('asset', 'rrbin-integrated.gba')
    if manifest.get('localOnly'):
        raise SystemExit('Unpublished ROM candidate: set BOUND_DEVELOPMENT_ROM to the exact locally validated cartridge.')
    if token := os.environ.get('BOUND_ROM_GITHUB_TOKEN'):
        opener = urllib.request.build_opener(PrivateReleaseRedirect())
        headers = {'Authorization': 'Bearer ' + token, 'Accept': 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28'}
        api = 'https://api.github.com/repos/' + manifest['repository'] + '/releases/tags/' + manifest['tag']
        with opener.open(urllib.request.Request(api, headers=headers), timeout=60) as response:
            release = json.load(response)
        asset = next(item for item in release['assets'] if item['name'] == asset_name)
        if urlparse(asset['url']).hostname != 'api.github.com':
            raise SystemExit('Unexpected ROM asset endpoint.')
        headers['Accept'] = 'application/octet-stream'
        with opener.open(urllib.request.Request(asset['url'], headers=headers), timeout=120) as response, destination.open('wb') as output:
            shutil.copyfileobj(response, output)
    elif shutil.which('gh'):
        subprocess.run(['gh', 'release', 'download', manifest['tag'], '--repo', manifest['repository'], '--pattern', asset_name, '--output', str(destination)], check=True)
    else:
        raise SystemExit('Private ROM unavailable. Supply BOUND_DEVELOPMENT_ROM, authenticated gh, or BOUND_ROM_GITHUB_TOKEN to this build.')

def main():
    manifest = json.loads((ROOT / 'PrototypeTools/bundled-rom.json').read_text())
    expected = re.search(r'romSHA256 = "([a-f0-9]{64})"', (ROOT / 'Delta/Bound/BoundSharedProgression.swift').read_text())[1]
    if manifest['sha256'] != expected:
        raise SystemExit('Bundled ROM pin must be updated to match the committed Bound contract.')
    cache = ROOT / '.build/bundled-rom' / (expected + '.gba')
    cache.parent.mkdir(parents=True, exist_ok=True)
    if not verify(cache, expected):
        with tempfile.TemporaryDirectory(dir=cache.parent) as folder:
            download = Path(folder) / 'download.gba'
            download_private_release(manifest, download)
            if not verify(download, expected):
                raise SystemExit('Bundled ROM resource failed its size/SHA256 check.')
            os.replace(download, cache)
    destination = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['UNLOCALIZED_RESOURCES_FOLDER_PATH'] / BUNDLED_ROM_NAME
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(cache, destination)
    if not verify(destination, expected):
        raise SystemExit('Bundled ROM copy failed verification.')
    # An incremental build can retain the former generated resource. Remove
    # only that app-bundle copy after the new canonical copy is verified.
    (destination.parent / 'rrbin-integrated.gba').unlink(missing_ok=True)
    print('Embedded matching Multi Red cartridge: ' + expected)

if __name__ == '__main__':
    main()
