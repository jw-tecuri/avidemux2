#!/bin/bash
# Confirm a packaged Avidemux.app is a self-contained arm64 bundle.
# Usage: verify-macos-arm64-bundle.sh /path/to/Avidemux.app
set -u

APP="${1:-}"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    echo "Usage: $0 /path/to/Avidemux.app" >&2
    exit 2
fi
# Smoke tests run from /tmp, so a relative bundle path would not resolve.
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"

fail=0
macho=0
bad_arch=0
bad_link=0

note() { printf '%s\n' "$*"; }

is_macho() {
    file -b "$1" 2>/dev/null | grep -q 'Mach-O'
}

note "Bundle: $APP"
note ""

main_bin=""
for candidate in "$APP"/Contents/MacOS/Avidemux*; do
    if [ -f "$candidate" ] && is_macho "$candidate"; then
        main_bin="$candidate"
        break
    fi
done
if [ -z "$main_bin" ]; then
    note "ERROR: no main Mach-O executable under Contents/MacOS"
    exit 1
fi

note "Main executable: $main_bin"
note "lipo -archs: $(lipo -archs "$main_bin" 2>/dev/null || echo '<lipo failed>')"
if command -v vtool >/dev/null 2>&1; then
    note "vtool -show-build:"
    vtool -show-build "$main_bin" 2>/dev/null || true
fi
note ""
note "otool -L (main executable):"
otool -L "$main_bin" || fail=1
note ""

# Non-bundled prefixes. System libraries under /usr/lib and /System are fine.
forbidden='/opt/homebrew|/usr/local|/opt/local|Cellar'

while IFS= read -r -d '' f; do
    if ! is_macho "$f"; then
        continue
    fi
    macho=$((macho + 1))
    archs=$(lipo -archs "$f" 2>/dev/null || true)
    if [ "$archs" != "arm64" ]; then
        note "BAD ARCH [$archs] $f"
        bad_arch=$((bad_arch + 1))
        fail=1
    fi
    links=$(otool -L "$f" 2>/dev/null | grep -E "$forbidden" || true)
    rpaths=$(otool -l "$f" 2>/dev/null | awk '/cmd LC_RPATH/,/^$/' | grep -E "$forbidden" || true)
    if [ -n "$links" ] || [ -n "$rpaths" ]; then
        note "BAD LINKAGE $f"
        if [ -n "$links" ]; then
            printf '%s\n' "$links"
        fi
        if [ -n "$rpaths" ]; then
            printf '%s\n' "$rpaths"
        fi
        bad_link=$((bad_link + 1))
        fail=1
    fi
done < <(find "$APP" -type f -print0)

note ""
note "Mach-O files checked: $macho"
note "Non-arm64: $bad_arch"
note "Non-bundled linkage: $bad_link"
if [ "$macho" -lt 1 ]; then
    note "ERROR: no Mach-O files found"
    exit 1
fi

cli="$APP/Contents/MacOS/avidemux_cli"
if [ ! -x "$cli" ]; then
    note "ERROR: avidemux_cli is missing"
    exit 1
fi

note ""
note "=== avidemux_cli --help ==="
set +e
cli_out=$(cd /tmp && "$cli" --help 2>&1)
cli_status=$?
set -e
printf '%s\n' "$cli_out"
if [ "$cli_status" -ne 0 ]; then
    note "ERROR: avidemux_cli --help exited $cli_status"
    fail=1
fi
if ! printf '%s\n' "$cli_out" | grep -q 'Avidemux v'; then
    note "ERROR: avidemux_cli did not print an Avidemux version banner"
    fail=1
fi

gui="$main_bin"
note ""
note "=== GUI --help (QT_QPA_PLATFORM=offscreen) ==="
set +e
gui_out=$(cd /tmp && QT_QPA_PLATFORM=offscreen python3 - "$gui" <<'PY'
import os, subprocess, sys
gui = sys.argv[1]
env = os.environ.copy()
env["QT_QPA_PLATFORM"] = "offscreen"
try:
    proc = subprocess.run([gui, "--help"], env=env, timeout=120,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
except subprocess.TimeoutExpired as exc:
    sys.stdout.write(exc.stdout or "")
    sys.stderr.write("ERROR: GUI --help timed out after 120s\n")
    sys.exit(124)
sys.stdout.write(proc.stdout or "")
sys.exit(proc.returncode)
PY
)
gui_status=$?
set -e
printf '%s\n' "$gui_out"
if [ "$gui_status" -ne 0 ]; then
    note "ERROR: GUI --help exited $gui_status"
    fail=1
fi
if ! printf '%s\n' "$gui_out" | grep -q 'Avidemux v'; then
    note "ERROR: GUI binary did not print an Avidemux version banner"
    fail=1
fi

note ""
if [ "$fail" -ne 0 ]; then
    note "VERIFICATION FAILED"
    exit 1
fi
note "VERIFICATION PASSED"
exit 0
