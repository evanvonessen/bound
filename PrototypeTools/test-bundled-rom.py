"""No app build may download or embed a multiplayer cartridge."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('cleanup', Path(__file__).with_name('remove-legacy-bundled-rom.py'))
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)

class ServerROMBuildTests(unittest.TestCase):
    def test_incremental_build_removes_only_product_multiplayer_resources(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            app = base / 'Bound.app'
            app.mkdir()
            for name in ['multiplayer.gba', 'rrbin-integrated.gba', 'RRv4.1M.gba', 'firered-cover.png', '2048.gba', 'Info.plist']:
                (app / name).write_bytes(b'sentinel')
            cache = base / 'multiplayer.gba'
            cache.write_bytes(b'untouched')
            cleanup.remove_legacy_resources(base, 'Bound.app')
            self.assertEqual(sorted(p.name for p in app.iterdir()), ['2048.gba', 'Info.plist'])
            self.assertEqual(cache.read_bytes(), b'untouched')

    def test_path_escape_is_rejected(self):
        for build, resources in [('relative', 'Bound.app'), ('/tmp', '../Bound.app'), ('/tmp', '/Bound.app'), ('/tmp', '')]:
            with self.subTest(resources=resources), self.assertRaises(ValueError):
                cleanup.remove_legacy_resources(build, resources)

    def test_product_symlink_escape_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            (base / 'build').mkdir(); (base / 'outside').mkdir()
            (base / 'build/Bound.app').symlink_to(base / 'outside')
            with self.assertRaises(ValueError):
                cleanup.remove_legacy_resources(base / 'build', 'Bound.app')

    def test_xcode_phase_never_calls_bundler(self):
        project = Path(__file__).resolve().parents[1] / 'Bound.xcodeproj/project.pbxproj'
        self.assertNotIn('bundle-development-rom.py', project.read_text())
        self.assertIn('remove-legacy-bundled-rom.py', project.read_text())

    def test_retired_bundler_cannot_download_or_embed(self):
        retired_spec = importlib.util.spec_from_file_location('retired', Path(__file__).with_name('bundle-development-rom.py'))
        retired = importlib.util.module_from_spec(retired_spec)
        retired_spec.loader.exec_module(retired)
        with self.assertRaisesRegex(SystemExit, 'bundling is retired'):
            retired.main()

if __name__ == '__main__':
    unittest.main()
