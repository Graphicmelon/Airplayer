#!/usr/bin/env python3
"""Copy a minimal GStreamer runtime and recursively relocate its Mach-O libraries.

The resulting app must not retain any link to the build machine's Homebrew.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess


def run(*args):
    return subprocess.check_output(args, text=True)


def dependencies(binary):
    return [line.strip().split(" (", 1)[0] for line in run("otool", "-L", str(binary)).splitlines()[1:] if line.strip()]


def rpaths(binary):
    return re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset", run("otool", "-l", str(binary)))


def system(path):
    return path.startswith(("/usr/lib/", "/System/Library/"))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--prefix", required=True, type=Path)
    parser.add_argument("--uxplay", required=True, type=Path)
    parser.add_argument("--plugin", required=True, type=Path)
    parser.add_argument("--destination", required=True, type=Path)
    parser.add_argument("--diagnostics", action="store_true")
    args = parser.parse_args()
    runtime = args.destination
    # A rebuild must not keep plugins or libraries removed from the manifest.
    if runtime.exists():
        shutil.rmtree(runtime)
    for directory in ("bin", "lib", "plugins", "licenses", "source-recipes"):
        (runtime / directory).mkdir(parents=True, exist_ok=True)
    gst = Path(run("brew", "--prefix", "gstreamer").strip())
    plugin_root = gst / "lib/gstreamer-1.0"
    plugins = [
        "coreelements", "app", "videoconvertscale", "videoparsersbad", "playback",
        "typefindfunctions", "applemedia", "libav", "audioconvert", "audioresample",
        "audioparsers", "volume", "level", "osxaudio", "autodetect", "videofilter",
    ]
    if args.diagnostics:
        plugins += ["videotestsrc", "x264", "audiotestsrc"]
    queue = []
    copied = {}
    origins = {}

    def enqueue(source, destination):
        source = source.resolve(strict=True)
        if destination in copied:
            if copied[destination] != source:
                raise RuntimeError(f"Conflicting library names: {source} and {copied[destination]}")
            return
        shutil.copy2(source, destination)
        destination.chmod(destination.stat().st_mode | 0o200)
        copied[destination] = source
        origins[str(destination.relative_to(runtime))] = ("Cellar/" + str(source).split("/Cellar/", 1)[1]
            if "/Cellar/" in str(source) else source.name)
        queue.append((source, destination))

    enqueue(args.uxplay, runtime / "bin/uxplay")
    enqueue(args.plugin, runtime / "plugins/libgstairplayer.dylib")
    scanner = gst / "libexec/gstreamer-1.0/gst-plugin-scanner"
    enqueue(scanner, runtime / "bin/gst-plugin-scanner")
    if args.diagnostics:
        enqueue(gst / "bin/gst-launch-1.0", runtime / "bin/gst-launch-1.0")
    for name in plugins:
        enqueue(plugin_root / f"libgst{name}.dylib", runtime / f"plugins/libgst{name}.dylib")

    index = 0
    while index < len(queue):
        source, destination = queue[index]
        index += 1
        changes = []
        for dep in dependencies(source):
            if system(dep):
                continue
            # otool -L prints the dylib's own ID as its first entry.
            if source.suffix == ".dylib" and dep == run("otool", "-D", str(source)).splitlines()[-1].strip():
                continue
            if dep.startswith("/"):
                resolved = Path(dep)
            else:
                candidates = [source.parent / Path(dep).name, args.prefix / "lib" / Path(dep).name]
                for search in rpaths(source):
                    expanded = search.replace("@loader_path", str(source.parent))
                    candidates.append(Path(expanded) / dep.removeprefix("@rpath/"))
                resolved = next((p for p in candidates if p.is_file()), None)
                if resolved is None:
                    raise RuntimeError(f"Cannot resolve {dep} needed by {source}")
            target = runtime / "lib" / resolved.name
            enqueue(resolved, target)
            relocated = "@loader_path/" + os.path.relpath(target, destination.parent)
            changes += ["-change", dep, relocated]
        if destination.suffix == ".dylib":
            changes += ["-id", "@rpath/" + destination.name]
        if changes:
            subprocess.run(["codesign", "--remove-signature", str(destination)], capture_output=True)
            subprocess.check_call(["install_name_tool", *changes, str(destination)])

    # Capture the license material for every packaged Homebrew library.
    formula_roots = set()
    for source, _ in queue:
        parts = source.parts
        if "Cellar" in parts:
            cellar_index = parts.index("Cellar")
            formula_roots.add(Path(*parts[:cellar_index + 3]))
    for root in sorted(formula_roots):
        name = root.parent.name
        dest = runtime / "licenses" / name
        dest.mkdir(exist_ok=True)
        for recipe in (root / ".brew").glob("*.rb"):
            shutil.copy2(recipe, runtime / "source-recipes" / recipe.name)
        for pattern in ("LICENSE*", "COPYING*", "NOTICE*", "AUTHORS*", "share/doc/*/LICENSE*", "share/doc/*/COPYING*"):
            for file in root.glob(pattern):
                if file.is_file():
                    shutil.copy2(file, dest / file.name)
    # UxPlay links these two libraries statically on macOS.
    for name in ("libplist", "openssl@3"):
        root = Path(run("brew", "--prefix", name).strip()).resolve()
        dest = runtime / "licenses" / name
        dest.mkdir(exist_ok=True)
        for recipe in (root / ".brew").glob("*.rb"):
            shutil.copy2(recipe, runtime / "source-recipes" / recipe.name)
        for pattern in ("LICENSE*", "COPYING*", "NOTICE*"):
            for file in root.glob(pattern):
                if file.is_file():
                    shutil.copy2(file, dest / file.name)
    for _, binary in queue:
        for dep in dependencies(binary):
            if not system(dep) and not dep.startswith("@loader_path/") and dep != "@rpath/" + binary.name:
                raise RuntimeError(f"Unrelocated dependency in {binary}: {dep}")
        subprocess.check_call(["codesign", "--force", "--sign", "-", str(binary)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    import json
    (runtime / "origins.json").write_text(json.dumps(origins, indent=2) + "\n")
    print(f"Bundled {len(queue)} binaries; all dependencies relocated.")


if __name__ == "__main__":
    main()
