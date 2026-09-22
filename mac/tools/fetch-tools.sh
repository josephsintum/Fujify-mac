#!/bin/sh
#
# fetch-tools.sh — download the command-line tools Fujify ships inside its
# app bundle, so a user never has to install anything to process a file.
#
# Usage:
#   tools/fetch-tools.sh            # fetch anything missing
#   tools/fetch-tools.sh --list     # show what is present
#   tools/fetch-tools.sh --clean    # remove the fetched tools
#
# Run this once before `xcodegen generate`, and again when the pinned
# versions below change. The downloads land in Vendor/, which is gitignored:
# committing ~25 MB of third-party binaries to every clone is not worth it
# when one command reproduces them.
#
# The app degrades gracefully if you skip this: ToolLocator falls back to a
# Homebrew or system install, and says "Not installed" in Settings if there
# is none. You just don't get the no-install-required experience.
#
# What is fetched:
#
#   Vendor/exiftool/         exiftool + lib/, from the tagged GitHub release.
#                            Run as `/usr/bin/perl Vendor/exiftool/exiftool`,
#                            so no shebang fix-up or execute bit is needed.
#                            The Lang/, t/ and html/ trees are dropped —
#                            translations, tests and docs we never read.
#
#   Vendor/dnglab            the macOS binary from the dnglab GitHub release.
#
# Licences are committed in Vendor/LICENSES/ and shown in the About box.
#
# NOTE: dnglab publishes an arm64 build for macOS and no x86_64 one, so on an
# Intel Mac the bundled copy cannot run. ToolLocator handles that by actually
# running `--version` on each candidate and discarding the ones that fail, so
# an Intel Mac falls back to a Homebrew dnglab or to Adobe DNG Converter.
#

set -eu

EXIFTOOL_VERSION="13.59"
DNGLAB_VERSION="0.8.0"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST="$ROOT/Vendor"

usage() {
    sed -n '3,38p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

list_only=0
clean=0
while [ $# -gt 0 ]; do
    case "$1" in
        --list)    list_only=1; shift ;;
        --clean)   clean=1; shift ;;
        -h|--help) usage ;;
        *) echo "fetch-tools: unknown option $1" >&2; usage ;;
    esac
done

if [ "$clean" -eq 1 ]; then
    rm -rf "$DEST/exiftool" "$DEST/dnglab"
    echo "Removed the fetched tools from $DEST"
    echo "(Vendor/LICENSES/ is committed and was kept. The shared exiftool config"
    echo " lives in tools/ at the repo root and is not touched by this script.)"
    exit 0
fi

if [ "$list_only" -eq 1 ]; then
    echo "Bundled tools in $DEST"
    echo
    if [ -f "$DEST/exiftool/exiftool" ]; then
        printf '  present  exiftool  %s  (%s)\n' \
            "$(/usr/bin/perl "$DEST/exiftool/exiftool" -ver 2>/dev/null || echo '?')" \
            "$(du -sh "$DEST/exiftool" | cut -f1 | tr -d ' \t')"
    else
        printf '  missing  exiftool  (want %s)\n' "$EXIFTOOL_VERSION"
    fi
    if [ -x "$DEST/dnglab" ]; then
        printf '  present  dnglab    %s  (%s)\n' \
            "$("$DEST/dnglab" --version 2>/dev/null | awk '{print $2}' || echo 'cannot run here')" \
            "$(du -sh "$DEST/dnglab" | cut -f1 | tr -d ' \t')"
    else
        printf '  missing  dnglab    (want %s)\n' "$DNGLAB_VERSION"
    fi
    exit 0
fi

command -v curl >/dev/null 2>&1 || { echo "fetch-tools: curl not found" >&2; exit 127; }

mkdir -p "$DEST"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

# ---------------------------------------------------------------- exiftool
if [ -f "$DEST/exiftool/exiftool" ] \
    && [ "$(/usr/bin/perl "$DEST/exiftool/exiftool" -ver 2>/dev/null)" = "$EXIFTOOL_VERSION" ]
then
    echo "have    exiftool $EXIFTOOL_VERSION"
else
    echo "fetch   exiftool $EXIFTOOL_VERSION"
    URL="https://github.com/exiftool/exiftool/archive/refs/tags/$EXIFTOOL_VERSION.tar.gz"
    if curl -fsSL --retry 2 --max-time 300 -o "$TMP/exiftool.tar.gz" "$URL"; then
        tar xzf "$TMP/exiftool.tar.gz" -C "$TMP"
        SRC="$TMP/exiftool-$EXIFTOOL_VERSION"

        rm -rf "$DEST/exiftool"
        mkdir -p "$DEST/exiftool"
        cp "$SRC/exiftool" "$DEST/exiftool/"
        cp -R "$SRC/lib" "$DEST/exiftool/"
        # Translations we never surface, and the geolocation database, which
        # is large and unused: Fujify only reads and writes camera tags.
        rm -rf "$DEST/exiftool/lib/Image/ExifTool/Lang"
        cp "$SRC/LICENSE" "$DEST/LICENSES/exiftool.txt" 2>/dev/null || true

        echo "        $(/usr/bin/perl "$DEST/exiftool/exiftool" -ver) in $(du -sh "$DEST/exiftool" | cut -f1 | tr -d ' \t')"
    else
        echo "        FAILED — check https://github.com/exiftool/exiftool/tags" >&2
    fi
fi

# ------------------------------------------------------------------ dnglab
if [ -x "$DEST/dnglab" ] \
    && "$DEST/dnglab" --version 2>/dev/null | grep -q "$DNGLAB_VERSION"
then
    echo "have    dnglab $DNGLAB_VERSION"
else
    echo "fetch   dnglab $DNGLAB_VERSION"
    URL="https://github.com/dnglab/dnglab/releases/download/v$DNGLAB_VERSION/dnglab-macos-arm64_v$DNGLAB_VERSION.zip"
    if curl -fsSL --retry 2 --max-time 300 -o "$TMP/dnglab.zip" "$URL"; then
        unzip -q -o "$TMP/dnglab.zip" -d "$TMP/dnglab-unpacked"
        FOUND=$(find "$TMP/dnglab-unpacked" -type f -name dnglab | head -1)
        if [ -n "$FOUND" ]; then
            cp "$FOUND" "$DEST/dnglab"
            chmod +x "$DEST/dnglab"
            if "$DEST/dnglab" --version >/dev/null 2>&1; then
                echo "        $("$DEST/dnglab" --version) in $(du -sh "$DEST/dnglab" | cut -f1 | tr -d ' \t')"
            else
                echo "        installed, but it does not run on this Mac (arm64 build)."
                echo "        Fujify will fall back to Homebrew dnglab or Adobe DNG Converter."
            fi
        else
            echo "        FAILED — no dnglab binary inside the zip" >&2
        fi
    else
        echo "        FAILED — check https://github.com/dnglab/dnglab/releases" >&2
    fi
fi

echo
echo "Tools in $DEST"
echo "  These are gitignored. Re-run this script on a fresh clone,"
echo "  then 'xcodegen generate' to pick them up."
