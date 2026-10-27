#!/usr/bin/env python3
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location('bundler', Path(__file__).with_name('bundle-development-rom.py'))
bundler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundler)

class BundledROMTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.data = bytes(33554432)
        self.digest = hashlib.sha256(self.data).hexdigest()
        for name in ('PrototypeTools', 'Delta/Bound'):
            (self.root / name).mkdir(parents=True)
        (self.root / 'PrototypeTools/bundled-rom.json').write_text(json.dumps({'sha256': self.digest,
            'repository': 'evanvonessen/multi_red', 'tag': 'multiplayer-' + self.digest[:12], 'asset': 'multiplayer.gba'}))
        (self.root / 'private-source.gba').write_bytes(self.data)
        (self.root / 'Delta/Bound/BoundSharedProgression.swift').write_text('romSHA256 = "' + self.digest + '"')
        self.output = self.root / 'output/Bound.app/multiplayer.gba'

    def run_build(self):
        with patch.object(bundler, 'ROOT', self.root), patch.dict(os.environ, {'BOUND_DEVELOPMENT_ROM': str(self.root / 'private-source.gba'), 'TARGET_BUILD_DIR': str(self.root / 'output'), 'UNLOCALIZED_RESOURCES_FOLDER_PATH': 'Bound.app'}):
            bundler.main()

    def test_empty_cache_and_cached_build_embed_verified_cartridge(self):
        self.run_build()
        self.assertEqual(self.output.read_bytes(), self.data)
        self.output.unlink()
        self.run_build()
        self.assertEqual(self.output.read_bytes(), self.data)

    def test_explicit_empty_cache_embeds_exact_rom_and_leaves_existing_cache_untouched(self):
        previous = self.root / '.build/bundled-rom' / (self.digest + '.gba')
        previous.parent.mkdir(parents=True); previous.write_bytes(b'preserved cache sentinel')
        explicit = self.root / 'isolated-empty-cache'
        with patch.dict(os.environ, {'BOUND_ROM_CACHE_DIRECTORY': str(explicit)}):
            self.run_build()
        self.assertEqual(self.output.read_bytes(), self.data)
        self.assertEqual((explicit / (self.digest + '.gba')).read_bytes(), self.data)
        self.assertEqual(previous.read_bytes(), b'preserved cache sentinel')

    def test_wrong_contract_refuses_to_embed(self):
        (self.root / 'Delta/Bound/BoundSharedProgression.swift').write_text('romSHA256 = "' + 'f' * 64 + '"')
        with self.assertRaises(SystemExit):
            self.run_build()
        self.assertFalse(self.output.exists())

    def test_corrupt_cache_is_replaced_and_old_bundle_resource_is_removed(self):
        cache = self.root / '.build/bundled-rom' / (self.digest + '.gba')
        cache.parent.mkdir(parents=True)
        cache.write_bytes(b'corrupt')
        self.output.parent.mkdir(parents=True)
        legacy = self.output.parent / 'rrbin-integrated.gba'
        legacy.write_bytes(b'obsolete generated resource')
        self.run_build()
        self.assertEqual(cache.read_bytes(), self.data)
        self.assertEqual(self.output.read_bytes(), self.data)
        self.assertFalse(legacy.exists())

    def test_wrong_full_size_rom_is_rejected(self):
        (self.root / 'private-source.gba').write_bytes(b'\x01' * len(self.data))
        with self.assertRaises(SystemExit):
            self.run_build()
        self.assertFalse(self.output.exists())

    def test_private_download_uses_exact_manifest_tag_and_asset(self):
        manifest = json.loads((self.root / 'PrototypeTools/bundled-rom.json').read_text())
        destination = self.root / 'download.gba'
        with patch.dict(os.environ, {}, clear=True), patch.object(bundler.shutil, 'which', return_value='/test/gh'), \
             patch.object(bundler.subprocess, 'run') as run:
            bundler.download_private_release(manifest, destination)
        run.assert_called_once_with(['gh', 'release', 'download', manifest['tag'], '--repo', manifest['repository'],
                                     '--pattern', 'multiplayer.gba', '--output', str(destination)], check=True)

    def test_private_token_is_not_forwarded_to_asset_storage(self):
        request = bundler.urllib.request.Request('https://api.github.com/asset', headers={'Authorization': 'Bearer test-only'})
        redirected = bundler.PrivateReleaseRedirect().redirect_request(request, None, 302, 'Found', {}, 'https://release-assets.githubusercontent.com/file')
        self.assertIsNone(redirected.get_header('Authorization'))

    def test_unpublished_candidate_never_attempts_a_release_download(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(bundler.subprocess, 'run') as run:
            with self.assertRaisesRegex(SystemExit, 'Unpublished ROM candidate'):
                bundler.download_private_release({'localOnly': True}, self.root / 'download.gba')
        run.assert_not_called()

    def test_incomplete_resource_refuses_to_embed(self):
        (self.root / 'private-source.gba').write_bytes(b'partial')
        with self.assertRaises(SystemExit):
            self.run_build()
        self.assertFalse(self.output.exists())

if __name__ == '__main__':
    unittest.main()
