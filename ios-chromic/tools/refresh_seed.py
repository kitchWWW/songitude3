#!/usr/bin/env python3
"""Refresh the Chromic apps' baked-in content snapshot ("seed").

Both Chromic apps open on a complete first frame — catalog, bio, artwork — because a copy of all
of it ships inside the app. On launch they render cache-then-seed and silently refetch. This
script takes the snapshot: the manifest filtered to Chromic, the artist profile, and every walk's
artwork downscaled to what the screens draw. Run it before a release, or whenever chromic duo
publish something:

    python3 ios-chromic/tools/refresh_seed.py

It also runs on every build of either app (an Xcode Run Script phase before Copy Bundle
Resources; a Gradle `preBuild` dependency), so a release can never ship a stale snapshot. If the
network is unreachable it warns and leaves the existing seed in place — a build must not fail for
want of wifi.

It writes the same files to
    ios-chromic/Chromic/Chromic/Seed/            (a folder reference in the Xcode target)
    android-chromic/app/src/main/assets/seed/    (Android assets)
plus an index.json mapping each source URL to its file, which is what the apps' ContentStore
reads. Needs Pillow (python3 -m pip install pillow).
"""
import io, json, os, sys, urllib.request
from PIL import Image

ROOT = "https://songitude-walks.s3.amazonaws.com"
ARTIST_ID = "80cda9dee7513416"
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
TARGETS = [
    os.path.join(REPO, "ios-chromic", "Chromic", "Chromic", "Seed"),
    os.path.join(REPO, "android-chromic", "app", "src", "main", "assets", "seed"),
]
MAX_PX = 1290   # 3x of a 430pt-wide phone: the walk page draws artwork edge to edge

def get(url):
    req = urllib.request.Request(url, headers={"Cache-Control": "no-cache"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.read()

def write_if_changed(path, data):
    try:
        with open(path, "rb") as f:
            if f.read() == data:
                return False
    except FileNotFoundError:
        pass
    with open(path, "wb") as f:
        f.write(data)
    return True

def main():
    files = {}   # filename -> bytes
    index = {}   # url -> filename

    manifest_url = f"{ROOT}/walks/manifest.json"
    manifest = json.loads(get(manifest_url))
    manifest["walks"] = [w for w in manifest["walks"] if w.get("artistId") == ARTIST_ID]
    files["manifest.json"] = json.dumps(manifest, indent=1).encode()
    index[manifest_url] = "manifest.json"
    print(f"manifest: {len(manifest['walks'])} walks")

    artist_url = f"{ROOT}/artists/{ARTIST_ID}.json"
    files[f"artist-{ARTIST_ID}.json"] = get(artist_url)
    index[artist_url] = f"artist-{ARTIST_ID}.json"
    print("artist profile ok")

    for w in manifest["walks"]:
        url = w.get("artUrl")
        if not url:
            continue
        im = Image.open(io.BytesIO(get(url)))
        im = im.convert("RGB")
        im.thumbnail((MAX_PX, MAX_PX), Image.LANCZOS)
        buf = io.BytesIO(); im.save(buf, "JPEG", quality=85, optimize=True, progressive=True)
        name = f"art-{w['id']}.jpg"
        files[name] = buf.getvalue()
        index[url] = name
        print(f"art {w['name']}: {im.size[0]}x{im.size[1]} {len(files[name])//1024} KB")

    files["index.json"] = json.dumps(index, indent=1, sort_keys=True).encode()
    for target in TARGETS:
        os.makedirs(target, exist_ok=True)
        for old in os.listdir(target):
            if old not in files:
                os.remove(os.path.join(target, old))
        # Only touch files whose bytes changed, so an unchanged seed doesn't churn Xcode's copy step.
        changed = sum(write_if_changed(os.path.join(target, name), data) for name, data in files.items())
        print(f"{os.path.relpath(target, REPO)}: {changed} of {len(files)} files changed")
    total = sum(len(b) for b in files.values())
    print(f"seed total {total/1e6:.2f} MB")

if __name__ == "__main__":
    try:
        main()
    except Exception as e:   # offline, S3 hiccup, missing Pillow — never fail the build over it
        print(f"warning: Chromic seed not refreshed ({e}); building with the existing snapshot", file=sys.stderr)
        sys.exit(0)
