import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("device_qa", Path(__file__).with_name("prepare-multiplayer-device-qa.py"))
qa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qa)


class DeviceQAIsolationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        (qa.ROOT / ".build").mkdir(exist_ok=True)

    def test_generated_overrides_preserve_original_plist_and_never_claim_its_callbacks(self):
        original = (qa.ROOT / "Delta/Supporting Files/Info.plist").read_bytes()
        with tempfile.TemporaryDirectory(dir=qa.ROOT / ".build", prefix="qa-isolation-") as tmp:
            output = Path(tmp) / "prepared"
            config = qa.prepare(output)
            value = plistlib.loads((output / "Info.plist").read_bytes())
            self.assertNotIn("CFBundleURLTypes", value)
            self.assertEqual(value["CFBundleDisplayName"], qa.QA_NAME)
            self.assertEqual(plistlib.loads((output / "QA.entitlements").read_bytes()), {})
            self.assertEqual([line.split(" = ")[0] for line in config.read_text().splitlines() if " = " in line],
                             ["BOUND_APP_BUNDLE_IDENTIFIER", "BOUND_APP_INFO_PLIST", "BOUND_APP_ENTITLEMENTS"])
            with self.assertRaises(FileExistsError):
                qa.prepare(output)
        self.assertEqual((qa.ROOT / "Delta/Supporting Files/Info.plist").read_bytes(), original)

    def test_verifier_rejects_normal_bound_identity_and_mismatched_cloud_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "Bound.app"; app.mkdir()
            info = dict(CFBundleIdentifier="com.evanvonessen.bound", CFBundleDisplayName=qa.QA_NAME, BoundMultiplayerDeviceQA=True)
            (app / "Info.plist").write_bytes(plistlib.dumps(info))
            with self.assertRaises(ValueError): qa.verify(app)
            info["CFBundleIdentifier"] = qa.QA_ID
            (app / "Info.plist").write_bytes(plistlib.dumps(info))
            normal = Path(tmp) / "Normal.app"; normal.mkdir()
            (normal / "cloud-configuration.json").write_bytes(b'{}')
            with self.assertRaises(ValueError): qa.verify(app, normal)
            (app / "cloud-configuration.json").write_bytes(b'{}')
            self.assertEqual(qa.verify(app, normal)["productionCloudConfiguration"], "identical")
            info["CFBundleURLTypes"] = [{"CFBundleURLSchemes": ["delta"]}]
            (app / "Info.plist").write_bytes(plistlib.dumps(info))
            with self.assertRaises(ValueError): qa.verify(app, normal)

    def test_prepare_refuses_paths_outside_ignored_build_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError): qa.prepare(Path(tmp) / "new")
            self.assertFalse((Path(tmp) / "new").exists())


if __name__ == "__main__":
    unittest.main()
