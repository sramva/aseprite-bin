@echo off
setlocal enabledelayedexpansion

rem Builds Aseprite from source and packages it into aseprite-<version>\.
rem Run from the repository root.
rem
rem Environment:
rem   ASEPRITE_VERSION  tag to build (default: newest tag of the repo)
rem   GITHUB_OUTPUT     when set, the version is exported as a step output


rem *** required tools ***

set "PATH=C:\Program Files\7-Zip;%PATH%"

where /q git.exe || (
  echo ERROR: "git.exe" not found
  exit /b 1
)

if exist "%ProgramFiles%\7-Zip\7z.exe" (
  set "SZIP=%ProgramFiles%\7-Zip\7z.exe"
) else (
  where /q 7za.exe || (
    echo ERROR: 7-Zip installation or "7za.exe" not found
    exit /b 1
  )
  set "SZIP=7za.exe"
)


rem *** Visual Studio environment ***

where /q cl.exe || (
  set "__VSCMD_ARG_NO_LOGO=1"
  for /f "tokens=*" %%i in ('"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -requires Microsoft.VisualStudio.Workload.NativeDesktop -property installationPath') do set "VS=%%i"
  if "!VS!" equ "" (
    echo ERROR: Visual Studio installation not found
    exit /b 1
  )
  call "!VS!\VC\Auxiliary\Build\vcvarsall.bat" amd64 || exit /b 1
)


rem *** ninja ***

where /q ninja.exe || (
  curl -LOsf https://github.com/ninja-build/ninja/releases/download/v1.13.1/ninja-win.zip || exit /b 1
  "%SZIP%" x -bb0 -y ninja-win.zip >nul 2>&1 || exit /b 1
  del /q ninja-win.zip >nul 2>&1
)


rem *** clone aseprite repo ***

if not exist aseprite (
  git clone --recursive --tags https://github.com/aseprite/aseprite.git aseprite || (
    echo ERROR: failed to clone repo
    exit /b 1
  )
) else (
  git -C aseprite fetch --tags || (
    echo ERROR: failed to fetch repo
    exit /b 1
  )
)


rem *** newest tag is used when ASEPRITE_VERSION is not set ***

if not defined ASEPRITE_VERSION (
  for /F "delims=" %%v in ('git -C aseprite tag --sort=creatordate') do set "ASEPRITE_VERSION=%%v"
)
if not defined ASEPRITE_VERSION (
  echo ERROR: unable to detect ASEPRITE_VERSION
  exit /b 1
)

echo building %ASEPRITE_VERSION%


rem *** update local aseprite repo to selected tag ***

git -C aseprite clean --quiet -fdx
git -C aseprite submodule foreach --recursive git clean -xfd
git -C aseprite fetch --quiet --depth=1 --no-tags origin %ASEPRITE_VERSION%:refs/remotes/origin/%ASEPRITE_VERSION% || (
  echo ERROR: failed to fetch %ASEPRITE_VERSION%
  exit /b 1
)
git -C aseprite reset --quiet --hard origin/%ASEPRITE_VERSION% || (
  echo ERROR: failed to update repo
  exit /b 1
)
git -C aseprite submodule update --init --recursive || (
  echo ERROR: failed to update submodules
  exit /b 1
)


rem *** version passed to CMake, without the leading "v" ***

set "ASEPRITE_CMAKE_VERSION=%ASEPRITE_VERSION%"
if "%ASEPRITE_CMAKE_VERSION:~0,1%" equ "v" set "ASEPRITE_CMAKE_VERSION=%ASEPRITE_CMAKE_VERSION:~1%"
set "ASEPRITE_CMAKE_VERSION=%ASEPRITE_CMAKE_VERSION%-dev"
python -c "from pathlib import Path; p = Path('aseprite/src/ver/CMakeLists.txt'); v = p.read_text(); p.write_text(v.replace('set(VERSION \"1.x-dev\")', 'set(VERSION \"1.x-dev\" CACHE STRING \"Version of Aseprite\")'))" || (
  echo ERROR: failed to patch version file
  exit /b 1
)


rem *** download skia ***

set "SKIA_URL="
for /f "delims=" %%u in ('bash -lc "cd aseprite && source laf/misc/skia-url.sh | xargs"') do set "SKIA_URL=%%u"
if not defined SKIA_URL (
  echo ERROR: unable to resolve skia url
  exit /b 1
)
for %%f in ("%SKIA_URL%") do set "SKIA_FILE=%%~nxf"
for %%f in ("%SKIA_FILE%") do set "SKIA_VERSION=%%~nf"

if not exist "skia-%SKIA_VERSION%" (
  mkdir "skia-%SKIA_VERSION%"
  pushd "skia-%SKIA_VERSION%"
  curl --ssl-revoke-best-effort -sfLO "%SKIA_URL%" || (
    echo ERROR: failed to download skia
    exit /b 1
  )
  "%SZIP%" x -bb0 -y "%SKIA_FILE%" >nul || (
    echo ERROR: failed to extract skia
    exit /b 1
  )
  popd
)


rem *** configure and build aseprite ***

if exist build rd /s /q build

set "LINK=opengl32.lib"
cmake.exe                                                     ^
  -G Ninja                                                    ^
  -S aseprite                                                 ^
  -B build                                                    ^
  -DCMAKE_BUILD_TYPE=Release                                  ^
  -DVERSION=%ASEPRITE_CMAKE_VERSION%                          ^
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5                          ^
  -DCMAKE_POLICY_DEFAULT_CMP0074=NEW                          ^
  -DCMAKE_POLICY_DEFAULT_CMP0091=NEW                          ^
  -DCMAKE_POLICY_DEFAULT_CMP0092=NEW                          ^
  -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded                  ^
  -DENABLE_TESTS=OFF                                          ^
  -DENABLE_SCRIPTING=ON                                       ^
  -DENABLE_CCACHE=OFF                                         ^
  -DOPENSSL_USE_STATIC_LIBS=TRUE                              ^
  -DLAF_BACKEND=skia                                          ^
  -DSKIA_DIR=%CD%\skia-%SKIA_VERSION%                         ^
  -DSKIA_LIBRARY_DIR=%CD%\skia-%SKIA_VERSION%\out\Release-x64 ^
  -DSKIA_OPENGL_LIBRARY=                                      || (
  echo ERROR: failed to configure build
  exit /b 1
)
ninja.exe -C build aseprite || (
  echo ERROR: build failed
  exit /b 1
)


rem *** package output folder ***

if exist "aseprite-%ASEPRITE_VERSION%" rd /s /q "aseprite-%ASEPRITE_VERSION%"
mkdir "aseprite-%ASEPRITE_VERSION%"
echo # This file is here so Aseprite behaves as a portable program >"aseprite-%ASEPRITE_VERSION%\aseprite.ini"
xcopy /E /I /Q /Y aseprite\docs "aseprite-%ASEPRITE_VERSION%\docs" >nul
xcopy /E /I /Q /Y build\bin\aseprite.exe "aseprite-%ASEPRITE_VERSION%" >nul
xcopy /E /I /Q /Y build\bin\data "aseprite-%ASEPRITE_VERSION%\data" >nul


rem *** expose the version to the calling workflow ***

if defined GITHUB_WORKFLOW >>"%GITHUB_OUTPUT%" echo ASEPRITE_VERSION=%ASEPRITE_VERSION%
