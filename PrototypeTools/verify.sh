#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
logs="$(pwd)/.build/verification/latest"
mkdir -p "$logs"
PrototypeTools/prepare.sh > "$logs/prepare.log" 2>&1
PrototypeTools/validate-sfml-strings.sh > "$logs/sfml-strings.log" 2>&1
swift test --package-path PrototypeTests > "$logs/models.log" 2>&1
if [[ -z "${QA_SIMULATOR_ID:-}" ]]; then
    QA_SIMULATOR_ID="$(xcrun simctl list devices available -j | PrototypeTools/qa-python -c 'import json,sys; d=json.load(sys.stdin); print(next((v["udid"] for a in d["devices"].values() for v in a if v["name"]=="Bound Gameplay Pacing QA"), ""))')"
fi
if [[ -z "$QA_SIMULATOR_ID" ]]; then
    echo 'Set QA_SIMULATOR_ID to a dedicated iOS Simulator; personal ROMs are not needed.' >&2
    exit 1
fi
xcrun simctl boot "$QA_SIMULATOR_ID" > /dev/null 2>&1 || true
xcrun simctl bootstatus "$QA_SIMULATOR_ID" -b > "$logs/simulator.log" 2>&1
qa_derived="${QA_DERIVED_DATA:-$(pwd)/.build/DerivedData}"
common=(-project Bound.xcodeproj -configuration Debug -destination "platform=iOS Simulator,id=$QA_SIMULATOR_ID" -derivedDataPath "$qa_derived" -parallel-testing-enabled NO IPHONEOS_DEPLOYMENT_TARGET=17.0 ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- -collect-test-diagnostics never -test-timeouts-enabled YES -default-test-execution-time-allowance 300 -maximum-test-execution-time-allowance 360)
# This suite injects offline transport. It never constructs a live RTC engine.
xcodebuild "${common[@]}" -scheme BoundIntegrationQA test > "$logs/integration.log" 2>&1
PrototypeTools/qa-python PrototypeTools/generate_diagnostic.py .build/fixtures/BoundDiagnostic.gba > "$logs/fixture.log"
xcrun simctl launch "$QA_SIMULATOR_ID" com.evanvonessen.bound > /dev/null
xcrun simctl openurl "$QA_SIMULATOR_ID" "file://$(pwd)/.build/fixtures/BoundDiagnostic.gba"
# Stage a distinct original cartridge for the real Files picker (not openURL).
container="$(xcrun simctl get_app_container "$QA_SIMULATOR_ID" com.evanvonessen.bound data)"
mkdir -p "$container/Documents/PickerImportQA"
PrototypeTools/qa-python - "$container/Documents/PickerImportQA/BoundPickerDiagnostic.gba" <<'FIXTURE'
import sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(Path('.build/fixtures/BoundDiagnostic.gba').read_bytes() + b'Bound 2 original picker verification cartridge')
FIXTURE
xcodebuild "${common[@]}" -scheme BoundCompanionQA test > "$logs/ui.log" 2>&1
# Generic unsigned build does not create/download signing assets or install a phone app.
xcodebuild -project Bound.xcodeproj -scheme Bound -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "${PHONE_DERIVED_DATA:-$(pwd)/.build/ReleaseDerivedData}" IPHONEOS_DEPLOYMENT_TARGET=17.0 ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build > "$logs/release.log" 2>&1
printf 'Model, offline integration/benchmark, UI and unsigned Release checks passed. Logs: %s\n' "$logs"
