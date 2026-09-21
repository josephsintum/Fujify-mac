#!/bin/sh
#
# verify-dng.sh — assert that a DNG carries the camera identity tags Fujify
# writes, so Lightroom will offer that camera's film simulation profiles.
#
# This is the golden test for docs/PIPELINE-CONTRACT.md §3.1. Both the macOS
# and the Windows app must produce files that pass it. Keep it POSIX sh and
# exiftool-only so it runs unchanged in Git Bash on Windows.
#
# Usage:
#   tools/verify-dng.sh <file.dng> [target model]
#   tools/verify-dng.sh out/*.dng                 # several files
#   tools/verify-dng.sh -m X100VI out/*.dng       # non-default target
#
# Default target model is X-T5. Exit status is 0 when every file passes.
#

set -u

TARGET_MODEL="X-T5"
TARGET_MAKE="FUJIFILM"

usage() {
    sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        -m|--model) TARGET_MODEL="${2:-}"; [ -n "$TARGET_MODEL" ] || usage; shift 2 ;;
        -h|--help)  usage ;;
        --)         shift; break ;;
        -*)         echo "verify-dng: unknown option $1" >&2; usage ;;
        *)          break ;;
    esac
done

[ $# -ge 1 ] || usage

# A second bare argument is the target model, so both of these work:
#   verify-dng.sh file.dng X100VI
#   verify-dng.sh -m X100VI file.dng
if [ $# -eq 2 ] && [ ! -e "$2" ]; then
    TARGET_MODEL="$2"
    set -- "$1"
fi

if ! command -v exiftool >/dev/null 2>&1; then
    echo "verify-dng: exiftool not found on PATH" >&2
    echo "  macOS:   brew install exiftool" >&2
    echo "  Windows: use the exiftool.exe bundled with Fujify, or install it" >&2
    exit 127
fi

TARGET_UNIQUE="Fujifilm $TARGET_MODEL"

# Every value exiftool reports for a tag must equal the expected string. A DNG
# can hold several camera profiles, in which case exiftool joins the values
# with ", " — all of them have to match, or Lightroom sees a mixed identity.
check_tag() {
    _file="$1"; _tag="$2"; _want="$3"
    _got=$(exiftool -s3 -"$_tag" "$_file" 2>/dev/null)

    if [ -z "$_got" ]; then
        echo "    $_tag: MISSING (expected \"$_want\")"
        return 1
    fi

    # Split on ", " and compare each element.
    _bad=0
    _old_ifs=$IFS
    IFS=,
    for _part in $_got; do
        _part=$(printf '%s' "$_part" | sed 's/^ *//; s/ *$//')
        [ "$_part" = "$_want" ] || _bad=1
    done
    IFS=$_old_ifs

    if [ "$_bad" -ne 0 ]; then
        echo "    $_tag: \"$_got\" (expected \"$_want\")"
        return 1
    fi

    echo "    $_tag: $_got"
    return 0
}

FAILED=0
CHECKED=0

for FILE in "$@"; do
    CHECKED=$((CHECKED + 1))

    if [ ! -f "$FILE" ]; then
        echo "FAIL $FILE"
        echo "    file does not exist"
        FAILED=$((FAILED + 1))
        continue
    fi

    RESULT=0
    OUTPUT=$(
        check_tag "$FILE" CameraProfilesMake "$TARGET_MAKE" || exit 1
        check_tag "$FILE" CameraProfilesModel "$TARGET_MODEL" || exit 1
        check_tag "$FILE" CameraProfilesUniqueCameraModel "$TARGET_UNIQUE" || exit 1
        check_tag "$FILE" UniqueCameraModel "$TARGET_UNIQUE" || exit 1
    ) || RESULT=1

    # check_tag returns on the first failure, so re-run to collect every
    # mismatch for the report rather than just the first one.
    if [ "$RESULT" -ne 0 ]; then
        OUTPUT=$(
            check_tag "$FILE" CameraProfilesMake "$TARGET_MAKE"
            check_tag "$FILE" CameraProfilesModel "$TARGET_MODEL"
            check_tag "$FILE" CameraProfilesUniqueCameraModel "$TARGET_UNIQUE"
            check_tag "$FILE" UniqueCameraModel "$TARGET_UNIQUE"
        )
        echo "FAIL $FILE"
        printf '%s\n' "$OUTPUT"
        FAILED=$((FAILED + 1))
    else
        echo "ok   $FILE ($TARGET_MAKE $TARGET_MODEL)"
    fi
done

echo
if [ "$FAILED" -eq 0 ]; then
    echo "$CHECKED file(s) carry the $TARGET_MAKE $TARGET_MODEL identity."
    exit 0
fi

echo "$FAILED of $CHECKED file(s) failed."
exit 1
