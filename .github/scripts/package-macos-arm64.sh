#!/bin/bash
# Build a native arm64 Avidemux.app and DMG on a GitHub-hosted macOS runner.
# The Avidemux bootstrap refuses a case-insensitive volume, and the runner's
# system disk is case-insensitive APFS. A new APFS volume in the boot container
# cannot be mounted on GitHub-hosted runners (diskutil error -69842), so the
# tree is copied onto a case-sensitive APFS disk image.
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
cd "$ROOT"

export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ENV_HINTS=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_PREFIX="${HOMEBREW_PREFIX:-/opt/homebrew}"
export PATH="$HOMEBREW_PREFIX/bin:$PATH"

echo "=== disk before install ==="
df -h /

avail_kb=$(df -k / | awk 'NR==2 {print $4}')
if [ "${avail_kb}" -lt 18000000 ]; then
    echo "Free space is ${avail_kb} KB; removing bulky unused SDKs."
    rm -rf "$HOME/Library/Developer/CoreSimulator/Caches" || true
    xcrun simctl delete unavailable || true
    rm -rf "$HOME/Library/Android" || true
    df -h /
fi

echo "=== Homebrew dependencies ==="
brew install \
    cmake pkgconf ccache gettext \
    qtbase qttools \
    sdl3 libass freetype fribidi fontconfig \
    libogg libvorbis opus libopusenc lame two-lame \
    aom libvpx x264 x265 xvid \
    faad2 a52dec

# faac is optional (often unbottled). Skip it if the formula will not install.
if ! brew install faac; then
    echo "WARNING: faac failed to install; the FAAC encoder plugin will be omitted."
fi

# qtbase is keg-only. Its qmake still reports QT_INSTALL_PREFIX as the Homebrew
# prefix, so the build only works once those files are linked into /opt/homebrew.
# The bootstrap also looks for /opt/homebrew/opt/qt (the old formula name).
brew link --force qtbase
brew link --force qttools || true
if [ ! -e "$HOMEBREW_PREFIX/opt/qt" ]; then
    ln -sfn qtbase "$HOMEBREW_PREFIX/opt/qt"
fi
# lrelease ships in qttools. The i18n build looks for it next to qmake.
if [ ! -x "$HOMEBREW_PREFIX/opt/qt/bin/lrelease" ] && [ -x "$HOMEBREW_PREFIX/opt/qttools/bin/lrelease" ]; then
    ln -sfn "$HOMEBREW_PREFIX/opt/qttools/bin/lrelease" "$HOMEBREW_PREFIX/opt/qt/bin/lrelease"
fi
plugins_dir=$("$HOMEBREW_PREFIX/bin/qmake" -query QT_INSTALL_PLUGINS)
if [ ! -d "$plugins_dir/platforms" ]; then
    keg_plugins="$HOMEBREW_PREFIX/opt/qtbase/share/qt/plugins"
    if [ -d "$keg_plugins/platforms" ]; then
        mkdir -p "$HOMEBREW_PREFIX/share/qt"
        ln -sfn "$keg_plugins" "$HOMEBREW_PREFIX/share/qt/plugins"
    fi
fi
plugins_dir=$("$HOMEBREW_PREFIX/bin/qmake" -query QT_INSTALL_PLUGINS)
if [ ! -d "$plugins_dir/platforms" ]; then
    echo "ERROR: Qt platform plugins not found at $plugins_dir/platforms" >&2
    "$HOMEBREW_PREFIX/bin/qmake" -query || true
    exit 1
fi
# A linked /opt/homebrew/bin/qmake must not be combined with MYQT; the
# bootstrap treats that combination as a conflicting Qt install.
unset MYQT || true
echo "Using linked Homebrew Qt at $HOMEBREW_PREFIX"
"$HOMEBREW_PREFIX/bin/qmake" -query

echo "=== translations submodule (mean00/avidemux2_i18n) ==="
# This fork does not have jw-tecuri/avidemux2_i18n. The gitlink is relative
# (../avidemux2_i18n.git), which would resolve to the missing fork repo.
git submodule init avidemux/qt4/i18n
git config submodule.i18n.url https://github.com/mean00/avidemux2_i18n.git
git submodule update --init avidemux/qt4/i18n
test -f avidemux/qt4/i18n/CMakeLists.txt

echo "=== case-sensitive APFS disk image ==="
# GitHub-hosted runners reject `diskutil apfs addVolume` with error -69842
# ("Couldn't mount disk"). A sparse disk image is writable by the runner user.
image="/tmp/AvidemuxCS.sparseimage"
rm -f "$image"
hdiutil create -size 40g -type SPARSE -fs "Case-sensitive APFS" -volname AvidemuxCS "$image"
sudo mkdir -p /Volumes/AvidemuxCS
sudo chown "$(id -un):$(id -gn)" /Volumes/AvidemuxCS
if ! hdiutil attach "$image" -nobrowse -mountpoint /Volumes/AvidemuxCS; then
    sudo hdiutil attach "$image" -nobrowse -mountpoint /Volumes/AvidemuxCS
    sudo chown "$(id -un):$(id -gn)" /Volumes/AvidemuxCS
fi
if [ ! -d /Volumes/AvidemuxCS ]; then
    echo "ERROR: /Volumes/AvidemuxCS did not mount" >&2
    exit 1
fi

echo "=== copy sources ==="
mkdir -p /Volumes/AvidemuxCS/src
# Trailing slash copies contents. .git is required for the bootstrap revision string.
rsync -a --exclude dist "$ROOT/" /Volumes/AvidemuxCS/src/
git config --global --add safe.directory /Volumes/AvidemuxCS/src || true

cd /Volumes/AvidemuxCS/src
# shellcheck disable=SC1091
. ./checkCaseSensitivity.sh
isCaseSensitive || { echo "ERROR: /Volumes/AvidemuxCS is not case-sensitive" >&2; exit 1; }

export PATH="$HOMEBREW_PREFIX/opt/ccache/libexec:$HOMEBREW_PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$HOMEBREW_PREFIX/lib/pkgconfig:$HOMEBREW_PREFIX/share/pkgconfig:$HOMEBREW_PREFIX/opt/gettext/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CMAKE_PREFIX_PATH="$HOMEBREW_PREFIX/opt/qtbase:$HOMEBREW_PREFIX/opt/qttools:$HOMEBREW_PREFIX/opt/gettext:$HOMEBREW_PREFIX${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export CPATH="$HOMEBREW_PREFIX/include${CPATH:+:$CPATH}"
export LIBRARY_PATH="$HOMEBREW_PREFIX/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
export CPPFLAGS="-I$HOMEBREW_PREFIX/include ${CPPFLAGS:-}"
export LDFLAGS="-L$HOMEBREW_PREFIX/lib ${LDFLAGS:-}"
export MAKEFLAGS="${MAKEFLAGS:--j2}"
export FFMPEG_MAKE_JOBS="${FFMPEG_MAKE_JOBS:-2}"
export CCACHE_DIR="${CCACHE_DIR:-$HOME/Library/Caches/ccache}"
export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-1G}"
unset CMAKE_GENERATOR || true

mkdir -p "$CCACHE_DIR"
if command -v ccache >/dev/null 2>&1; then
    ccache --zero-stats || true
    ccache -s || true
fi

echo "=== bootstrap ==="
set +e
bash ./bootStrapMacOS_Monterey.arm64.sh --output=Avidemux-2.8.2-macos-arm64
bootstrap_status=$?
set -e
if [ "$bootstrap_status" -ne 0 ]; then
    echo "Bootstrap failed with status $bootstrap_status"
    for log in /tmp/log*; do
        [ -f "$log" ] || continue
        echo "----- tail $log -----"
        tail -n 120 "$log" || true
    done
    exit "$bootstrap_status"
fi

if command -v ccache >/dev/null 2>&1; then
    ccache -s || true
fi

echo "=== stage package ==="
installer_dir="/Volumes/AvidemuxCS/src/installer"
app=$(find "$installer_dir" -maxdepth 1 -type d -name 'Avidemux*.app' | head -n 1)
if [ -z "$app" ]; then
    echo "ERROR: packaged .app not found in $installer_dir" >&2
    ls -la "$installer_dir" || true
    exit 1
fi
dmg=$(find "$installer_dir" -maxdepth 1 -type f -name '*.dmg' | head -n 1)
if [ -z "$dmg" ]; then
    echo "ERROR: DMG not found in $installer_dir" >&2
    ls -la "$installer_dir" || true
    exit 1
fi

stage="$ROOT/dist"
mkdir -p "$stage"
cp -v "$dmg" "$stage/"
ditto -c -k --keepParent "$app" "$stage/Avidemux-2.8.2-macos-arm64.zip"
# Keep the .app where the verifier can run it. Copying an .app across volumes
# with ditto preserves the symlinks fixup_bundle created.
rm -rf "$stage/Avidemux.app"
ditto "$app" "$stage/Avidemux.app"
printf '%s\n' "$stage/Avidemux.app" > "$stage/app.path"
ls -lh "$stage"
echo "BUILD STAGED"
