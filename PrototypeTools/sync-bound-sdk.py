#!/usr/bin/env python3
"""Import or verify the game-owned SDK schema and exact generated host definitions.

Run through qa-python with an explicit BOUND_GAME_SOURCE. Checking regenerates
in memory; it never invokes a game build or changes the paired game checkout.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / "Delta/Bound/SDK/Generated"


def expected_files(game: Path) -> dict[str, bytes]:
    generator = game / "tools/generate_bound_sdk.py"
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("bound_game_sdk_generator", generator)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    files = module.generate()
    files["protocol-v1.json"] = module.SCHEMA.read_bytes()
    files["bound_sdk.h"] = module.LIBRARY.read_bytes()
    metadata = json.loads(files["metadata.json"])
    if metadata["schemaOwner"] != "multi_red/source/multiplayer/sdk/protocol-v1.json":
        raise ValueError("Unexpected SDK schema owner")
    if metadata["schemaSHA256"] != hashlib.sha256(files["protocol-v1.json"]).hexdigest():
        raise ValueError("SDK schema digest differs")
    for name, digest in {**metadata["outputs"], **metadata["library"]}.items():
        if hashlib.sha256(files[name]).hexdigest() != digest:
            raise ValueError(f"SDK generated digest differs: {name}")
    schema = json.loads(files["protocol-v1.json"])
    contract = json.loads((ROOT / "PrototypeConfiguration/integrated-game.json").read_text())["contract"]
    for name, size, major, minor in (
        ("GameHost", "host_port_size", "abi_major", "abi_minor"),
        ("GameSnapshot", "snapshot_size", "abi_major", "abi_minor"),
        ("UIHost", "ui_host_port_size", "ui_abi_major", "ui_abi_minor"),
        ("UIRequest", "ui_snapshot_size", "ui_abi_major", "ui_abi_minor"),
        ("CooperativeHost", "cooperative_host_port_size", "cooperative_abi_major", "cooperative_abi_minor"),
        ("CooperativeSnapshot", "cooperative_snapshot_size", "cooperative_abi_major", "cooperative_abi_minor"),
    ):
        if size not in contract:
            continue
        layout = schema["layouts"][name]
        if (layout["byte_size"], layout["major"], layout["minor"]) != (contract[size], contract[major], contract[minor]):
            raise ValueError(f"SDK layout differs from the admitted cartridge contract: {name}")
    return files


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--from-game", type=Path, help="Reviewed SDK export directory to import")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    source = os.environ.get("BOUND_GAME_SOURCE")
    if not source:
        raise SystemExit("Set BOUND_GAME_SOURCE explicitly; implicit sibling checkouts are not supported")
    if not args.check and args.from_game is None:
        raise SystemExit("An import requires --from-game; use --check for read-only verification")
    files = expected_files(Path(source).resolve())
    if args.from_game:
        for name, expected in files.items():
            if (args.from_game / name).read_bytes() != expected:
                raise SystemExit(f"SDK export is stale or mismatched: {name}")
    for name, expected in files.items():
        output = (DESTINATION.parent if name == "bound_sdk.h" else DESTINATION) / name
        if args.check:
            if not output.is_file() or output.read_bytes() != expected:
                raise SystemExit(f"Imported SDK output is stale or mismatched: {name}")
        else:
            DESTINATION.mkdir(parents=True, exist_ok=True)
            output.write_bytes(expected)
    print(json.dumps({"verified": True, "checked": args.check,
                      "metadata": json.loads(files["metadata.json"])}, indent=2))


if __name__ == "__main__":
    main()
