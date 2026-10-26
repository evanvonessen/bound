"""Offline safeguards for publication snapshots and internal upload scope."""

import importlib.util
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("delivery", Path(__file__).with_name("deliver-testflight.py"))
delivery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delivery)


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "repo"
        self.root.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "Offline Test")
        (self.root / "source.swift").write_text("published source\n")
        (self.root / "source-link").symlink_to("source.swift")
        self.git("add", ".")
        self.git("commit", "-qm", "Published")
        self.commit = self.git("rev-parse", "HEAD")
        self.remote = self.base / "remote.git"
        subprocess.run(["git", "init", "-q", "--bare", str(self.remote)], check=True)
        self.git("remote", "add", "origin", str(self.remote))
        self.git("push", "-q", "origin", "HEAD:refs/heads/main")

    def git(self, *args):
        return delivery.git(self.root, *args)

    def test_snapshot_excludes_dirty_source_and_untracked_personal_files(self):
        (self.root / "source.swift").write_text("unrelated local edit\n")
        (self.root / "personal-save.sav").write_bytes(b"personal data")
        with delivery.source_snapshot(self.root, self.commit, self.base) as source:
            self.assertEqual((source / "source.swift").read_text(), "published source\n")
            self.assertEqual((source / "source-link").readlink(), Path("source.swift"))
            self.assertFalse((source / "personal-save.sav").exists())
        self.assertEqual((self.root / "source.swift").read_text(), "unrelated local edit\n")
        self.assertTrue((self.root / "personal-save.sav").exists())

    def test_rejects_unpublished_commit_and_wrong_push_remote(self):
        with patch.object(delivery, "REMOTE_URLS", {str(self.remote)}):
            self.assertEqual(delivery.published_revision(self.root, self.commit), self.commit)
            (self.root / "source.swift").write_text("not published\n")
            self.git("commit", "-qam", "Unpublished")
            with self.assertRaisesRegex(ValueError, "current origin/main"):
                delivery.published_revision(self.root, "HEAD")
            self.git("remote", "set-url", "--push", "origin", "https://example.invalid/wrong.git")
            with self.assertRaisesRegex(ValueError, "origin must point"):
                delivery.published_revision(self.root, self.commit)

    def test_export_is_limited_to_internal_testing_with_managed_numbering(self):
        options = delivery.export_options()
        self.assertTrue(options["testFlightInternalTestingOnly"])
        self.assertTrue(options["manageAppVersionAndBuildNumber"])
        self.assertEqual(options["destination"], "upload")
        self.assertEqual(options["teamID"], "3N83BX5M9G")

    def archive_fixture(self):
        archive = self.base / 'Bound.xcarchive'
        app = archive / 'Products/Applications/Bound.app'
        app.mkdir(parents=True)
        (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': delivery.BUNDLE_ID,
            'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '99'}))
        (archive / 'Info.plist').write_bytes(plistlib.dumps({'ApplicationProperties': {'Team': delivery.TEAM_ID}}))
        source = self.base / 'published-source'
        (source / 'PrototypeTools').mkdir(parents=True)
        (source / 'Delta/Bound').mkdir(parents=True)
        data = bytes(32 * 1024 * 1024)
        digest = hashlib.sha256(data).hexdigest()
        (source / 'PrototypeTools/bundled-rom.json').write_text(json.dumps({'sha256': digest, 'tag': 'immutable-test-tag'}))
        (source / 'Delta/Bound/BoundSharedProgression.swift').write_text('romSHA256 = "' + digest + '"')
        return archive, app, source, data, digest

    def test_archive_records_exact_rom_from_snapshot_pin(self):
        archive, app, source, data, digest = self.archive_fixture()
        (app / 'multiplayer.gba').write_bytes(data)
        info = delivery.archive_info(archive, source)
        self.assertEqual(info['rom_resource'], 'multiplayer.gba')
        self.assertEqual(info['rom_sha256'], digest)
        self.assertEqual(info['rom_bytes'], len(data))
        self.assertEqual(info['rom_release_tag'], 'immutable-test-tag')

    def test_archive_refuses_missing_partial_and_wrong_rom(self):
        archive, app, source, data, _ = self.archive_fixture()
        (app / 'rrbin-integrated.gba').write_bytes(data)
        with self.assertRaisesRegex(ValueError, 'missing the complete'):
            delivery.archive_info(archive, source)
        (app / 'multiplayer.gba').write_bytes(b'partial')
        with self.assertRaisesRegex(ValueError, 'missing the complete'):
            delivery.archive_info(archive, source)
        (app / 'multiplayer.gba').write_bytes(b'\x01' * len(data))
        with self.assertRaisesRegex(ValueError, 'does not match'):
            delivery.archive_info(archive, source)

    def test_archive_refuses_source_contract_pin_drift(self):
        archive, app, source, data, _ = self.archive_fixture()
        (app / 'multiplayer.gba').write_bytes(data)
        (source / 'Delta/Bound/BoundSharedProgression.swift').write_text('romSHA256 = "' + 'f' * 64 + '"')
        with self.assertRaisesRegex(ValueError, 'source contract'):
            delivery.archive_info(archive, source)


if __name__ == "__main__":
    unittest.main()
