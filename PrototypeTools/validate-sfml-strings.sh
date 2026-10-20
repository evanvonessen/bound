#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
sfml_root="$repo_root/Cores/GBADeltaCore/SFML"
temp_root="$(mktemp -d "${TMPDIR:-/tmp}/bound-sfml-validation.XXXXXX")"
trap 'python3 -c '\''import pathlib, shutil, sys; shutil.rmtree(pathlib.Path(sys.argv[1]), ignore_errors=True)'\'' "$temp_root"' EXIT

# Use the project's C++11 mode, with deprecated library usage treated as errors.
xcrun --sdk macosx clang++ -std=c++11 -Wall -Wextra -Werror -DSFML_STATIC \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I "$sfml_root/include" \
  "$repo_root/PrototypeTests/sfml_string_validation.cpp" \
  "$sfml_root/src/SFML/System/String.cpp" \
  -o "$temp_root/sfml-strings"
"$temp_root/sfml-strings"

# Also validate the actual iPhone SDK headers and target architecture.
xcrun --sdk iphoneos clang++ -std=c++11 -Wall -Wextra -Werror -DSFML_STATIC \
  -target arm64-apple-ios17.0 -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -I "$sfml_root/include" -fsyntax-only \
  "$repo_root/PrototypeTests/sfml_string_validation.cpp" \
  "$sfml_root/src/SFML/System/String.cpp"
