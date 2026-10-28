"""Offline safeguards for publication snapshots and internal upload scope."""

import importlib.util
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import zipfile
from contextlib import contextmanager
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("delivery", Path(__file__).with_name("deliver-testflight.py"))
delivery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delivery)


class DeliveryTests(unittest.TestCase):
    def test_profile_must_match_private_key_push_scope_team_and_validity(self):
        from datetime import datetime, timezone
        certificate = b'fixture public DER certificate'
        fingerprint = hashlib.sha1(certificate).hexdigest().upper()
        profile = {'TeamIdentifier':[delivery.TEAM_ID], 'ExpirationDate':datetime(2099,1,1),
            'DeveloperCertificates':[certificate], 'Entitlements':{
                'application-identifier':delivery.TEAM_ID+'.'+delivery.BUNDLE_ID,
                'get-task-allow':False, 'aps-environment':'production'}}
        self.assertTrue(delivery.profile_can_sign(profile, {fingerprint}))
        self.assertFalse(delivery.profile_can_sign(profile, {'0'*40}))
        self.assertFalse(delivery.profile_can_sign(dict(profile, ExpirationDate=datetime(2000,1,1)), {fingerprint}))
        self.assertFalse(delivery.profile_can_sign(dict(profile, ProvisionedDevices=['fixture-device']), {fingerprint}))
        for field,value in [('aps-environment','development'),('application-identifier','OTHER.fixture'),('get-task-allow',True)]:
            changed=dict(profile,Entitlements=dict(profile['Entitlements'],**{field:value}))
            self.assertFalse(delivery.profile_can_sign(changed,{fingerprint}))

    def test_xcode_selection_rejects_command_line_tools_and_preserves_explicit_full_xcode(self):
        with tempfile.TemporaryDirectory() as folder:
            developer = Path(folder) / 'Xcode.app/Contents/Developer'
            (developer / 'usr/bin').mkdir(parents=True)
            (developer / 'usr/bin/xcodebuild').touch()
            environment = {'DEVELOPER_DIR': str(developer)}
            self.assertEqual(delivery.configure_xcode(environment), str(developer))
            with self.assertRaisesRegex(ValueError, 'full Xcode'):
                delivery.configure_xcode({'DEVELOPER_DIR': folder})

    def test_preflight_does_not_read_account_preferences(self):
        with patch.object(delivery, 'configure_xcode'), \
             patch.object(delivery.subprocess, 'run') as run, \
             patch.object(delivery.subprocess, 'check_output', return_value='Apple Development: fixture') as identity:
            with self.assertRaisesRegex(ValueError, 'No usable Apple Distribution'):
                delivery.signing_preflight()
            run.assert_not_called()
            self.assertEqual(identity.call_args.args[0],
                             ['security', 'find-identity', '-v', '-p', 'codesigning'])

    def test_relocated_xcode_is_preferred_without_global_selection_changes(self):
        with patch.object(Path, 'is_file', return_value=True):
            environment = {}
            self.assertEqual(delivery.configure_xcode(environment, selected='/old/Xcode'),
                             '/Applications/Developer/Xcode.app/Contents/Developer')
            self.assertEqual(environment['DEVELOPER_DIR'],
                             '/Applications/Developer/Xcode.app/Contents/Developer')

    def test_api_key_configuration_and_export_arguments(self):
        key = self.base / 'private.p8'
        key.write_text('fixture only')
        key.chmod(0o600)
        env = {'ASC_API_KEY_PATH': str(key), 'ASC_API_KEY_ID': 'ABCDEFGHIJ',
               'ASC_API_ISSUER_ID': '12345678-1234-1234-1234-123456789abc'}
        args = delivery.api_key_arguments(env, root=self.root)
        self.assertEqual(args[1], str(key.resolve()))
        self.assertNotIn('fixture only', str(args))
        command = delivery.export_command('archive', 'options', 'out', upload=True, authentication=args)
        self.assertEqual(command[-6:], args)
        self.assertNotIn('-authenticationKeyPath', delivery.export_command('a', 'b', 'c', authentication=args))
        with self.assertRaisesRegex(ValueError, "Set all three"):
            delivery.api_key_arguments({}, root=self.root)
        for broken in [dict(env, ASC_API_KEY_ID=''), dict(env, ASC_API_ISSUER_ID='bad'),
                       dict(env, ASC_API_KEY_PATH=str(self.base / 'missing'))]:
            with self.assertRaises(ValueError):
                delivery.api_key_arguments(broken, root=self.root)
        key.chmod(0o644)
        with self.assertRaisesRegex(ValueError, 'owner-only'):
            delivery.api_key_arguments(env, root=self.root)
        key.chmod(0o600)
        with self.assertRaisesRegex(ValueError, 'outside'):
            delivery.api_key_arguments(env, root=self.base)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "repo"
        self.root.mkdir()
        fixture_key = self.base / 'fixture.p8'
        fixture_key.write_text('not a real key')
        fixture_key.chmod(0o600)
        environment = patch.dict(os.environ, {
            'ASC_API_KEY_PATH': str(fixture_key), 'ASC_API_KEY_ID': 'ABCDEFGHIJ',
            'ASC_API_ISSUER_ID': '12345678-1234-1234-1234-123456789abc'})
        environment.start()
        self.addCleanup(environment.stop)

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

    def test_local_distribution_export_cannot_upload_or_update_signing_assets(self):
        options = delivery.export_options("export")
        self.assertEqual(options["destination"], "export")
        self.assertTrue(options["manageAppVersionAndBuildNumber"])
        self.assertTrue(options["testFlightInternalTestingOnly"])
        command = delivery.export_command("archive", "options", "output")
        self.assertNotIn("-allowProvisioningUpdates", command)
        self.assertIn("-allowProvisioningUpdates", delivery.export_command("archive", "options", "output", upload=True))
        with self.assertRaises(ValueError):
            delivery.export_options("ad-hoc")

    def test_account_failure_is_distinguished_from_binary_validation_and_uncertain_upload(self):
        self.assertIn("account-access failure", delivery.failure_diagnosis("error: exportArchive Failed to Use Accounts"))
        self.assertIn("validation failed", delivery.failure_diagnosis("Validation failed ERROR ITMS-90000"))
        self.assertIn("no accepted upload is confirmed", delivery.failure_diagnosis("network connection lost"))

    def exported_fixture(self):
        archive, app, source, data, digest = self.archive_fixture()
        info = plistlib.loads((app / "Info.plist").read_bytes())
        info["CFBundleExecutable"] = "Bound"
        ipa = self.base / "Bound.ipa"
        with zipfile.ZipFile(ipa, "w") as package:
            package.writestr("Payload/Bound.app/Info.plist", plistlib.dumps(info))
            package.writestr("Payload/Bound.app/Bound", b"fixture-binary")
            package.writestr("Payload/Bound.app/multiplayer.gba", data)
        entitlements = {"application-identifier": delivery.TEAM_ID + "." + delivery.BUNDLE_ID,
                        "com.apple.developer.team-identifier": delivery.TEAM_ID,
                        "get-task-allow": False, "aps-environment": "production"}
        return ipa, source, entitlements, digest

    def test_export_inspects_distribution_entitlements_and_actual_rom(self):
        ipa, source, entitlements, digest = self.exported_fixture()
        result = subprocess.CompletedProcess([], 0, stdout=plistlib.dumps(entitlements), stderr=b"")
        with patch.object(delivery.subprocess, "run", return_value=result) as run:
            info = delivery.distribution_info(ipa, source)
            self.assertEqual(info["rom_sha256"], digest)
            self.assertTrue(info["distribution_entitlements_verified"])
            self.assertEqual(run.call_args.args[0][:4], ["codesign", "-d", "--entitlements", ":-"])

    def test_export_refuses_development_or_wrong_team_entitlements(self):
        ipa, source, entitlements, _ = self.exported_fixture()
        for key, wrong in [("get-task-allow", True), ("aps-environment", "development"),
                           ("com.apple.developer.team-identifier", "WRONGTEAM"),
                           ("application-identifier", "WRONG.app")]:
            with self.subTest(key=key):
                result = subprocess.CompletedProcess([], 0, stdout=plistlib.dumps({**entitlements, key: wrong}), stderr=b"")
                with patch.object(delivery.subprocess, "run", return_value=result):
                    with self.assertRaisesRegex(ValueError, "distribution entitlements"):
                        delivery.distribution_info(ipa, source)

    def test_invalid_local_export_blocks_upload_before_remote_or_upload_command(self):
        @contextmanager
        def snapshot(*_):
            yield self.root
        with patch.object(delivery, "source_snapshot", snapshot), \
             patch.object(delivery, "run_logged") as run, \
             patch.object(delivery, "archive_info", return_value={"version": "1.0", "archive_build": "99"}), \
             patch.object(delivery, "distribution_info", side_effect=ValueError("bad distribution entitlements")), \
             patch.object(delivery, "published_revision") as remote:
            with self.assertRaisesRegex(ValueError, "bad distribution"):
                delivery.deliver(self.root, self.commit, upload=True)
            remote.assert_not_called()
            self.assertFalse(any(Path(call.args[2]).name == "upload.log" for call in run.call_args_list))
            local_call = next(call for call in run.call_args_list if Path(call.args[2]).name == "local-export.log")
            options = plistlib.loads(Path(local_call.args[0][local_call.args[0].index("-exportOptionsPlist") + 1]).read_bytes())
            self.assertEqual(options["destination"], "export")

    def test_upload_passes_explicit_key_and_missing_key_stops_before_build(self):
        with patch.dict(os.environ, {'ASC_API_KEY_PATH': '', 'ASC_API_KEY_ID': '', 'ASC_API_ISSUER_ID': ''}), \
             patch.object(delivery, 'run_logged') as run:
            with self.assertRaisesRegex(ValueError, 'Set all three'):
                delivery.deliver(self.root, self.commit, upload=True)
            run.assert_not_called()
        @contextmanager
        def snapshot(*_):
            yield self.root
        with patch.object(delivery, 'source_snapshot', snapshot), \
             patch.object(delivery, 'run_logged') as run, \
             patch.object(delivery, 'archive_info', return_value={}), \
             patch.object(delivery, 'distribution_info', return_value={}), \
             patch.object(delivery, 'published_revision'):
            delivery.deliver(self.root, self.commit, upload=True)
            exports = [call.args[0] for call in run.call_args_list
                       if Path(call.args[2]).name in ('upload.log', 'local-export.log')]
            self.assertEqual(len(exports), 2)
            for command in exports:
                self.assertEqual(command[-6:], delivery.api_key_arguments(root=self.root))

    def test_archive_only_rechecks_distribution_without_uploading_or_discarding_receipt(self):
        @contextmanager
        def snapshot(*_):
            yield self.root
        output = self.root / ".build/testflight-delivery" / self.commit
        output.mkdir(parents=True)
        receipt = output / "upload-accepted.json"
        receipt.write_text(json.dumps({"commit": self.commit, "bundle_id": delivery.BUNDLE_ID}))
        original = receipt.read_bytes()
        with patch.object(delivery, "source_snapshot", snapshot), \
             patch.object(delivery, "run_logged") as run, \
             patch.object(delivery, "archive_info", return_value={"version": "1.0", "archive_build": "99"}), \
             patch.object(delivery, "distribution_info", return_value={"distribution_entitlements_verified": True}), \
             patch.object(delivery, "published_revision") as remote:
            delivery.deliver(self.root, self.commit, upload=False)
            remote.assert_not_called()
            self.assertEqual(receipt.read_bytes(), original)
            self.assertFalse(any(Path(call.args[2]).name == "upload.log" for call in run.call_args_list))
            local_call = next(call for call in run.call_args_list if Path(call.args[2]).name == "local-export.log")
            self.assertNotIn("-allowProvisioningUpdates", local_call.args[0])

    def test_checkout_gem_preflight_never_starts_fastlane(self):
        launcher = Path(__file__).with_name("fastlane-local").resolve()
        root = launcher.parent.parent
        executable = self.base / "bundle"
        calls = self.base / "bundle-calls.jsonl"
        executable.write_text("#!/bin/sh\nprintf '%s\\n' \"$*|$BUNDLE_GEMFILE|$BUNDLE_PATH|$PWD\" >> \"$BOUND_TEST_CALLS\"\n")
        executable.chmod(0o700)
        environment = {**os.environ, "PATH": str(self.base) + ":" + os.environ["PATH"], "BOUND_TEST_CALLS": str(calls)}
        environment.pop("BUNDLE_PATH", None)
        subprocess.run([str(launcher), "--check-environment"], cwd=self.base, env=environment, check=True)
        self.assertEqual(calls.read_text().splitlines(), [f"check|{root}/Gemfile|{root}/.build/gems|{root}"])
        subprocess.run([str(launcher), "beta", "check:true"], cwd=self.base, env=environment, check=True)
        self.assertEqual(calls.read_text().splitlines()[-1], f"exec fastlane beta check:true|{root}/Gemfile|{root}/.build/gems|{root}")

    def test_missing_gems_stop_before_fastlane(self):
        launcher = Path(__file__).with_name("fastlane-local").resolve()
        executable = self.base / "bundle"
        calls = self.base / "calls"
        executable.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$BOUND_TEST_CALLS\"\nexit 17\n")
        executable.chmod(0o700)
        environment = {**os.environ, "PATH": str(self.base) + ":" + os.environ["PATH"], "BOUND_TEST_CALLS": str(calls)}
        result = subprocess.run([str(launcher), "beta"], cwd=self.base, env=environment)
        self.assertEqual(result.returncode, 17)
        self.assertEqual(calls.read_text(), "check\n")

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
