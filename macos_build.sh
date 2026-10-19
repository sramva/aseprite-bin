#!/usr/bin/env bash
#
# Builds Aseprite on macOS and packages it as a portable folder
# (aseprite-<version>/) containing Aseprite.app.
# Run from the repository root.
#
# Environment:
#   ASEPRITE_VERSION         tag to build (default: newest tag of the repo)
#   BUILD_TYPE               CMake build type (default: Release)
#   SKIA_ARCH                skia architecture (default: arm64)
#   MACOSX_DEPLOYMENT_TARGET minimum macOS version (default: 10.14)

set -euo pipefail

WORKDIR="${PWD}"
ASEPRITE_DIR="${WORKDIR}/aseprite"
BUILD_DIR="${ASEPRITE_DIR}/build"
BUILD_TYPE="${BUILD_TYPE:-Release}"
SKIA_ARCH="${SKIA_ARCH:-arm64}"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-10.14}"

# ASEPRITE_VERSION comes from the environment (or the newest tag, see
# resolve_version); the rest is filled in by resolve_version.
ASEPRITE_VERSION="${ASEPRITE_VERSION:-}"
ASEPRITE_CMAKE_VERSION=""
OUTDIR=""

die() { echo "ERROR: $*" >&2; exit 1; }


# --- dependencies ------------------------------------------------------------

install_dependencies() {
  command -v brew >/dev/null 2>&1 || die "Homebrew not found. Please install Homebrew first."
  local formula
  for formula in cmake ninja jpeg-turbo; do
    brew list --versions "${formula}" >/dev/null 2>&1 || brew install "${formula}"
  done
}


# --- sources -----------------------------------------------------------------

update_repository() {
  if [ ! -d "${ASEPRITE_DIR}/.git" ]; then
    git clone --recursive https://github.com/aseprite/aseprite.git "${ASEPRITE_DIR}"
  else
    git -C "${ASEPRITE_DIR}" fetch --tags origin
  fi
}

# Fills ASEPRITE_VERSION, ASEPRITE_CMAKE_VERSION and OUTDIR.
resolve_version() {
  if [ -z "${ASEPRITE_VERSION}" ]; then
    ASEPRITE_VERSION="$(git -C "${ASEPRITE_DIR}" tag --sort=creatordate | tail -n1)"
  fi
  [ -n "${ASEPRITE_VERSION}" ] || die "unable to detect ASEPRITE_VERSION"

  ASEPRITE_CMAKE_VERSION="${ASEPRITE_VERSION#v}-dev"
  OUTDIR="${WORKDIR}/aseprite-${ASEPRITE_VERSION}"
}

checkout_tag() {
  git -C "${ASEPRITE_DIR}" clean -fdx
  git -C "${ASEPRITE_DIR}" submodule foreach --recursive git clean -xfd || true
  git -C "${ASEPRITE_DIR}" fetch --depth=1 --no-tags origin \
    "${ASEPRITE_VERSION}:refs/remotes/origin/${ASEPRITE_VERSION}" || true
  git -C "${ASEPRITE_DIR}" -c advice.detachedHead=false switch --detach "${ASEPRITE_VERSION}" \
    || git -C "${ASEPRITE_DIR}" checkout "${ASEPRITE_VERSION}"
  git -C "${ASEPRITE_DIR}" submodule update --init --recursive
}

# Lets CMake accept -DVERSION=<tag> instead of the hardcoded "1.x-dev".
patch_version_file() {
  python3 - <<PY
from pathlib import Path
path = Path(r"${ASEPRITE_DIR}/src/ver/CMakeLists.txt")
text = path.read_text()
path.write_text(text.replace('set(VERSION "1.x-dev")', 'set(VERSION "1.x-dev" CACHE STRING "Version of Aseprite")'))
PY
}


# --- skia --------------------------------------------------------------------

# Fills SKIA_URL, SKIA_FILE and SKIA_DIR.
download_skia() {
  SKIA_URL="$(bash -c "cd '${ASEPRITE_DIR}' && source laf/misc/skia-url.sh" | xargs)"
  [ -n "${SKIA_URL}" ] || die "unable to resolve skia url"
  SKIA_FILE="$(basename "${SKIA_URL}")"
  SKIA_DIR="${WORKDIR}/skia"

  if [ ! -d "${SKIA_DIR}/out/Release-${SKIA_ARCH}" ]; then
    rm -rf "${SKIA_DIR}"
    curl --ssl-revoke-best-effort -fsSL -o "${WORKDIR}/${SKIA_FILE}" "${SKIA_URL}"
    unzip -q "${WORKDIR}/${SKIA_FILE}" -d "${SKIA_DIR}"
    rm -f "${WORKDIR}/${SKIA_FILE}"
  fi
}


# --- build -------------------------------------------------------------------

build_aseprite() {
  local jpeg_prefix
  jpeg_prefix="$(brew --prefix jpeg-turbo)"

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
    -DLIBJPEG_TURBO_INCLUDE_DIR="${jpeg_prefix}/include" \
    -DLIBJPEG_TURBO_LIBRARY="${jpeg_prefix}/lib/libjpeg.a" \
    -DPNG_ARM_NEON=off

  ninja -C "${BUILD_DIR}" aseprite
}


# --- packaging ---------------------------------------------------------------

package_portable() {
  local app="${BUILD_DIR}/bin/Aseprite.app"
  [ -d "${app}" ] || die "built app not found: ${app}"

  rm -rf "${OUTDIR}"
  mkdir -p "${OUTDIR}"
  cp -R "${app}" "${OUTDIR}/"
  cp -R "${ASEPRITE_DIR}/docs" "${OUTDIR}/docs" 2>/dev/null || true
  echo "# This file is here so Aseprite behaves as a portable program" > "${OUTDIR}/aseprite.ini"
}


# --- report ------------------------------------------------------------------

report_version() {
  if [ -n "${GITHUB_WORKFLOW:-}" ]; then
    echo "ASEPRITE_VERSION=${ASEPRITE_VERSION}" >> "${GITHUB_OUTPUT:-/dev/null}" || true
  fi
}


main() {
  install_dependencies
  update_repository
  resolve_version
  echo "Building Aseprite ${ASEPRITE_VERSION} (${BUILD_TYPE}, Skia ${SKIA_ARCH})"
  checkout_tag
  patch_version_file
  download_skia
  build_aseprite
  package_portable
  report_version
  echo "Done. Packaged: ${OUTDIR}"
}

main "$@"
