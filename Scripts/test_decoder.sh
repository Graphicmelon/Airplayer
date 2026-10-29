#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p .build
clang -O2 -Wall -Wextra -Werror -I Native \
    Tests/DecoderTests.c Tests/DecoderMain.m Native/RealtimeH264.c -o .build/decoder-tests \
    -framework AppKit -framework VideoToolbox -framework CoreVideo -framework CoreMedia -framework CoreFoundation
.build/decoder-tests
.build/decoder-tests --hevc-2160
