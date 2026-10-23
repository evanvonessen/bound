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
        (self.root / 'PrototypeTools/bundled-rom.json').write_text(json.dumps({'sha256': self.digest}))
        (self.root / 'private-source.gba').write_bytes(self.data)
        (self.root / 'Delta/Bound/BoundSharedProgression.swift').write_text('romSHA256 = "' + self.digest + '"')
        self.output = self.root / 'output/Bound.app/rrbin-integrated.gba'

    def run_build(self):
        with patch.object(bundler, 'ROOT', self.root), patch.dict(os.environ, {'BOUND_DEVELOPMENT_ROM': str(self.root / 'private-source.gba'), 'TARGET_BUILD_DIR': str(self.root / 'output'), 'UNLOCALIZED_RESOURCES_FOLDER_PATH': 'Bound.app'}):
            bundler.main()

    def test_empty_cache_and_cached_build_embed_verified_cartridge(self):
        self.run_build()
        self.assertEqual(self.output.read_bytes(), self.data)
        self.output.unlink()
        self.run_build()
        self.assertEqual(self.output.read_bytes(), self.data)

    def test_wrong_contract_refuses_to_embed(self):
        (self.root / 'Delta/Bound/BoundSharedProgression.swift').write_text('romSHA256 = "' + 'f' * 64 + '"')
        with self.assertRaises(SystemExit):
            self.run_build()
        self.assertFalse(self.output.exists())

    def test_private_token_is_not_forwarded_to_asset_storage(self):
        request = bundler.urllib.request.Request('https://api.github.com/asset', headers={'Authorization': 'Bearer test-only'})
        redirected = bundler.PrivateReleaseRedirect().redirect_request(request, None, 302, 'Found', {}, 'https://release-assets.githubusercontent.com/file')
        self.assertIsNone(redirected.get_header('Authorization'))

    def test_incomplete_resource_refuses_to_embed(self):
        (self.root / 'private-source.gba').write_bytes(b'partial')
        with self.assertRaises(SystemExit):
            self.run_build()
        self.assertFalse(self.output.exists())

if __name__ == '__main__':
    unittest.main()
