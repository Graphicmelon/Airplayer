#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/dist/Airplayer.app"
if [ -n "$(git status --porcelain)" ]; then
    echo "Commit the source before packaging a release." >&2
    exit 1
fi
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
SOURCE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
[ "$VERSION" = "$SOURCE_VERSION" ] || { echo 'Rebuild the app for this source version.' >&2; exit 1; }
ARCH=$(uname -m)
OUTPUT="$ROOT/dist/releases"
mkdir -p "$OUTPUT"
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT/Airplayer-$VERSION-macos-$ARCH.zip"
git archive --format=tar.gz --prefix="Airplayer-$VERSION/" HEAD > "$OUTPUT/Airplayer-$VERSION-source.tar.gz"
python3 - "$APP/Contents/Resources/Runtime" "$OUTPUT" "$VERSION" <<'PY'
import json, re, sys, tarfile
from pathlib import Path
runtime, output = map(Path, sys.argv[1:3])
version = sys.argv[3]
lines = ['# Dependency sources', '', 'Exact installed Homebrew recipes are included in the dependency-recipes archive.',
         'They retain upstream source URLs, source hashes, patches, and build instructions.',
         'The app and UxPlay sources are in the Airplayer source archive.', '',
         '## Upstream source downloads', '']
for recipe in sorted((runtime / 'source-recipes').glob('*.rb')):
    urls = list(dict.fromkeys(re.findall(r'^\s*url "(https?://[^"\n]+)"', recipe.read_text(), re.M)))
    lines += [f'### {recipe.stem}', ''] + [f'- {url}' for url in urls] + ['']
lines += ['## Packaged binary origins', '', '```json', (runtime / 'origins.json').read_text().strip(), '```', '']
(output / 'DEPENDENCY-SOURCES.md').write_text('\n'.join(lines))
with tarfile.open(output / f'Airplayer-{version}-dependency-recipes.tar.gz', 'w:gz') as archive:
    for name in ('source-recipes', 'licenses', 'origins.json'):
        archive.add(runtime / name, arcname=name)
    archive.add(output / 'DEPENDENCY-SOURCES.md', arcname='DEPENDENCY-SOURCES.md')
PY
(
    cd "$OUTPUT"
    shasum -a 256 "Airplayer-$VERSION-macos-$ARCH.zip" "Airplayer-$VERSION-source.tar.gz" \
        "Airplayer-$VERSION-dependency-recipes.tar.gz" DEPENDENCY-SOURCES.md > SHA256SUMS
)
echo "Release assets: $OUTPUT"
