#!/usr/bin/env bash
set -euo pipefail

WORKDIR="${PWD}"
ASEPRITE_DIR="${WORKDIR}/aseprite"
BUILD_DIR="${ASEPRITE_DIR}/build"
BUILD_TYPE="${BUILD_TYPE:-Release}"
SKIA_ARCH="${SKIA_ARCH:-arm64}"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-10.14}"

command -v brew >/dev/null 2>&1 || { echo "Homebrew not found. Please install Homebrew first." >&2; exit 1; }
brew list --versions cmake >/dev/null 2>&1 || brew install cmake
brew list --versions ninja >/dev/null 2>&1 || brew install ninja
brew list --versions jpeg-turbo >/dev/null 2>&1 || brew install jpeg-turbo

if [ ! -d "${ASEPRITE_DIR}/.git" ]; then
  git clone --recursive https://github.com/aseprite/aseprite.git "${ASEPRITE_DIR}"
else
  git -C "${ASEPRITE_DIR}" fetch --tags origin
fi

if [ -z "${ASEPRITE_VERSION:-}" ]; then
  ASEPRITE_VERSION="$(git -C "${ASEPRITE_DIR}" tag --sort=creatordate | tail -n1)"
fi
[ -n "${ASEPRITE_VERSION}" ] || { echo "Unable to detect ASEPRITE_VERSION" >&2; exit 1; }
echo "Building Aseprite ${ASEPRITE_VERSION} (${BUILD_TYPE}, Skia ${SKIA_ARCH})"

git -C "${ASEPRITE_DIR}" clean -fdx
git -C "${ASEPRITE_DIR}" submodule foreach --recursive git clean -xfd || true
git -C "${ASEPRITE_DIR}" fetch --depth=1 --no-tags origin "${ASEPRITE_VERSION}:refs/remotes/origin/${ASEPRITE_VERSION}" || true
git -C "${ASEPRITE_DIR}" -c advice.detachedHead=false switch --detach "${ASEPRITE_VERSION}" || git -C "${ASEPRITE_DIR}" checkout "${ASEPRITE_VERSION}"
git -C "${ASEPRITE_DIR}" submodule update --init --recursive

ASEPRITE_CMAKE_VERSION="${ASEPRITE_VERSION#v}-dev"
python3 - <<PY2
from pathlib import Path
path = Path(r"${ASEPRITE_DIR}/src/ver/CMakeLists.txt")
text = path.read_text()
path.write_text(text.replace('set(VERSION "1.x-dev")', 'set(VERSION "1.x-dev" CACHE STRING "Version of Aseprite")'))
PY2

SKIA_URL="$(bash -c "cd '${ASEPRITE_DIR}' && source laf/misc/skia-url.sh" | xargs)"
SKIA_FILE="$(basename "${SKIA_URL}")"
SKIA_DIR="${WORKDIR}/skia"
if [ ! -d "${SKIA_DIR}/out/Release-${SKIA_ARCH}" ]; then
  rm -rf "${SKIA_DIR}"
  curl --ssl-revoke-best-effort -fsSL -o "${WORKDIR}/${SKIA_FILE}" "${SKIA_URL}"
  unzip -q "${WORKDIR}/${SKIA_FILE}" -d "${SKIA_DIR}"
  rm -f "${WORKDIR}/${SKIA_FILE}"
fi

cmake -S "${ASEPRITE_DIR}" -B "${BUILD_DIR}" -G Ninja \
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
  -DVERSION="${ASEPRITE_CMAKE_VERSION}" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" \
  -DENABLE_TESTS=OFF \
  -DENABLE_SCRIPTING=ON \
  -DENABLE_CCACHE=OFF \
  -DLAF_BACKEND=skia \
  -DSKIA_DIR="${SKIA_DIR}" \
  -DSKIA_LIBRARY_DIR="${SKIA_DIR}/out/Release-${SKIA_ARCH}" \
  -DLIBJPEG_TURBO_INCLUDE_DIR="$(brew --prefix jpeg-turbo)/include" \
  -DLIBJPEG_TURBO_LIBRARY="$(brew --prefix jpeg-turbo)/lib/libjpeg.a" \
  -DPNG_ARM_NEON=off

ninja -C "${BUILD_DIR}" aseprite

BIN_DIR="${BUILD_DIR}/bin"
OUTDIR="${WORKDIR}/aseprite-${ASEPRITE_VERSION}"
rm -rf "${OUTDIR}"
mkdir -p "${OUTDIR}"
if [ -d "${BIN_DIR}/Aseprite.app" ]; then
  cp -R "${BIN_DIR}/Aseprite.app" "${OUTDIR}/"
else
  echo "Error: built app not found" >&2
  exit 1
fi
cp -R "${ASEPRITE_DIR}/docs" "${OUTDIR}/docs" 2>/dev/null || true
echo "# This file is here so Aseprite behaves as a portable program" > "${OUTDIR}/aseprite.ini"

if [ -n "${GITHUB_WORKFLOW:-}" ]; then
  echo "ASEPRITE_VERSION=${ASEPRITE_VERSION}" >> "${GITHUB_OUTPUT:-/dev/null}" || true
fi

echo "Done. Packaged: ${OUTDIR}"
