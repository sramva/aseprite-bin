#!/usr/bin/env bash
set -euo pipefail

WORKDIR="${PWD}"
ASEPRITE_DIR="${WORKDIR}/aseprite"
BUILD_DIR="${ASEPRITE_DIR}/build"
BUILD_TYPE="${BUILD_TYPE:-Release}"
SKIA_ARCH="x64"

sudo apt-get update -qq
sudo apt-get install -y \
  build-essential clang git unzip curl cmake ninja-build xvfb \
  libpixman-1-dev libfreetype6-dev libharfbuzz-dev zlib1g-dev \
  libx11-dev libxcursor-dev libxi-dev libxrandr-dev libgl1-mesa-dev \
  libfontconfig1-dev libpng-dev libjpeg-dev libwebp-dev

if [ ! -d "${ASEPRITE_DIR}/.git" ]; then
  git clone --recursive https://github.com/aseprite/aseprite.git "${ASEPRITE_DIR}"
else
  git -C "${ASEPRITE_DIR}" fetch --tags origin
fi

if [ -z "${ASEPRITE_VERSION:-}" ]; then
  ASEPRITE_VERSION="$(git -C "${ASEPRITE_DIR}" tag --sort=creatordate | tail -n1)"
fi
[ -n "${ASEPRITE_VERSION}" ] || { echo "Unable to detect ASEPRITE_VERSION" >&2; exit 1; }
echo "Building Aseprite ${ASEPRITE_VERSION} (${BUILD_TYPE})"

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

OUTDIR="${WORKDIR}/aseprite-${ASEPRITE_VERSION}"
rm -rf "${OUTDIR}"
mkdir -p "${OUTDIR}"
echo "# This file is here so Aseprite behaves as a portable program" > "${OUTDIR}/aseprite.ini"
cp -r "${ASEPRITE_DIR}/docs" "${OUTDIR}/docs" 2>/dev/null || true
cp "${BUILD_DIR}/bin/aseprite" "${OUTDIR}/"
cp -r "${BUILD_DIR}/bin/data" "${OUTDIR}/data"

APPDIR="${WORKDIR}/AppDir"
rm -rf "${APPDIR}"
mkdir -p "${APPDIR}/usr/bin" "${APPDIR}/usr/share/applications"
for s in 16 20 24 28 32 48 64 128 256; do
  mkdir -p "${APPDIR}/usr/share/icons/hicolor/${s}x${s}/apps"
  [ -f "${ASEPRITE_DIR}/data/icons/ase${s}.png" ] && cp "${ASEPRITE_DIR}/data/icons/ase${s}.png" "${APPDIR}/usr/share/icons/hicolor/${s}x${s}/apps/aseprite.png"
done
cp "${ASEPRITE_DIR}/data/icons/ase256.png" "${APPDIR}/aseprite.png"
cp "${BUILD_DIR}/bin/aseprite" "${APPDIR}/usr/bin/aseprite"
cp -r "${BUILD_DIR}/bin/data" "${APPDIR}/usr/bin/data"
cat > "${APPDIR}/aseprite.desktop" <<'DESKTOP'
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
cp "${APPDIR}/aseprite.desktop" "${APPDIR}/usr/share/applications/aseprite.desktop"
cat > "${APPDIR}/AppRun" <<'APPRUN'
#!/usr/bin/env bash
HERE="$(dirname "$(readlink -f "${0}")")"
exec "${HERE}/usr/bin/aseprite" "$@"
APPRUN
chmod +x "${APPDIR}/AppRun"

APPIMAGETOOL="${WORKDIR}/appimagetool-x86_64.AppImage"
if [ ! -f "${APPIMAGETOOL}" ]; then
  curl -fsSL "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage" -o "${APPIMAGETOOL}"
  chmod +x "${APPIMAGETOOL}"
fi
ARCH=x86_64 "${APPIMAGETOOL}" --appimage-extract-and-run "${APPDIR}" "${WORKDIR}/Aseprite.AppImage"

if [ -n "${GITHUB_WORKFLOW:-}" ]; then
  echo "ASEPRITE_VERSION=${ASEPRITE_VERSION}" >> "${GITHUB_OUTPUT:-/dev/null}" || true
fi

echo "Done. Packaged: ${OUTDIR} and Aseprite.AppImage"
