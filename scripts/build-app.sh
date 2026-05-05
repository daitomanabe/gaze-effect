#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="GazeEffectPreview"
PRODUCT_NAME="GazeEffectPreviewApp"
APP_DIR="${ROOT_DIR}/build/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
INFO_PLIST="${ROOT_DIR}/Resources/GazeEffectPreviewApp/Info.plist"
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-Apple Development: DAITO MANABE (8W8KF3UZ2J)}"

cd "${ROOT_DIR}"

set +e
swift build -c release --product "${PRODUCT_NAME}"
BUILD_STATUS=$?
set -e

if [ "${BUILD_STATUS}" -ne 0 ]; then
  if [ ! -x "${ROOT_DIR}/.build/release/${PRODUCT_NAME}" ]; then
    echo "swift build failed and no release binary was produced." >&2
    exit "${BUILD_STATUS}"
  fi

  echo "swift build returned ${BUILD_STATUS}, but the release binary exists; continuing." >&2
fi

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp -X "${ROOT_DIR}/.build/release/${PRODUCT_NAME}" "${MACOS_DIR}/${PRODUCT_NAME}"
cp -X "${INFO_PLIST}" "${CONTENTS_DIR}/Info.plist"
chmod 755 "${MACOS_DIR}/${PRODUCT_NAME}"

if security find-identity -v | grep -F "${APP_SIGN_IDENTITY}" >/dev/null 2>&1; then
  codesign --force --sign "${APP_SIGN_IDENTITY}" "${APP_DIR}"
else
  codesign --force --sign - "${APP_DIR}"
fi

codesign --verify --deep --strict --verbose=2 "${APP_DIR}"

echo "${APP_DIR}"
