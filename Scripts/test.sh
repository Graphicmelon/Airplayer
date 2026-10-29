#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p .build/module-cache
clang -O2 -Wall -Wextra -Werror -c Native/SurfaceTransport.c -o .build/SurfaceTransport.o
swiftc -swift-version 5 -warnings-as-errors -module-cache-path .build/module-cache \
    -import-objc-header Native/SurfaceTransport.h .build/SurfaceTransport.o \
    Sources/Airplayer/SurfaceFrame.swift Sources/Airplayer/FrameServer.swift Sources/Airplayer/ReceiverConfiguration.swift Tests/TransportTests.swift \
    -o .build/transport-tests -framework IOSurface
.build/transport-tests
if [ "${1:-}" = "--ui" ]; then
    swiftc -swift-version 5 -O -D AIRPLAYER_DIAGNOSTICS -module-cache-path .build/module-cache \
        -import-objc-header Native/SurfaceTransport.h .build/SurfaceTransport.o \
        Sources/Airplayer/SurfaceFrame.swift Sources/Airplayer/PipelineTimings.swift \
        Sources/Airplayer/MetalVideoView.swift Tests/DisplayTests.swift -o .build/display-tests \
        -framework AppKit -framework QuartzCore -framework Metal -framework IOSurface -framework CoreVideo
    .build/display-tests
    bash Scripts/build.sh --diagnostics
    .build/Airplayer-Test.app/Contents/MacOS/Airplayer --smoke-test
    python3 - <<'PY'
import json
from pathlib import Path
report = json.loads(Path('.build/Smoke/report.json').read_text())
assert report['passed'], report
print('PASS: native UI and bundled GStreamer integration')
PY
fi
