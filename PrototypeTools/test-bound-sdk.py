#!/usr/bin/env python3
"""Verify SDK import rejection and native primitive equivalence in isolated outputs."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if not os.environ.get("BOUND_GAME_SOURCE"):
        raise SystemExit("Set BOUND_GAME_SOURCE explicitly")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    # Each check uses a copied minimal host tree. Actual generated definitions
    # and the paired game checkout stay unchanged during rejection probes.
    probe = output / "import-probe"
    if probe.exists():
        raise SystemExit("Use a fresh output directory; retained probes must not be overwritten")
    for relative in ("PrototypeTools/sync-bound-sdk.py", "PrototypeConfiguration/integrated-game.json"):
        target = probe / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / relative, target)
    shutil.copytree(ROOT / "Delta/Bound/SDK/Generated", probe / "Delta/Bound/SDK/Generated")
    shutil.copy2(ROOT / "Delta/Bound/SDK/bound_sdk.h", probe / "Delta/Bound/SDK/bound_sdk.h")
    command = [str(ROOT / "PrototypeTools/qa-python"), str(probe / "PrototypeTools/sync-bound-sdk.py"), "--check"]
    baseline = subprocess.run(command, capture_output=True, text=True)
    (output / "import-baseline.log").write_text(baseline.stdout + baseline.stderr)
    if baseline.returncode:
        raise SystemExit("Clean SDK import check failed")
    rejected = []
    paths = ["Generated/BoundSDKProtocol.swift", "Generated/BoundSDKProtocol.h", "Generated/metadata.json",
             "Generated/protocol-v1.json", "bound_sdk.h"]
    for relative in paths:
        path = probe / "Delta/Bound/SDK" / relative
        original = path.read_bytes()
        path.write_bytes(original + b"\n/* stale output */\n")
        result = subprocess.run(command, capture_output=True, text=True)
        (output / (path.name + ".rejection.log")).write_text(result.stdout + result.stderr)
        path.write_bytes(original)
        if result.returncode == 0:
            raise SystemExit("Stale SDK output was accepted: " + relative)
        rejected.append(relative)
    source = output / "native-primitives.c"
    source.write_text(r'''#include <assert.h>
#include <stdint.h>
#include <string.h>
#include "bound_sdk.h"
#include "Generated/BoundSDKProtocol.h"
static uint32_t original_word(const uint8_t *p) {
    return p[0]|uint32_t(p[1])<<8|uint32_t(p[2])<<16|uint32_t(p[3])<<24;
}
static void original_put(uint8_t *p,uint32_t v) {
    p[0]=uint8_t(v);p[1]=uint8_t(v>>8);p[2]=uint8_t(v>>16);p[3]=uint8_t(v>>24);
}
int main(void) {
    static_assert(BOUND_SDK_UIHOST_BYTE_SIZE==2048 && BOUND_SDK_UIREQUEST_BYTE_SIZE==256);
    static_assert(BOUND_SDK_COOPERATIVE_HOST_BYTE_SIZE==16384 && BOUND_SDK_GAME_SNAPSHOT_BYTE_SIZE==960);
    const uint32_t limits[]={0,1,2,3,0x7fffffff,0x80000000,0xfffffffd,0xfffffffe,0xffffffff};
    uint8_t old[4],now[4];
    for(uint32_t i=0;i<65536+9;++i) {
        uint32_t v=i<65536 ? i*65537u : limits[i-65536];
        original_put(old,v);bound_sdk_store_le32(now,v);
        assert(!memcmp(old,now,4));assert(original_word(old)==bound_sdk_load_le32(now));
        assert((uint16_t(v))==bound_sdk_load_le16(now));
        for(uint32_t after:limits) {
            assert(bound_sdk_same_committed_sequence(v,after)==(v!=0 && !(v&1) && v==after));
        }
        uint32_t oldNext=v+2;if(!oldNext || (oldNext&1))oldNext=2;
        uint32_t newNext;BOUND_SDK_ADVANCE_SEQUENCE(newNext,v);assert(oldNext==newNext);
    }
    return 0;
}
''')
    binary = output / "native-primitives"
    compile_result = subprocess.run(["/usr/bin/xcrun", "clang++", "-std=c++17", "-x", "c++", "-Wall", "-Wextra", "-Werror",
                                     "-I", str(ROOT / "Delta/Bound/SDK"), str(source), "-o", str(binary)],
                                    capture_output=True, text=True)
    (output / "native-compile.log").write_text(compile_result.stdout + compile_result.stderr)
    if compile_result.returncode:
        raise SystemExit("SDK native primitive test did not compile")
    native = subprocess.run([str(binary)], capture_output=True, text=True)
    (output / "native-run.log").write_text(native.stdout + native.stderr)
    if native.returncode:
        raise SystemExit("SDK native primitive equivalence failed")
    result = {"passed": True, "stale_outputs_rejected": rejected,
              "native_scalar_vectors": 65545, "native_sequence_comparisons": 65545 * 9}
    (output / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
