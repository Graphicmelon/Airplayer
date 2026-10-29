#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export HOMEBREW_NO_AUTO_UPDATE=1
for tool in brew cmake pkg-config swiftc python3; do
    if ! command -v "$tool" >/dev/null; then
        echo "Missing $tool. Install build tools: brew install cmake pkgconf libplist openssl@3 gstreamer" >&2
        exit 1
    fi
done
BREW_PREFIX="$(brew --prefix)"
export HOMEBREW_PREFIX="$BREW_PREFIX"
export PKG_CONFIG_PATH="$BREW_PREFIX/opt/openssl@3/lib/pkgconfig:$BREW_PREFIX/lib/pkgconfig"
UXPLAY_COMMIT=21eef8df25d91e12635c36d8176ad192725baca2
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-$(sw_vers -productVersion | cut -d. -f1).0}"
if [ ! -f Vendor/UxPlay/uxplay.cpp ]; then
    echo "Missing vendored UxPlay source. Download a complete Airplayer source checkout." >&2
    exit 1
fi
if [ -d Vendor/UxPlay/.git ] && [ "$(git -C Vendor/UxPlay rev-parse HEAD)" != "$UXPLAY_COMMIT" ]; then
    echo "Expected UxPlay v1.73.6 ($UXPLAY_COMMIT). Refusing to build an unpinned receiver." >&2
    exit 1
fi
mkdir -p .build/uxplay-source .build/module-cache dist
rsync -a --exclude .git --exclude build Vendor/UxPlay/ .build/uxplay-source/
python3 - <<'PY'
from pathlib import Path
source = Path('.build/uxplay-source/uxplay.cpp')
text = source.read_text()
needle = '    reconnect:\n'
assert text.count(needle) == 1, 'Upstream readiness hook changed'
source.write_text(text.replace(needle, '    fprintf(stderr, "AIRPLAYER_READY\\n");\n    fflush(stderr);\n' + needle))
cmake = Path('.build/uxplay-source/CMakeLists.txt')
cmake.write_text(cmake.read_text() + '\ntarget_sources(uxplay PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../../Native/parent_watch.c")\n')
library = Path('.build/uxplay-source/lib/CMakeLists.txt')
text = library.read_text()
needle = '  pkg_check_modules( OPENSSL REQUIRED openssl>=1.1.1)'
assert text.count(needle) == 1, 'Upstream OpenSSL configuration changed'
library.write_text(text.replace(needle,
    '  set(ENV{PKG_CONFIG_PATH} "$ENV{HOMEBREW_PREFIX}/opt/openssl@3/lib/pkgconfig:$ENV{PKG_CONFIG_PATH}")\n' + needle))
renderer = Path('.build/uxplay-source/renderers/video_renderer.c')
text = renderer.read_text()
start = text.index('            GString *launch = g_string_new("appsrc name=video_source ! ");')
end = text.index('            if (!strcmp(renderer_type[i]->codec, h264)) {', start)
original = text[start:end].replace('GString *launch =', 'launch =', 1)
replacement = '''            GString *launch;
            if (!strcmp(videosink, "airplayerh264sink") && !jpeg_pipeline && !rtp) {
                launch = g_string_new("appsrc name=video_source max-buffers=2 max-bytes=0 max-time=0 block=true ! airplayerh264sink name=airplayerh264sink_h264 sync=false async=false");
                sync = false;
            } else {
''' + original + '            }\n'
renderer.write_text(text[:start] + replacement + text[end:])
PY
cmake -S .build/uxplay-source -B .build/uxplay \
    -DCMAKE_BUILD_TYPE=Release -DNO_MARCH_NATIVE=ON \
    -DGST_MACOS=OFF -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DLIBCRYPTO="$BREW_PREFIX/opt/openssl@3/lib/libcrypto.a" \
    -DCMAKE_PREFIX_PATH="$BREW_PREFIX" -U '*OPENSSL*'
cmake --build .build/uxplay --parallel "$(sysctl -n hw.logicalcpu)"
clang -dynamiclib -O2 -Wall -Wextra -Werror -mmacosx-version-min="$DEPLOYMENT_TARGET" \
    $(pkg-config --cflags gstreamer-video-1.0) Native/gstairplayersink.c Native/SurfaceTransport.c Native/RealtimeH264.c \
    -o .build/libgstairplayer.dylib $(pkg-config --libs gstreamer-video-1.0) \
    -framework IOSurface -framework CoreFoundation -framework CoreVideo -framework CoreMedia -framework VideoToolbox
clang -O2 -Wall -Wextra -Werror -mmacosx-version-min="$DEPLOYMENT_TARGET" \
    -c Native/SurfaceTransport.c -o .build/SurfaceTransport.o

APP="$ROOT/dist/Airplayer.app"
if [ "${1:-}" = "--diagnostics" ]; then APP="$ROOT/.build/Airplayer-Test.app"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
swift -module-cache-path "$ROOT/.build/module-cache" Scripts/make_icon.swift .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
SWIFT_FLAGS=()
if [ "${1:-}" = "--diagnostics" ]; then SWIFT_FLAGS=(-D AIRPLAYER_DIAGNOSTICS); fi
swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx$DEPLOYMENT_TARGET" \
    -module-cache-path "$ROOT/.build/module-cache" "${SWIFT_FLAGS[@]}" \
    -import-objc-header Native/SurfaceTransport.h .build/SurfaceTransport.o \
    Sources/Airplayer/*.swift -o "$APP/Contents/MacOS/Airplayer" \
    -framework AppKit -framework QuartzCore -framework Metal -framework IOSurface
PACKAGE_FLAGS=()
if [ "${1:-}" = "--diagnostics" ]; then PACKAGE_FLAGS=(--diagnostics); fi
python3 Scripts/package_runtime.py "${PACKAGE_FLAGS[@]}" --prefix "$BREW_PREFIX" \
    --uxplay .build/uxplay/uxplay --plugin .build/libgstairplayer.dylib \
    --destination "$APP/Contents/Resources/Runtime"
python3 - "$APP" "$DEPLOYMENT_TARGET" <<'PY'
from pathlib import Path
import plistlib, re, subprocess, sys
app = Path(sys.argv[1])
minimum = tuple(map(int, sys.argv[2].split('.')))
for binary in (app / 'Contents/Resources/Runtime').rglob('*'):
    if binary.suffix == '.dylib' or binary.parent.name == 'bin':
        metadata = subprocess.check_output(['otool', '-l', str(binary)], text=True)
        for version in re.findall(r'\bminos ([0-9.]+)', metadata):
            minimum = max(minimum, tuple(map(int, version.split('.'))))
path = app / 'Contents/Info.plist'
info = plistlib.loads(path.read_bytes())
info['LSMinimumSystemVersion'] = '.'.join(map(str, minimum))
path.write_bytes(plistlib.dumps(info))
print('Packaged runtime requires macOS ' + info['LSMinimumSystemVersion'])
PY
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp Vendor/UxPlay/LICENSE "$APP/Contents/Resources/Runtime/licenses/UxPlay-GPL-3.0.txt"
cp Vendor/UxPlay/lib/llhttp/LICENSE-MIT "$APP/Contents/Resources/Runtime/licenses/llhttp-MIT.txt"
cp THIRD_PARTY.md "$APP/Contents/Resources/THIRD_PARTY.md"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built: $APP"
