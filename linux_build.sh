#!/usr/bin/env bash
#
# Builds Aseprite on Linux and packages it as a portable folder
# (aseprite-<version>/) plus an AppImage.
# Run from the repository root.
#
# Environment:
#   ASEPRITE_VERSION  tag to build (default: newest tag of the repo)
#   BUILD_TYPE        CMake build type (default: Release)

set -euo pipefail

WORKDIR="${PWD}"
ASEPRITE_DIR="${WORKDIR}/aseprite"
BUILD_DIR="${ASEPRITE_DIR}/build"
BUILD_TYPE="${BUILD_TYPE:-Release}"
SKIA_ARCH="x64"

# ASEPRITE_VERSION comes from the environment (or the newest tag, see
# resolve_version); the rest is filled in by resolve_version.
ASEPRITE_VERSION="${ASEPRITE_VERSION:-}"
ASEPRITE_CMAKE_VERSION=""
OUTDIR=""

die() { echo "ERROR: $*" >&2; exit 1; }


# --- dependencies ------------------------------------------------------------

install_dependencies() {
  sudo apt-get update -qq
  sudo apt-get install -y \
    build-essential clang git unzip curl cmake ninja-build xvfb \
    libpixman-1-dev libfreetype6-dev libharfbuzz-dev zlib1g-dev \
    libx11-dev libxcursor-dev libxi-dev libxrandr-dev libgl1-mesa-dev \
    libfontconfig1-dev libpng-dev libjpeg-dev libwebp-dev
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
  cmake -S "${ASEPRITE_DIR}" -B "${BUILD_DIR}" -G Ninja \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    -DVERSION="${ASEPRITE_CMAKE_VERSION}" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_POLICY_DEFAULT_CMP0074=NEW \
    -DCMAKE_POLICY_DEFAULT_CMP0091=NEW \
    -DCMAKE_POLICY_DEFAULT_CMP0092=NEW \
    -DENABLE_TESTS=OFF \
    -DENABLE_SCRIPTING=ON \
    -DENABLE_CCACHE=OFF \
    -DLAF_BACKEND=skia \
    -DSKIA_DIR="${SKIA_DIR}" \
    -DSKIA_LIBRARY_DIR="${SKIA_DIR}/out/Release-${SKIA_ARCH}"

  ninja -C "${BUILD_DIR}" aseprite
}


# --- packaging ---------------------------------------------------------------

package_portable() {
  rm -rf "${OUTDIR}"
  mkdir -p "${OUTDIR}"
  echo "# This file is here so Aseprite behaves as a portable program" > "${OUTDIR}/aseprite.ini"
  cp -r "${ASEPRITE_DIR}/docs" "${OUTDIR}/docs" 2>/dev/null || true
  cp "${BUILD_DIR}/bin/aseprite" "${OUTDIR}/"
  cp -r "${BUILD_DIR}/bin/data" "${OUTDIR}/data"
}

package_appimage() {
  local appdir="${WORKDIR}/AppDir"
  local appimagetool="${WORKDIR}/appimagetool-x86_64.AppImage"
  local size

  rm -rf "${appdir}"
  mkdir -p "${appdir}/usr/bin" "${appdir}/usr/share/applications"
  for size in 16 20 24 28 32 48 64 128 256; do
    mkdir -p "${appdir}/usr/share/icons/hicolor/${size}x${size}/apps"
    if [ -f "${ASEPRITE_DIR}/data/icons/ase${size}.png" ]; then
      cp "${ASEPRITE_DIR}/data/icons/ase${size}.png" \
         "${appdir}/usr/share/icons/hicolor/${size}x${size}/apps/aseprite.png"
    fi
  done
  cp "${ASEPRITE_DIR}/data/icons/ase256.png" "${appdir}/aseprite.png"
  cp "${BUILD_DIR}/bin/aseprite" "${appdir}/usr/bin/aseprite"
  cp -r "${BUILD_DIR}/bin/data" "${appdir}/usr/bin/data"

  cat > "${appdir}/aseprite.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Aseprite
GenericName=Sprite Editor
Comment=Animated sprite editor & pixel art tool
Exec=aseprite %F
Icon=aseprite
Terminal=false
Categories=Graphics;2DGraphics;RasterGraphics;
DESKTOP
  cp "${appdir}/aseprite.desktop" "${appdir}/usr/share/applications/aseprite.desktop"

  cat > "${appdir}/AppRun" <<'APPRUN'
#!/usr/bin/env bash
HERE="$(dirname "$(readlink -f "${0}")")"
exec "${HERE}/usr/bin/aseprite" "$@"
APPRUN
  chmod +x "${appdir}/AppRun"

  if [ ! -f "${appimagetool}" ]; then
    curl -fsSL "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage" -o "${appimagetool}"
    chmod +x "${appimagetool}"
  fi
  ARCH=x86_64 "${appimagetool}" --appimage-extract-and-run "${appdir}" "${WORKDIR}/Aseprite.AppImage"
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
  echo "Building Aseprite ${ASEPRITE_VERSION} (${BUILD_TYPE})"
  checkout_tag
  patch_version_file
  download_skia
  build_aseprite
  package_portable
  package_appimage
  report_version
  echo "Done. Packaged: ${OUTDIR} and Aseprite.AppImage"
}

main "$@"
