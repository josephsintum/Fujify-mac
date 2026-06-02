# Fujify for macOS

A macOS app that unlocks Fujifilm film simulation profiles in Adobe Lightroom for RAW files from non-Fuji cameras. Native SwiftUI port of the original Windows [Fujify](https://github.com/ip-web/Fujify) by Isidore Paulin.

<img src="Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" alt="Fujify icon">

> Most of this repository was written with the help of [Claude](https://www.anthropic.com/claude) (Anthropic's AI assistant) in an extended pair-programming session: the Swift code, the design doc under [`docs/plans/`](docs/plans/), the build tooling, and this README. The original concept, the metadata trick, and the Windows implementation are entirely [Isidore Paulin's](https://github.com/ip-web) work.

## How it works

The clever bit, courtesy of the original Fujify: Adobe Lightroom gates the Fujifilm simulation profiles (Provia, Velvia, Astia, Classic Chrome, Acros, Eterna, Nostalgic Neg., etc.) on the DNG's camera metadata. Rewrite a few `CameraProfile*` tags to identify the file as a Fujifilm X-T5, and Lightroom's profile picker exposes every Fuji simulation profile for the shot — even though it was taken on a Sony, Canon, or Nikon body.

For each file Fujify:

1. Optionally converts your RAW → DNG (via Adobe DNG Converter or dnglab)
2. Injects the Fujifilm X-T5 `CameraProfile` tags via [exiftool](https://exiftool.org/)
3. Leaves the source RAW untouched

Import the resulting DNG into Lightroom Classic and the Fuji film simulations appear in the Profile picker, just as if you'd shot the file on a Fuji.

## Requirements

- macOS 14 (Sonoma) or later
- [exiftool](https://exiftool.org/) — `brew install exiftool`
- One backend for RAW → DNG conversion:
  - **[Adobe DNG Converter](https://helpx.adobe.com/camera-raw/using/adobe-dng-converter.html)** (recommended) — best camera coverage, including newer bodies like the Sony A7 V
  - **[dnglab](https://github.com/dnglab/dnglab)** — open-source, install via Homebrew (`brew install dnglab`) or a [release binary](https://github.com/dnglab/dnglab/releases)
  - **Lightroom Classic** — pre-convert via Library → Convert Photo to DNG, then drop the DNGs into Fujify

The app detects whatever's installed on first launch and picks the best available. You can override the choice in Settings (⌘,).

## Install / build

This is a personal fork — not distributed as a signed `.app`. To build from source:

```sh
git clone https://github.com/josephsintum/Fujify-mac.git
cd Fujify-mac
brew install xcodegen exiftool
xcodegen generate
open Fujify.xcodeproj
```

Build and run in Xcode (⌘R). The app is unsandboxed and uses ad-hoc local signing.

## Usage

1. Drag RAW files or folders into the window (or click **+ Add Files**).
2. Optional: pick an output folder. Leave as "In place" to overwrite metadata on existing DNGs.
3. Click **Process**.
4. Import the resulting DNGs into Lightroom Classic.
5. Open the Profile picker — Fujifilm film simulations are now available.

| Shortcut | Action |
|---|---|
| ⌘I | Toggle Inspector (full exiftool dump for the selected file) |
| ⌘, | Open Settings (converter preference, embed-original-RAW toggle) |
| ⌫ | Remove selected files from the list |

## Camera support

The Fuji metadata injection works on any DNG, regardless of which camera the original RAW came from. The bottleneck is the RAW → DNG step:

- **Adobe DNG Converter** handles essentially every camera Adobe supports in Lightroom.
- **dnglab** has [broad coverage](https://github.com/dnglab/dnglab/blob/main/SUPPORTED_CAMERAS.md) but lags on newer bodies (e.g., the Sony A7 V isn't yet supported as of dnglab 0.7.2).

If your camera isn't supported by either, pre-convert to DNG with Lightroom Classic and drop the DNGs into Fujify directly.

## Architecture

~1,000 LOC of Swift across three layers:

- **`Engine/`** — subprocess wrappers for exiftool, dnglab, Adobe DNG Converter, plus a QuickLook-backed thumbnail generator. No SwiftUI imports.
- **`Models/`** — `Pipeline` (batch orchestrator with cancellation) and `FileItem` (per-file state). `@Observable @MainActor`. Bounded-concurrency fan-out for metadata + thumbnails.
- **`Views/`** — `ContentView`, `SettingsView`, `InspectorView`, `ToolSetupSheet`.

The Xcode project is regenerated from `project.yml` by [xcodegen](https://github.com/yonaskolb/XcodeGen) — `Fujify.xcodeproj` is gitignored. To add a Swift file, drop it in the relevant folder and re-run `xcodegen generate`.

The app icon is regenerated from `tools/render-icon.swift` (a pure-AppKit script that draws the squircle, wordmark, and accent stripe natively at each required pixel size). Run `swift tools/render-icon.swift` to rebuild the icon assets.

## Differences from the Windows original

The original is a 3,300 LOC WPF .NET application that bundles `exiftool.exe`, `dnglab.exe`, and a partial libraw build as Windows binaries. The Mac rewrite:

- Native SwiftUI with macOS conventions: NSToolbar, sheets, ⌘, Settings, ⌘I Inspector, drag-drop everywhere, system dark mode.
- ~1,000 LOC of Swift, no Material Design, no manual theme management, no custom title-bar code.
- Uses the OS-native QuickLook for thumbnails — no libraw dependency.
- exiftool / dnglab / Adobe DNG Converter are user-installed rather than bundled.

The metadata trick itself is identical — same seven exiftool tags. The Mac version remains GPL v3 and depends on the same open-source tools.

The historical Windows source and a Python CLI prototype live in [`reference/`](reference/).

## FAQ

**Does this work with Capture One or other editors?**
No. Lightroom Classic only — the trick relies on Lightroom's specific profile-picker behavior. The original author noted the same.

**Will I get exactly the same colors as a real Fujifilm camera?**
Adobe's profiles are recreations of Fujifilm's, not the originals. They're a very close match on most scenes but were tuned for Fujifilm sensors, so results on Sony/Canon/Nikon files will be approximate. For exact Fuji color, shoot Fuji.

**Why does my conversion fail with "Unsupported camera"?**
dnglab doesn't yet know about your camera (typically newer bodies). Install Adobe DNG Converter, or pre-convert with Lightroom Classic, and try again. Fujify will pick up Adobe DNG Converter automatically on next launch.

**Can I use this on Fujifilm RAF files?**
Technically yes — it'd unlock newer simulations on older Fuji bodies. The original Fujify README points to [a pal2tech video](https://www.youtube.com/watch?v=UUce-04DoSM) on doing this without modifying RAFs.

## Credits

- **[Isidore Paulin](https://github.com/ip-web)** — created the original Fujify (Windows app), discovered the metadata trick, did the hard work.
- **[Phil Harvey](https://exiftool.org/)** — ExifTool.
- **[DNGLab](https://github.com/dnglab/dnglab)** — open-source RAW → DNG converter.
- **Adobe** — DNG Converter, Camera Raw, Lightroom Classic.

## License

GPL v3, inherited from the original Fujify. See [`LICENSE`](LICENSE). ExifTool is licensed under the Perl Artistic Licence; DNGLab under LGPL 2.1.
