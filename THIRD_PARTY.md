# Third-party components

Airplayer is licensed under GPL-3.0-or-later. Its source, native transport
plugin, IOSurface/Mach transport, Metal renderer, build scripts, and UxPlay
integration are provided in this directory.

## UxPlay

- Upstream: https://github.com/FDH2/UxPlay
- Pinned release: **v1.73.6**
- Commit: `21eef8df25d91e12635c36d8176ad192725baca2`
- License: GPL-3.0-or-later; see `Vendor/UxPlay/LICENSE`.
- The original source is in `Vendor/UxPlay`, including its authorship notes.
- The build adds a flushed `AIRPLAYER_READY` message after successful service
  registration and links `Native/parent_watch.c` for receiver lifetime handling.
  Its build copy also prioritizes Homebrew OpenSSL 3 headers, explicitly links
  OpenSSL 3, and disables the GStreamer Cocoa main wrapper: this helper creates
  no Cocoa windows and shares video buffers using Mach ports.
  The mirror pipeline uses an appsrc directly connected to the custom compressed
  H.264/HEVC sink. The renderer's library remains responsible for AirPlay connection
  lifecycle; video decoding is implemented independently in `Native/RealtimeH264.c`
  using Apple's system VideoToolbox/CoreVideo frameworks.
  These changes are applied to a build copy; vendored sources are unchanged.
- Embedded components include PlayFair (GPL), ShairPlay-derived code (LGPL),
  and llhttp (MIT). See UxPlay's README and component license files.

## GStreamer and runtime libraries

GStreamer is distributed under LGPL-2.1-or-later; individual plugins and
dependencies retain their own licenses. Airplayer dynamically links GStreamer
and provides a GPL transport plugin, `Native/gstairplayersink.c`.

The build copies a limited set of plugins, their transitive dynamic libraries,
and available Homebrew license files into
`Airplayer.app/Contents/Resources/Runtime/`. `origins.json` records each copied
binary's source. Development dependencies can be installed using Homebrew;
their source and build recipes are available at https://github.com/Homebrew/homebrew-core
and https://gstreamer.freedesktop.org/src/.

UxPlay statically links libplist and OpenSSL on macOS. Their installed license
files are also copied into the application's runtime license directory.
The application is locally ad-hoc signed and can be rebuilt or re-signed after
replacing dynamically linked libraries with compatible versions.

When distributing a build to others, provide the corresponding source of this
application and the bundled components as required by their respective licenses.

For packaged releases, `Runtime/source-recipes/` includes the exact installed
Homebrew formula recipes, with upstream source URLs, hashes, patches, and build
instructions. Release dependency-source references and the application's source
archive are published alongside the app. Apple's frameworks are supplied by macOS
and are not bundled here.
