# Development

## Architecture

```text
AirPlay sender
    → UxPlay / GStreamer appsrc (receiver process)
    → direct VideoToolbox H.264 / HEVC decoder
    → NV12 CVPixelBuffer / IOSurface
    → private Mach transport and frame leases
    → Metal / Core Animation (AppKit process)
```

Video decoding is synchronous and disables temporal processing. Compressed reference frames are not dropped; the appsrc queue is bounded to two access units. The UI keeps the latest decoded frame, with one GPU command buffer in flight and two drawables. Audio remains on GStreamer's macOS output path.

Each decoded pixel buffer is leased until the receiving UI and GPU release it. This prevents VideoToolbox from recycling a surface still in use. Annex B to length-prefixed NAL conversion still copies compressed bytes; the entire pipeline is not claimed to be zero-copy.

Metal samples NV12 directly. Enlargement uses bounded cubic luma interpolation; chroma uses linear sampling. Vsync and Core Animation transactions synchronize complete-frame presentation. Source timestamp waiting is disabled, and incoming frames do not incur an extra display-link wait. The display link retries the latest pending frame when necessary.

## Layout

| Directory | Purpose |
| --- | --- |
| `Sources/Airplayer` | AppKit UI, process lifecycle, IPC, Metal rendering |
| `Native` | VideoToolbox decoder, GStreamer sink, Mach transport |
| `Vendor/UxPlay` | Pinned, unmodified upstream source |
| `Tests` | Transport, hardware decoder, and GPU regression tests |
| `Scripts` | Build, runtime packaging, and test entry points |

## Build and test

`bash Scripts/build.sh` creates `dist/Airplayer.app`. `--diagnostics` builds a separate `.build/Airplayer-Test.app` containing smoke-test code and video generators. Never publish the diagnostic app.

```sh
bash Scripts/test.sh
bash Scripts/test_decoder.sh
bash Scripts/test.sh --ui
```

The UI suite exercises GPU readback, fullscreen, rotation/reconnection, resizing, minimize/restore, a 2160p HEVC pipeline, and process cleanup. Its report is `.build/Smoke/report.json`. These are synthetic local tests; real sender discovery, wireless motion, and audio should also be checked before a release.

The build uses the host macOS major version as its deployment target by default. `MACOSX_DEPLOYMENT_TARGET` can select another target, but all bundled dependencies must support it. Packaging raises `LSMinimumSystemVersion` to the highest requirement found in bundled libraries. Do not lower the plist independently.

## Diagnostics

The receiver writes `~/Library/Logs/Airplayer/receiver.log` and replaces it at startup. Logs can contain device names and network information; redact them before sharing.

- `REQUEST`: requested size, frame rate, codecs, and presentation mode.
- `VIDEO size`: actual decoded pixel dimensions.
- `received_fps`: measured incoming frame rate, including idle periods.
- `producer_dropped` / `ui_superseded`: local queue pressure, not network loss.
- `LOCAL_LATENCY`: local decode, IPC, and presentation percentiles. These exclude sender encoding, network transport, and touch input.

For compatibility diagnosis, quit first and launch with `--resolution 1080` or `--resolution 1440`. Ordinary launches use 2160p60. Synchronized presentation is always enabled.

## Release

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.
2. Build from a clean checkout and run the suites above in a logged-in desktop session.
3. Check real-device video, audio, and reconnect behavior.
4. Verify `codesign --verify --deep --strict dist/Airplayer.app`.
5. Commit the source, run `bash Scripts/package_release.sh`, and publish every file in `dist/releases/`. This includes the app, exact source, dependency source references/build recipes, and checksums.
6. State the architecture, minimum OS, signing, and notarization status in release notes.

`Runtime/origins.json` records packaged dependency versions without personal absolute paths. `Runtime/source-recipes/` contains the installed Homebrew recipes, including source URLs and checksums; `Runtime/licenses/` contains notices. Runtime directories are recreated on each build so removed plugins cannot survive a rebuild.

The current signing step is ad-hoc. Developer ID signing and notarization require maintainer credentials and are not part of this repository.
