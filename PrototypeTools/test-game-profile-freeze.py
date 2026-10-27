#!/usr/bin/env python3
"""Protect frozen exact-ROM metadata from accidental current-profile imports."""
import importlib.util
import subprocess
import sys
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('profile_generator', Path(__file__).with_name('generate-bound-game-profiles.py'))
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)

class GameProfileFreezeTests(unittest.TestCase):
    def test_current_world_constants_match_imported_contract(self):
        subprocess.run([sys.executable, str(generator.ROOT / 'PrototypeTools/build-shared-world.py'), '--check'], check=True)

    def test_pre_shiny_profile_exports_exact_frozen_abi_and_library_identity(self):
        output = generator.generate()
        header = generator.ROOT / 'Delta/Bound/SharedWorld/BoundPreShinyMagikarpGameABI.h'
        self.assertEqual(output[header], (generator.PRE_SHINY_ROOT / 'BoundGameABI.h').read_bytes())
        swift = output[generator.ROOT / 'Delta/Bound/SDK/Generated/BoundGameProfiles.swift'].decode()
        self.assertIn('static let preShinyMagikarp = BoundGameProfile(', swift)
        self.assertIn('romSHA256: "fcfaa8a9fb022656994a429be4cba5b9f14ba6c477ec813d2d6a2aa3878edc00", gameID: "51ebbe0108c0c18bb5bfcbef42ed3d19a4cfd606"', swift)
        self.assertIn('all = [original, stackSafe, debugDefaults, friendsMultiview, preShinyMagikarp, preLinksMenu, current]', swift)

    def test_pre_links_profile_exports_exact_frozen_abi_and_library_identity(self):
        output = generator.generate()
        header = generator.ROOT / 'Delta/Bound/SharedWorld/BoundPreLinksMenuGameABI.h'
        self.assertEqual(output[header], (generator.PRE_LINKS_ROOT / 'BoundGameABI.h').read_bytes())
        swift = output[generator.ROOT / 'Delta/Bound/SDK/Generated/BoundGameProfiles.swift'].decode()
        self.assertIn('static let preLinksMenu = BoundGameProfile(', swift)
        self.assertIn('romSHA256: "d7d9ec63064f9ea8dae75fa2ee05817056769f2cc933f4291414267575885583", gameID: "eb96749d9ebb8c9e4300885a59b930e94e23eca3"', swift)
        self.assertIn('all = [original, stackSafe, debugDefaults, friendsMultiview, preShinyMagikarp, preLinksMenu, current]', swift)

    def reject_mutation(self, filename, message, root=None):
        target = (root or generator.PRE_SHINY_ROOT) / filename
        original = Path.read_bytes
        def read(path):
            value = original(path)
            return value + b'\n' if path == target else value
        with patch.object(Path, 'read_bytes', autospec=True, side_effect=read):
            with self.assertRaisesRegex(AssertionError, message): generator.generate()

    def test_frozen_manifest_mutation_is_rejected(self):
        self.reject_mutation('manifest.json', 'Frozen pre-shiny Magikarp manifest changed')

    def test_frozen_abi_mutation_is_rejected(self):
        self.reject_mutation('BoundGameABI.h', 'Frozen pre-shiny Magikarp ABI changed')

    def test_pre_links_frozen_manifest_mutation_is_rejected(self):
        self.reject_mutation('manifest.json', 'Frozen pre-Links menu manifest changed', generator.PRE_LINKS_ROOT)

    def test_pre_links_frozen_abi_mutation_is_rejected(self):
        self.reject_mutation('BoundGameABI.h', 'Frozen pre-Links menu ABI changed', generator.PRE_LINKS_ROOT)

if __name__ == '__main__': unittest.main()
