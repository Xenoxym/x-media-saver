#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACT_ROOT="${PROJECT_ROOT}/artifacts"
LOG_ROOT="${ARTIFACT_ROOT}/logs"
DERIVED_DATA="${PROJECT_ROOT}/build/DerivedData"
APP_PATH="${DERIVED_DATA}/Build/Products/Release-iphoneos/XMediaSaver.app"
STAGING_ROOT="${PROJECT_ROOT}/build/ipa-staging"
IPA_PATH="${ARTIFACT_ROOT}/XMediaSaver-unsigned.ipa"
BUILD_LOG="${LOG_ROOT}/xcodebuild.log"

mkdir -p "${LOG_ROOT}"

set +e
xcodebuild \
  -project "${PROJECT_ROOT}/XMediaSaver.xcodeproj" \
  -scheme XMediaSaver \
  -configuration Release \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath "${DERIVED_DATA}" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  clean build 2>&1 | tee "${BUILD_LOG}"
build_status=${PIPESTATUS[0]}
set -e

if [[ ${build_status} -ne 0 ]]; then
  echo "xcodebuild failed with status ${build_status}." >&2
  exit "${build_status}"
fi

if [[ ! -d "${APP_PATH}" ]]; then
  echo "Expected app bundle was not produced: ${APP_PATH}" >&2
  exit 1
fi

if [[ ! -f "${APP_PATH}/XMediaSaver" ]]; then
  echo "Expected app executable was not produced." >&2
  exit 1
fi

file "${APP_PATH}/XMediaSaver" | tee "${LOG_ROOT}/app-binary.log"
/usr/bin/otool -hv "${APP_PATH}/XMediaSaver" \
  | tee "${LOG_ROOT}/mach-header.log"
/usr/bin/codesign -dvv "${APP_PATH}" \
  >"${LOG_ROOT}/codesign-inspection.log" 2>&1 || true

rm -rf "${STAGING_ROOT}"
mkdir -p "${STAGING_ROOT}/Payload"
cp -R "${APP_PATH}" "${STAGING_ROOT}/Payload/"
rm -f "${IPA_PATH}"
(
  cd "${STAGING_ROOT}"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent Payload "${IPA_PATH}"
)

if [[ ! -s "${IPA_PATH}" ]]; then
  echo "IPA packaging failed or produced an empty file." >&2
  exit 1
fi

/usr/bin/unzip -t "${IPA_PATH}" | tee "${LOG_ROOT}/ipa-integrity.log"
/usr/bin/shasum -a 256 "${IPA_PATH}" | tee "${LOG_ROOT}/ipa-sha256.log"

echo "Created unsigned IPA: ${IPA_PATH}"
echo "This artifact contains no provisioning profile or Apple credentials."
