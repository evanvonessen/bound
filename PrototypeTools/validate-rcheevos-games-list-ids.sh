#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
vendor="$repo_root/Vendor/rcheevos"
temp_root="$(mktemp -d "${TMPDIR:-/tmp}/bound-rcheevos-validation.XXXXXX")"
trap 'python3 -c '\''import pathlib, shutil, sys; shutil.rmtree(pathlib.Path(sys.argv[1]), ignore_errors=True)'\'' "$temp_root"' EXIT
clang -std=c11 -Wall -Wextra -ffunction-sections -fdata-sections -DRC_DISABLE_LUA \
  -I "$vendor/include" -I "$vendor/src/rcheevos" \
  "$repo_root/PrototypeTests/rcheevos_games_list_id_validation.c" \
  "$vendor/src/rapi/rc_api_info.c" \
  "$vendor/src/rapi/rc_api_common.c" \
  "$vendor/src/rc_compat.c" \
  "$vendor/src/rc_util.c" \
  -Wl,-dead_strip -lm -o "$temp_root/rcheevos-games-list-ids"
binary="$temp_root/rcheevos-games-list-ids"
"$binary"
