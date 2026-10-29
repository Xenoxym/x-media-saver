#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "${PROJECT_ROOT}/artifacts/logs"
SIMULATOR_ID="$(xcrun simctl list devices available -j | python3 -c '
import json,sys
devices=json.load(sys.stdin)["devices"]
phones=[d for runtime,items in devices.items() if ".iOS-" in runtime for d in items if d.get("isAvailable") and d["name"].startswith("iPhone")]
if not phones: raise SystemExit("No available iPhone simulator")
print(phones[0]["udid"])
')"

xcodebuild test \
  -project "${PROJECT_ROOT}/XMediaSaver.xcodeproj" \
  -scheme XMediaSaver \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=${SIMULATOR_ID}" \
  -derivedDataPath "${PROJECT_ROOT}/build/TestDerivedData" \
  -resultBundlePath "${PROJECT_ROOT}/artifacts/logs/UnitTests.xcresult" \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  2>&1 | tee "${PROJECT_ROOT}/artifacts/logs/unit-tests.log"
