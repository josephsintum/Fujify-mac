# Fujify for macOS

A macOS app that unlocks Fujifilm film simulation profiles in Adobe Lightroom for RAW files from non-Fuji cameras. Native SwiftUI port of the original Windows [Fujify](https://github.com/ip-web/Fujify) by Isidore Paulin.

<img src="Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" alt="Fujify icon">

> Most of this repository was written with the help of [Claude](https://www.anthropic.com/claude) (Anthropic's AI assistant) in an extended pair-programming session: the Swift code, the design docs under [`docs/`](docs/), the build tooling, and this README. The original concept, the metadata trick, and the Windows implementation are entirely [Isidore Paulin's](https://github.com/ip-web) work.
>
> Not affiliated with, or endorsed by, Fujifilm.

## How it works

The clever bit, courtesy of the original Fujify: Adobe Lightroom gates the Fujifilm simulation profiles (Provia, Velvia, Astia, Classic Chrome, Acros, Eterna, Nostalgic Neg., Reala Ace, etc.) on the DNG's camera metadata. Rewrite a few `CameraProfile*` tags to identify the file as a Fujifilm body, and Lightroom's profile picker exposes every Fuji simulation for the shot — even though it was taken on a Sony, Canon, or Nikon.

For each file Fujify:

1. Optionally converts your RAW → DNG
2. Injects the target camera's `CameraProfile` tags via ExifTool
3. Records the file's original camera identity, so the change can be undone later
4. Leaves the source RAW untouched

Import the resulting DNG into Lightroom Classic and the Fuji film simulations appear in the Profile picker, just as if you'd shot the file on a Fuji.

The exact tags, flags and rules are specified in [`docs/PIPELINE-CONTRACT.md`](docs/PIPELINE-CONTRACT.md), which both this app and the planned Windows app implement.

## Requirements

- macOS 14 (Sonoma) or later
- Nothing else

ExifTool and dnglab ship inside the app. There is no install step and no Homebrew requirement.

**[Adobe DNG Converter](https://helpx.adobe.com/camera-raw/using/adobe-dng-converter.html) is optional but recommended.** It's a free download from Adobe and covers essentially every camera Lightroom supports, including recent bodies the bundled dnglab doesn't know yet — the Sony A7 V is the current example. Fujify picks it up automatically when it's installed and prefers it.

If a camera is supported by neither, convert to DNG in Lightroom Classic (Library → Convert Photo to DNG) and drop the DNGs into Fujify.

## Target cameras

Fujify ships with two targets:

| Target | What it unlocks |
|---|---|
| **Fujifilm X-T5** (default) | Nostalgic Neg., Classic Neg., Eterna Bleach Bypass and the classics |
| **Fujifilm X100VI** | Adds Reala Ace |

Pick one from **Profile as** in the toolbar. It's a per-batch setting and is remembered between launches.

You can add other Fujifilm bodies yourself with **Add Camera…**, which asks for the make and model and shows exactly which tags will be written. Copy the model name exactly as Adobe spells it — Fujify can't check that Lightroom recognises a name, only Lightroom can, so if the simulations don't appear after import, check the spelling against [Adobe's supported cameras list](https://helpx.adobe.com/camera-raw/kb/camera-raw-plug-supported-cameras.html).

## Usage

1. Drag RAW files or folders into the window, or click **+**.
2. Pick a target camera under **Profile as**.
3. Optional: pick an output folder. Leave it as **In place** to update existing DNGs where they are.
4. Click **Process**.
5. Import the resulting DNGs into Lightroom Classic and open the Profile picker.

**RAW files are never changed.** Converting a RAW always produces a new DNG. Tagging a DNG with no output folder set rewrites that file, so Fujify asks once per batch before doing it.

| Shortcut | Action |
|---|---|
| ⌘I | Toggle Inspector |
| ⌘, | Settings |
| ⌥⌘C | Copy path |
| ⌫ | Remove selected files from the list |

### When something goes wrong

Select the file and open the Inspector (⌘I). It explains what happened, what to do about it, and has the tool's raw output collapsed underneath with a Copy button for bug reports. After a batch, the status bar filters to **Done / Skipped / Failed** so you can walk through just the problems, and **Retry All** re-queues them.

## Build from source

```sh
git clone https://github.com/josephsintum/Fujify-mac.git
cd Fujify-mac
brew install xcodegen
tools/fetch-tools.sh      # downloads ExifTool and dnglab into Vendor/
xcodegen generate
open Fujify.xcodeproj
```

Build and run in Xcode (⌘R). The app is unsandboxed and uses ad-hoc local signing.

`tools/fetch-tools.sh` is what keeps ~25 MB of third-party binaries out of every clone. Skip it and the app still builds and runs; it just falls back to a Homebrew ExifTool and dnglab if you have them.

### Repository layout

| Path | What's in it |
|---|---|
| `Engine/` | Subprocess wrappers for ExifTool, dnglab and Adobe DNG Converter, plus QuickLook thumbnails and the Lightroom launcher. No SwiftUI imports. |
| `Models/` | `Pipeline` (batch orchestrator), `FileItem`, `TargetCamera`, `CameraStore`, and the structured failure types. `@Observable @MainActor`. |
| `Views/` | The main window, Inspector, Settings tabs and sheets. |
| `Tests/` | Swift Testing suites covering the contract's rules. |
| `docs/` | The pipeline contract and the design/planning docs. |
| `tools/` | Developer scripts: icon rendering, fixture and tool fetching, output verification. |
| `Vendor/` | Bundled ExifTool and dnglab (gitignored) plus their licences. |

The Xcode project is regenerated from `project.yml` by [xcodegen](https://github.com/yonaskolb/XcodeGen) — `Fujify.xcodeproj` is gitignored. To add a Swift file, drop it in the relevant folder and re-run `xcodegen generate`.

### Testing against real files

```sh
tools/fetch-fixtures.sh              # six CC0 samples from raw.pixls.us
xcodebuild -scheme Fujify test       # unit tests
tools/verify-dng.sh out/*.dng        # assert the identity tags on real output
tools/verify-dng.sh out/*.dng X100VI # ...against a different target
```

The fixture set covers Sony, Canon, Nikon and Fujifilm, a DNG for the in-place path, and a Nikon D1H that dnglab rejects and Adobe DNG Converter handles — which exercises the skip path and the fallback in one 4 MB file.

### Icons

```sh
swift tools/render-icon.swift              # macOS icon set
swift tools/render-icon.swift --windows    # Windows PNG set for an .ico
```

Every size is drawn natively rather than downsampled. Below 48px the wordmark is unreadable, so those sizes use an "f" monogram.

## Differences from the Windows original

The original is a 3,300 LOC WPF .NET application. This rewrite:

- Native SwiftUI with macOS conventions: NSToolbar, sheets, ⌘, Settings, ⌘I Inspector, drag-drop, system dark mode.
- Uses OS-native QuickLook for thumbnails — no libraw dependency.
- Adds a target camera picker, so you can choose which Fujifilm body Lightroom sees.
- Explains failures instead of printing stderr, and lets you filter and retry them.

The metadata trick itself is identical. The Mac version remains GPL v3 and depends on the same open-source tools.

## FAQ

**Does this work with Capture One or other editors?**
No. Lightroom Classic only — the trick relies on Lightroom's specific profile-picker behavior. The original author noted the same.

**Will I get exactly the same colors as a real Fujifilm camera?**
Adobe's profiles are recreations of Fujifilm's, not the originals. They're a very close match on most scenes but were tuned for Fujifilm sensors, so results on Sony/Canon/Nikon files will be approximate. For exact Fuji color, shoot Fuji.

**Why was my file skipped as "unsupported camera"?**
dnglab doesn't know that body yet, typically a recent one. Install Adobe DNG Converter, click **Check Again** in Settings, then **Retry**.

**Why was my file skipped as "already tagged"?**
It already carries the current target's tags, so there was nothing to do. Re-tagging for a *different* camera always runs — that's how you move a batch from the X-T5 to the X100VI for Reala Ace. Use **Process Again** to write the tags regardless.

**Can I use this on Fujifilm RAF files?**
Technically yes — it'd unlock newer simulations on older Fuji bodies. The original Fujify README points to [a pal2tech video](https://www.youtube.com/watch?v=UUce-04DoSM) on doing this without modifying RAFs.

## Credits

- **[Isidore Paulin](https://github.com/ip-web)** — created the original Fujify (Windows app), discovered the metadata trick, did the hard work.
- **[Phil Harvey](https://exiftool.org/)** — ExifTool.
- **[DNGLab](https://github.com/dnglab/dnglab)** — open-source RAW → DNG converter.
- **Adobe** — DNG Converter, Camera Raw, Lightroom Classic.

## License

GPL v3, inherited from the original Fujify. See [`LICENSE`](LICENSE). ExifTool is licensed under the Perl Artistic Licence; DNGLab under LGPL 2.1. Both licence texts ship inside the app bundle and are listed in the About box.
