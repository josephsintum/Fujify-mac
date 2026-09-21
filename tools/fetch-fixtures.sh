#!/bin/sh
#
# fetch-fixtures.sh — download the sample RAW files the pipeline is tested
# against. They are CC0 samples from https://raw.pixls.us and are NOT
# committed: fixtures/ is gitignored.
#
# Usage:
#   tools/fetch-fixtures.sh            # fetch anything missing
#   tools/fetch-fixtures.sh --list     # show the set and what is present
#   tools/fetch-fixtures.sh --clean    # remove everything fetched
#
# The set covers the interesting cases rather than many cameras:
#
#   sony-a7s.arw       Sony        the mount this app was built for
#   canon-r6.cr3       Canon       a second mainstream mount
#   nikon-z6.nef       Nikon       make normalisation, "NIKON CORPORATION"
#   fuji-xt1.raf       Fujifilm    a RAW that is already Fuji
#   unsupported.nef    Nikon D1H   dnglab rejects it; Adobe converts it
#   sample.dng         built here  in-place input, needs confirmation
#
# unsupported.nef is the most valuable one: dnglab 0.8.0 answers it with
#   Unknown camera, model 'NIKON D1H', make: 'NIKON CORPORATION'
# which is the exact string docs/PIPELINE-CONTRACT.md §4.2 parses, while
# Adobe DNG Converter handles the file — the two together are the whole
# "install Adobe for wider coverage" story in 4 MB.
#

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST="$ROOT/fixtures"
BASE="https://raw.pixls.us/getfile.php"

# local name|raw.pixls.us id|filename on the server
# Look these up at https://raw.pixls.us — the table's download links carry
# the id, and json/getrepository.php?set=all is the machine-readable index.
SAMPLES=$(cat <<'EOF'
sony-a7s.arw|1582|Sony - ILCE-7S - 14bit 14bit compressed (3:2).ARW
canon-r6.cr3|4659|Canon - EOS R6 - 3:2.CR3
nikon-z6.nef|3587|Nikon - Z 6 - 12bit 12bit compressed (3:2).NEF
fuji-xt1.raf|2421|Fujifilm - X-T1 - 14bit 14bit uncompressed (3:2).RAF
unsupported.nef|5364|Nikon - D1H - 12bit 12bit uncompressed (3:2).NEF
EOF
)

usage() {
    sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

list_only=0
clean=0
while [ $# -gt 0 ]; do
    case "$1" in
        --list)    list_only=1; shift ;;
        --clean)   clean=1; shift ;;
        -h|--help) usage ;;
        *) echo "fetch-fixtures: unknown option $1" >&2; usage ;;
    esac
done

if [ "$clean" -eq 1 ]; then
    rm -rf "$DEST"
    echo "Removed $DEST"
    exit 0
fi

if [ "$list_only" -eq 1 ]; then
    echo "Fixture set in $DEST"
    echo
    printf '%s\n' "$SAMPLES" | while IFS='|' read -r name _ _; do
        if [ -f "$DEST/$name" ]; then
            printf '  present  %-18s %s\n' "$name" \
                "$(du -h "$DEST/$name" | cut -f1 | tr -d ' \t')"
        else
            printf '  missing  %s\n' "$name"
        fi
    done
    if [ -f "$DEST/sample.dng" ]; then
        printf '  present  %-18s %s\n' "sample.dng" \
            "$(du -h "$DEST/sample.dng" | cut -f1 | tr -d ' \t')"
    else
        printf '  missing  %-18s built locally from sony-a7s.arw\n' "sample.dng"
    fi
    exit 0
fi

command -v curl >/dev/null 2>&1 || { echo "fetch-fixtures: curl not found" >&2; exit 127; }

mkdir -p "$DEST"

# Server filenames contain spaces and parentheses, so percent-encode the
# path segment before handing it to curl.
urlencode_path() {
    printf '%s' "$1" | sed 's/ /%20/g'
}

printf '%s\n' "$SAMPLES" | while IFS='|' read -r name id filename; do
    [ -n "$name" ] || continue
    if [ -f "$DEST/$name" ]; then
        echo "have    $name"
        continue
    fi
    echo "fetch   $name"
    url="$BASE/$id/nice/$(urlencode_path "$filename")"
    if curl -fsSL --retry 2 --max-time 300 -o "$DEST/$name.part" "$url"; then
        mv "$DEST/$name.part" "$DEST/$name"
    else
        rm -f "$DEST/$name.part"
        echo "        FAILED — the sample may have been renamed or removed." >&2
        echo "        Find a replacement at https://raw.pixls.us and update" >&2
        echo "        the id and filename in this script." >&2
    fi
done

# The DNG fixture has to be a real DNG, so build it from the Sony sample
# with whichever converter is installed.
if [ ! -f "$DEST/sample.dng" ] && [ -f "$DEST/sony-a7s.arw" ]; then
    echo "build   sample.dng"
    ADOBE="/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter"
    if [ -x "$ADOBE" ]; then
        "$ADOBE" -c -fl -p2 -d "$DEST" "$DEST/sony-a7s.arw" >/dev/null 2>&1 || true
        [ -f "$DEST/sony-a7s.dng" ] && mv "$DEST/sony-a7s.dng" "$DEST/sample.dng"
    elif command -v dnglab >/dev/null 2>&1; then
        dnglab convert --embed-raw false \
            "$DEST/sony-a7s.arw" "$DEST/sample.dng" >/dev/null 2>&1 || true
    fi
    [ -f "$DEST/sample.dng" ] || \
        echo "        skipped — install Adobe DNG Converter or dnglab, then re-run." >&2
fi

echo
echo "Fixtures in $DEST"
ls -1 "$DEST" 2>/dev/null | sed 's/^/  /'
echo
echo "Gitignored. Re-run this script on a fresh clone."
