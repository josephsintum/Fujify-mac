#!/usr/bin/env python3
"""fujify — apply Fujifilm X-T5 film simulation profiles to RAW files.

Usage: fujify.py FILE [FILE ...]

For each input file:
  - if not already DNG, convert via `dnglab convert`
  - rewrite DNG CameraProfile tags so Lightroom offers Fuji film simulations
"""
import shutil
import subprocess
import sys
from pathlib import Path

SUPPORTED_EXTS = {
    ".dng", ".cr3", ".cr2", ".crw", ".erf", ".raf", ".3fr", ".kdc", ".dcs",
    ".dcr", ".iiq", ".mos", ".mef", ".mrw", ".nef", ".nrw", ".orf", ".rw2",
    ".pef", ".srw", ".arw", ".srf", ".sr2", ".ari",
}

EXIFTOOL_ARGS = [
    "-CameraProfilesMake=FUJIFILM",
    "-CameraProfilesModel=X-T5",
    "-CameraProfilesUniqueCameraModel=Fujifilm X-T5",
    "-CameraProfilesCameraRawProfile=True",
    "-UniqueCameraModel=Fujifilm X-T5",
    "-overwrite_original",
    "-m",
]


def check_deps() -> None:
    missing = [t for t in ("exiftool", "dnglab") if shutil.which(t) is None]
    if missing:
        sys.exit(
            f"error: missing tools on PATH: {', '.join(missing)}\n"
            f"install with: brew install {' '.join(missing)}"
        )


def convert_to_dng(src: Path) -> Path:
    dst = src.with_suffix(".dng")
    result = subprocess.run(
        ["dnglab", "convert", str(src), str(dst)],
        capture_output=True, text=True,
    )
    if result.returncode != 0 or not dst.exists():
        msg = result.stderr.strip() or result.stdout.strip() or "unknown error"
        raise RuntimeError(f"dnglab failed: {msg}")
    return dst


def inject_fuji_metadata(dng: Path) -> None:
    result = subprocess.run(
        ["exiftool", *EXIFTOOL_ARGS, str(dng)],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        msg = result.stderr.strip() or result.stdout.strip() or "unknown error"
        raise RuntimeError(f"exiftool failed: {msg}")


def process(path: Path) -> None:
    ext = path.suffix.lower()
    if ext not in SUPPORTED_EXTS:
        print(f"skip: {path.name} (unsupported extension {ext})")
        return

    print(f"processing: {path.name}")
    if ext == ".dng":
        dng = path
    else:
        print("  converting to DNG...")
        dng = convert_to_dng(path)

    print("  applying Fuji X-T5 profile metadata...")
    inject_fuji_metadata(dng)
    print(f"  done -> {dng.name}")


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(f"usage: {Path(sys.argv[0]).name} FILE [FILE ...]")

    check_deps()

    failed = 0
    for arg in sys.argv[1:]:
        path = Path(arg)
        if not path.exists():
            print(f"skip: {arg} (not found)")
            failed += 1
            continue
        try:
            process(path)
        except Exception as e:
            print(f"  FAILED: {e}")
            failed += 1

    if failed:
        sys.exit(f"\n{failed} file(s) failed")


if __name__ == "__main__":
    main()
