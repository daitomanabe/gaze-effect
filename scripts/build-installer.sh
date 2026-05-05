#!/bin/sh
set -eu

VERSION="0.1.0"
PRODUCT_NAME="GazeEffect-DeveloperPreview"
IDENTIFIER="ws.daito.gaze-effect.devpreview"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build/installer"
PKG_ROOT="${BUILD_DIR}/pkgroot"
OUTPUT_DIR="${ROOT_DIR}/dist"
OUTPUT_PKG="${OUTPUT_DIR}/${PRODUCT_NAME}-${VERSION}.pkg"
UNSIGNED_PKG="${BUILD_DIR}/${PRODUCT_NAME}-${VERSION}.unsigned.pkg"
DEVELOPER_ID_INSTALLER="${DEVELOPER_ID_INSTALLER:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

export COPYFILE_DISABLE=1

cd "${ROOT_DIR}"

set +e
swift build -c release --product GazeEffectCoreCheck
BUILD_STATUS=$?
set -e

if [ "${BUILD_STATUS}" -ne 0 ]; then
  if [ ! -x "${ROOT_DIR}/.build/release/GazeEffectCoreCheck" ]; then
    echo "swift build failed and no release binary was produced." >&2
    exit "${BUILD_STATUS}"
  fi

  echo "swift build returned ${BUILD_STATUS}, but the release binary exists; continuing." >&2
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${PKG_ROOT}/usr/local/bin"
mkdir -p "${PKG_ROOT}/usr/local/share/gaze-effect"
mkdir -p "${OUTPUT_DIR}"

cp -X "${ROOT_DIR}/.build/release/GazeEffectCoreCheck" "${PKG_ROOT}/usr/local/bin/gaze-effect-check"
cp -X "${ROOT_DIR}/README.md" "${PKG_ROOT}/usr/local/share/gaze-effect/README.md"
cp -X "${ROOT_DIR}/LICENSE" "${PKG_ROOT}/usr/local/share/gaze-effect/LICENSE"

chmod 755 "${PKG_ROOT}/usr/local/bin/gaze-effect-check"

if command -v xattr >/dev/null 2>&1; then
  xattr -cr "${PKG_ROOT}"
fi

pkgbuild \
  --root "${PKG_ROOT}" \
  --identifier "${IDENTIFIER}" \
  --version "${VERSION}" \
  --install-location "/" \
  "${UNSIGNED_PKG}"

if [ -n "${DEVELOPER_ID_INSTALLER}" ]; then
  productsign \
    --sign "${DEVELOPER_ID_INSTALLER}" \
    "${UNSIGNED_PKG}" \
    "${OUTPUT_PKG}"
else
  cp -X "${UNSIGNED_PKG}" "${OUTPUT_PKG}"
fi

if [ -n "${NOTARY_PROFILE}" ]; then
  if [ -z "${DEVELOPER_ID_INSTALLER}" ]; then
    echo "NOTARY_PROFILE requires DEVELOPER_ID_INSTALLER." >&2
    exit 1
  fi

  xcrun notarytool submit "${OUTPUT_PKG}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait
  xcrun stapler staple "${OUTPUT_PKG}"
fi

set +e
pkgutil --check-signature "${OUTPUT_PKG}"
SIGNATURE_STATUS=$?
spctl --assess --type install -vv "${OUTPUT_PKG}"
ASSESS_STATUS=$?
set -e

if [ -n "${NOTARY_PROFILE}" ] && [ "${ASSESS_STATUS}" -ne 0 ]; then
  echo "Gatekeeper assessment failed after notarization." >&2
  exit "${ASSESS_STATUS}"
fi

if [ "${SIGNATURE_STATUS}" -ne 0 ]; then
  echo "Built unsigned developer-preview package." >&2
fi

echo "${OUTPUT_PKG}"
