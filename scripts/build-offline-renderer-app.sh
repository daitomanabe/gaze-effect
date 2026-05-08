#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="GazeEffectOfflineRenderer"
PRODUCT_NAME="GazeEffectOfflineRendererApp"
HELPER_PRODUCT_NAME="GazeEffectImageTool"
APP_DIR="${ROOT_DIR}/build/${APP_NAME}.app"
SWIFTPM_BUILD_PATH="${SWIFTPM_BUILD_PATH:-${TMPDIR:-/tmp}/gaze-effect-swiftpm-app}"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
INFO_PLIST="${ROOT_DIR}/Resources/GazeEffectOfflineRendererApp/Info.plist"
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-Apple Development: DAITO MANABE (8W8KF3UZ2J)}"

cd "${ROOT_DIR}"

build_product() {
  PRODUCT="$1"
  BINARY_PATH="${SWIFTPM_BUILD_PATH}/release/${PRODUCT}"

  set +e
  swift build -c release --product "${PRODUCT}" --build-path "${SWIFTPM_BUILD_PATH}"
  BUILD_STATUS=$?
  set -e

  if [ "${BUILD_STATUS}" -ne 0 ]; then
    if [ ! -x "${BINARY_PATH}" ]; then
      echo "swift build failed for ${PRODUCT}, and no release binary was produced." >&2
      exit "${BUILD_STATUS}"
    fi

    echo "swift build returned ${BUILD_STATUS} for ${PRODUCT}, but the release binary exists; continuing." >&2
  fi
}

build_product "${PRODUCT_NAME}"
build_product "${HELPER_PRODUCT_NAME}"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}/scripts"

cp -X "${SWIFTPM_BUILD_PATH}/release/${PRODUCT_NAME}" "${MACOS_DIR}/${PRODUCT_NAME}"
cp -X "${SWIFTPM_BUILD_PATH}/release/${HELPER_PRODUCT_NAME}" "${MACOS_DIR}/${HELPER_PRODUCT_NAME}"
cp -X "${INFO_PLIST}" "${CONTENTS_DIR}/Info.plist"
cp -X "${ROOT_DIR}/scripts/mediapipe-eye-landmarks.py" "${RESOURCES_DIR}/scripts/mediapipe-eye-landmarks.py"
chmod 755 "${MACOS_DIR}/${PRODUCT_NAME}" "${MACOS_DIR}/${HELPER_PRODUCT_NAME}" "${RESOURCES_DIR}/scripts/mediapipe-eye-landmarks.py"

if security find-identity -v | grep -F "${APP_SIGN_IDENTITY}" >/dev/null 2>&1; then
  codesign --force --deep --sign "${APP_SIGN_IDENTITY}" "${APP_DIR}"
else
  codesign --force --deep --sign - "${APP_DIR}"
fi

codesign --verify --deep --strict --verbose=2 "${APP_DIR}"

echo "${APP_DIR}"
