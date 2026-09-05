#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="GazeEffectCameraTest"
PRODUCT_NAME="GazeEffectPreviewApp"
APP_DIR="${ROOT_DIR}/build/${APP_NAME}.app"
SWIFTPM_BUILD_PATH="${SWIFTPM_BUILD_PATH:-${TMPDIR:-/tmp}/gaze-effect-swiftpm-app}"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
INFO_PLIST="${ROOT_DIR}/Resources/GazeEffectPreviewApp/Info.plist"
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-Apple Development: DAITO MANABE (8W8KF3UZ2J)}"

cd "${ROOT_DIR}"

set +e
swift build -c release --product "${PRODUCT_NAME}" --build-path "${SWIFTPM_BUILD_PATH}"
BUILD_STATUS=$?
set -e

BINARY_PATH="${SWIFTPM_BUILD_PATH}/release/${PRODUCT_NAME}"

if [ "${BUILD_STATUS}" -ne 0 ]; then
  exit "${BUILD_STATUS}"
fi

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp -X "${BINARY_PATH}" "${MACOS_DIR}/${PRODUCT_NAME}"
cp -X "${INFO_PLIST}" "${CONTENTS_DIR}/Info.plist"
chmod 755 "${MACOS_DIR}/${PRODUCT_NAME}"

mkdir -p "${RESOURCES_DIR}/scripts" "${RESOURCES_DIR}/models"
cp -X "${ROOT_DIR}/scripts/gaze_pipeline.py" "${ROOT_DIR}/scripts/gaze-worker.py" "${ROOT_DIR}/scripts/render-gaze-video.py" "${ROOT_DIR}/scripts/gaze-images.py" "${ROOT_DIR}/scripts/calibrate-gaze.py" "${RESOURCES_DIR}/scripts/"
cp -X "${ROOT_DIR}/Assets/models/face_landmarker.task" "${ROOT_DIR}/Assets/models/neural-manifest.json" "${ROOT_DIR}/Assets/models/gaze_L.onnx" "${ROOT_DIR}/Assets/models/gaze_R.onnx" "${RESOURCES_DIR}/models/"
cp -X "${ROOT_DIR}/THIRD_PARTY.md" "${RESOURCES_DIR}/"

if security find-identity -v | grep -F "${APP_SIGN_IDENTITY}" >/dev/null 2>&1; then
  codesign --force --sign "${APP_SIGN_IDENTITY}" "${APP_DIR}"
else
  codesign --force --sign - "${APP_DIR}"
fi

codesign --verify --deep --strict --verbose=2 "${APP_DIR}"

echo "${APP_DIR}"
