#!/bin/sh
# Runs the plugin in KOReader's desktop build, headless, and checks what it
# does: the markup export, the pen menu and Highlight tool, ink after a font
# change or a turn of the screen, and renaming and copying a book
# (forktest.koplugin).
#
#   tests/desktop/run.sh [koreader dir]
#
# Without a KOReader folder, the Linux release below is downloaded into
# tests/desktop/.koreader. Needs glibc 2.35 or newer, and python3.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$(dirname "$HERE")")
VERSION=v2026.07.1
KO=${1:-$HERE/.koreader}

if [ ! -x "$KO/bin/koreader" ]; then
    mkdir -p "$KO"
    url="https://github.com/koreader/koreader/releases/download/$VERSION/koreader-linux-x86_64-$VERSION.tar.xz"
    echo "Downloading KOReader $VERSION…"
    curl -fsSL "$url" | tar -xJ -C "$KO"
fi

PLUGINS="$KO/lib/koreader/plugins"
rm -rf "$PLUGINS/pencil.koplugin" "$PLUGINS/forktest.koplugin"
cp -r "$ROOT/pencil.koplugin" "$HERE/forktest.koplugin" "$PLUGINS/"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; rm -rf "$PLUGINS/forktest.koplugin"' EXIT
failed=0

# test NAME VARIABLE [BOOK NAME] [VAR=VALUE...]: one run, in its own profile.
test_one() {
    name=$1 var=$2 book=${3:-odyssey.epub}
    shift 2
    if [ $# -gt 0 ]; then shift; fi
    mkdir -p "$WORK/$name/home"
    cp "$HERE/odyssey.epub" "$WORK/$name/$book"
    env "$@" HOME="$WORK/$name/home" SDL_VIDEODRIVER=dummy \
        EMULATE_READER_W=1053 EMULATE_READER_H=1400 EMULATE_READER_DPI=300 \
        "$var=$WORK/$name/result.json" \
        timeout 300 "$KO/bin/koreader" "$WORK/$name/$book" > "$WORK/$name/log.txt" 2>&1 || true
    if ! python3 - "$name" "$WORK/$name/result.json" <<'PY'
import json, sys
name, path = sys.argv[1], sys.argv[2]
try:
    checks = json.load(open(path))["checks"]
except (OSError, ValueError, KeyError):
    print(f"FAIL {name}: no results (see its log)")
    sys.exit(1)
bad = [c for c in checks if not c["ok"]]
for c in checks:
    print(f"  {'ok  ' if c['ok'] else 'FAIL'} {c['name']}" + ("" if c["ok"] else f"  {c.get('detail')}"))
print(f"{name}: {len(checks) - len(bad)} of {len(checks)}")
sys.exit(1 if bad or not checks else 0)
PY
    then
        failed=1
        tail -20 "$WORK/$name/log.txt"
    fi
}

test_one export FORKTEST_EXPORT
test_one highlight FORKTEST_HIGHLIGHT
test_one font FORKTEST_FONT
test_one marks FORKTEST_MARKS odyssey.epub
test_one marks-wrapped FORKTEST_MARKS odyssey.epub FORKTEST_GROW=40
test_one rename FORKTEST_RENAME a.epub
test_one rotate FORKTEST_ROTATE
test_one bookmarks FORKTEST_BOOKMARKS

exit $failed
