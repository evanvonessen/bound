#!/usr/bin/env python3
"""Remove only stale multiplayer resources from this Xcode build product.

No download, publication, library, cache or save operations belong in app builds.
"""
import os
from pathlib import Path


def remove_legacy_resources(build_directory, resources_path):
    build = Path(build_directory)
    relative = Path(resources_path)
    if not build.is_absolute() or relative.is_absolute() or '..' in relative.parts or not relative.parts:
        raise ValueError('Expected an absolute Xcode build directory and relative app resources path')
    resources = build / relative
    if not resources.resolve().is_relative_to(build.resolve()):
        raise ValueError('App resources escaped the build directory')
    for name in ('multiplayer.gba', 'rrbin-integrated.gba', 'RRv4.1M.gba', 'firered-cover.png'):
        path = resources / name
        if path.is_symlink() or path.is_file():
            path.unlink()


if __name__ == '__main__':
    remove_legacy_resources(os.environ['TARGET_BUILD_DIR'], os.environ['UNLOCALIZED_RESOURCES_FOLDER_PATH'])
