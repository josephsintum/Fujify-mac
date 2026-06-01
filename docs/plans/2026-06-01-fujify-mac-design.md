# Fujify for macOS — Design

**Date:** 2026-06-01
**Status:** Validated, ready for implementation
**Scope:** Personal use only. No distribution, codesigning, or notarization in v1.

## Context

Fujify is a Windows .NET/WPF app that rewrites DNG metadata so Adobe Lightroom offers Fujifilm film simulation profiles for RAW files from non-Fuji cameras. The Mac port is a ground-up SwiftUI rewrite — not a line-by-line port — because WPF doesn't run on macOS and the original codebase is ~95% Windows-specific UI chrome.

The Python CLI (`fujify.py`) already replicates the core pipeline and validated the metadata trick end-to-end on a real Sony A7 V shoot (59 DNGs, all unlocked Fuji simulations in Lightroom). The Mac app is a native UI wrapper around that same pipeline.

**Preserved as reference (not deleted):**
- `reference/FujifyNET/` — original WPF app
- `reference/FujifyNET.sln` — solution file
- `reference/fujify.py` — Python CLI

## Project layout

```
Fujify/
├── reference/                       # historical Windows app + Python CLI
├── docs/plans/                      # design docs (this file)
├── README.md
├── LICENSE
├── .gitignore                       # covers Xcode/Swift artifacts
└── Fujify/                          # SwiftUI app (created by Xcode)
    ├── Fujify.xcodeproj
    └── Fujify/
        ├── FujifyApp.swift          # @main entry
        ├── ContentView.swift        # main window
        ├── Models/
        │   ├── FileItem.swift       # @Observable per-file state
        │   └── Pipeline.swift       # batch orchestrator
        ├── Engine/
        │   ├── Subprocess.swift     # shared Process helper
        │   ├── ExifTool.swift       # exiftool wrapper
        │   ├── DngLab.swift         # dnglab wrapper
        │   ├── AdobeDngConverter.swift  # Adobe DNG Converter wrapper
        │   ├── ToolLocator.swift    # discover installed converters
        │   └── Thumbnail.swift      # QuickLook-backed thumbnails
        ├── Views/
        │   ├── FileRow.swift
        │   ├── DropZone.swift
        │   ├── SettingsView.swift
        │   └── ToolSetupSheet.swift # first-launch tool picker
        └── Assets.xcassets
```

**Target:** macOS 14 (Sonoma) — modern SwiftUI (`@Observable`, `.dropDestination`, `.inspector`). Tested machine runs macOS 26.

**Size target:** ~600 LOC Swift total. The Windows app is 3,300 LOC; the reduction comes from dropping the custom title bar, Material Design palette, manual theme management, animations, and CustomMessageBox — all native to macOS.

**Architectural principles:**

- **No God object.** Windows' `MainWindow.xaml.cs` was 1,736 LOC. Mac modules are each <150 LOC with single responsibilities.
- **Engine has no SwiftUI imports.** `Engine/` and `Models/` could theoretically run from a CLI; SwiftUI lives only in `Views/` + `ContentView` + `FujifyApp`. Easier to test, easier to swap UI later.
- **Native settings.** `@AppStorage` over `UserDefaults`. Replaces Windows' `Properties.Settings`.

## UI design — Mac-native

**Inspirations** (all do drag-drop-batch-process workflows):

| App | Borrowed pattern |
|---|---|
| ImageOptim | Whole-window drop zone, table with per-file progress, idle = empty state hint |
| Permute | Bottom action bar, file-row status icons |
| Photos.app | Optional right-side Inspector (⌘I), automatic dark mode |
| HandBrake | Queue-style mental model |
| Transmit / Finder | NSToolbar + system materials + SF Symbols |

### Main window — populated state

```
┌──────────────────────────────────────────────────────────────┐
│ ●●●  Fujify   [+ Add]  [📁 ~/Out ▾]      [Process 4 files ▶]│
├──────────────────────────────────────────────────────────────┤
│  ⊟ Thumbnail │ Filename          │ Camera     │ Status      │
│  [thumb]       L5A00463.dng        SONY ⍺7 V    ✓ Done       │
│  [thumb]       L5A00464.dng        SONY ⍺7 V    ⟳ Processing │
│  [thumb]       L5A00465.dng        SONY ⍺7 V    ◦ Pending    │
├──────────────────────────────────────────────────────────────┤
│  ▓▓▓▓▓▓▓▓▓▓▓░░░░  3 of 12 · 25 s remaining                  │
└──────────────────────────────────────────────────────────────┘
```

### Main window — empty state

```
┌──────────────────────────────────────────────────────────────┐
│ ●●●  Fujify   [+ Add]  [📁 In place ▾]      [Process ▶]      │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│                          ┌──────────┐                        │
│                          │   📷     │   ← SF Symbol          │
│                          └──────────┘                        │
│              Drop RAW files or folders here                  │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### UI specifics

- **NSToolbar** via `.toolbar { ToolbarItemGroup(placement: .principal) }`. Looks identical to Finder/Mail.
- **Output folder** is a `Menu` button (Finder path-bar style) — not a textfield + button.
- **Table** with sortable columns (`Table` SwiftUI primitive): thumbnail (48pt), filename, camera, status.
- **Drag/drop** covers the whole window via `.dropDestination(for: URL.self)`.
- **SF Symbols throughout**: `plus`, `folder`, `play.fill`, `checkmark.circle.fill`, `arrow.triangle.2.circlepath`, `exclamationmark.triangle.fill`. No PNG icons except the app icon.
- **Semantic colors only**: `.primary`, `.secondary`, `.accentColor`. Dark mode follows system.
- **Inspector (⌘I)** — `.inspector` modifier, toggled by toolbar `info.circle`. Shows full exiftool dump of selected file. Closed by default.
- **Settings (⌘,)** — native `.sheet`. Contains converter picker + embed-raw toggle (see addendum below).
- **Row context menu** — Show in Finder, Open with…, Remove from list.
- **No custom animations.** Default SwiftUI list transitions only.
- **No theme toggle.** macOS handles it system-wide.

**Type system**: SF Pro everywhere. `.body` filenames, `.callout` camera names (secondary), `.caption` status text. Default table row height (24pt).

**Accent color**: pinned in `Assets.xcassets` to a Fuji-evoking green that adapts to dark mode (light: `#4CAF50`, dark: `#34A853` or similar — final shade TBD in implementation).

## Engine layer

Four wrappers + one shared helper. No SwiftUI imports.

### Subprocess helper

```swift
struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum SubprocessError: Error {
    case toolNotFound(URL)
    case nonZeroExit(code: Int32, stderr: String)
}

func run(_ tool: URL, _ args: [String]) async throws -> ProcessResult
```

- Reads pipes via `FileHandle.bytes` async sequences. Prevents the "pipe fills up, child blocks forever" pitfall.
- Throws `toolNotFound` if the binary URL doesn't exist.
- Doesn't enforce zero-exit — callers decide what stderr/exit codes mean.

### ExifTool API

```swift
enum ExifTool {
    static func readMakeModel(_ url: URL) async throws -> (make: String, model: String)
    static func injectFujiMetadata(dng: URL) async throws
    static func readAllMetadata(_ url: URL) async throws -> [String: String]
}
```

`injectFujiMetadata` uses the same 7 args as `fujify.py`:

```
-CameraProfilesMake=FUJIFILM
-CameraProfilesModel=X-T5
-CameraProfilesUniqueCameraModel=Fujifilm X-T5
-CameraProfilesCameraRawProfile=True
-UniqueCameraModel=Fujifilm X-T5
-overwrite_original
-m
```

The `-m` flag (ignore minor errors) is non-negotiable — exiftool refuses to write some DNGs without it (real failure mode hit during CLI testing).

### DngLab API

```swift
enum DngLab {
    static func convert(src: URL, dst: URL, embedRaw: Bool) async throws
}
```

Returns when conversion completes, throws otherwise. The wrapper parses stderr for `Unknown camera, model 'XXX'` and throws `.unsupportedCamera(model)` — the rest is generic failure.

### Adobe DNG Converter API

```swift
enum AdobeDngConverter {
    static let binaryPath = URL(fileURLWithPath:
        "/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter")

    static func convert(src: URL, dst: URL, embedRaw: Bool) async throws
}
```

Invokes the binary directly (not via `open -a`). Args used: `-c` (compressed), `-fl` (fast load), `-p2` (full-size JPEG preview), `-d <outDir>` (output directory), `-e` (embed original, only when `embedRaw == true`). Note: Adobe's tool always writes to a directory + auto-names the output file, so the wrapper handles file renaming after conversion to match the requested `dst` URL.

### Thumbnail (replaces Windows' `simple_dcraw`)

```swift
enum Thumbnail {
    static func generate(for url: URL, size: CGSize) async -> NSImage?
}
```

Uses `QLThumbnailGenerator` — built into macOS, already knows how to read RAW previews for every camera macOS supports. No libraw dependency, no bundled binaries.

### Tool discovery

```swift
@Observable @MainActor
final class ToolLocator {
    var exiftool: URL?              // /opt/homebrew/bin/exiftool etc.
    var dnglab: URL?
    var adobeDngConverter: URL?
    var preferredConverter: Converter = .auto   // from @AppStorage

    func probe()
    var activeConverter: Converter? { ... }     // resolved by preference + availability
}
```

Probes on launch — checks `/opt/homebrew/bin/`, `/usr/local/bin/`, `/usr/bin/` for `exiftool`/`dnglab`, plus the fixed `/Applications/...` path for Adobe DNG Converter. Cached results re-validated on subsequent launches. SwiftUI apps don't inherit shell PATH, so absolute paths matter.

## State & concurrency

### FileItem

```swift
@Observable @MainActor
final class FileItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var status: Status = .pending
    var make: String = ""
    var model: String = ""
    var thumbnail: NSImage?

    enum Status: Equatable {
        case pending
        case processing
        case done
        case error(String)
        case skipped(reason: String)   // e.g., unsupported camera
    }
}
```

`.skipped` is split from `.error` so the UI can show a more helpful icon/message for the A7 V case (the real pain point during CLI testing).

### Pipeline

```swift
@Observable @MainActor
final class Pipeline {
    var files: [FileItem] = []
    var isProcessing = false
    var outputFolder: URL?
    var embedRaw: Bool = false
    var completedCount: Int { ... }

    private var currentTask: Task<Void, Never>?
    private var currentProcess: Process?

    func add(_ urls: [URL]) async        // recursive folder walk + de-dupe
    func process()                       // kicks off batch
    func cancel()                        // SIGTERM + Task.cancel()
}
```

**Threading**: everything is `@MainActor`. Heavy work happens inside `async` Engine calls which yield naturally — `Process` reads pipes off-main automatically. State mutations all run on main, so SwiftUI re-renders are race-free by construction.

### Batch loop

```swift
for file in files where file.status == .pending {
    if Task.isCancelled { break }
    file.status = .processing
    do {
        let dng = try await prepareDng(for: file)
        try await ExifTool.injectFujiMetadata(dng: dng)
        file.status = .done
    } catch is CancellationError {
        file.status = .pending
        break
    } catch ToolError.unsupportedCamera(let model) {
        file.status = .skipped(reason: "Unsupported camera: \(model)")
    } catch {
        file.status = .error(error.localizedDescription)
    }
}
```

**Serial, not parallel.** dnglab is CPU-heavy, RAWs are RAM-heavy, parallel batches would thrash. Easy v2 add via `TaskGroup` once benchmarked.

**Cancellation**: `cancel()` calls `currentTask?.cancel()` (flips `Task.isCancelled`) and `currentProcess?.terminate()` (SIGTERM to subprocess). Process exits, `await` throws, caught, current file marked `.pending` for re-run.

**Persistence**: `@AppStorage("embedRaw")`, `@AppStorage("preferredConverter")`, `@AppStorage("lastOutputFolder")`.

## Error handling & edge cases

### 1. Missing tools — gates the app

On launch, `ToolLocator.probe()` runs. If `exiftool` not found, OR no converter available AND user hasn't explicitly chosen "DNG-only mode", show the **Tool Setup Sheet** (see next section). exiftool is non-optional; everything else is configurable.

### 2. Unsupported camera (the A7 V scenario)

`DngLab.convert` parses `Unknown camera, model 'XXX'` from stderr and throws `.unsupportedCamera(model)`. Pipeline catches → file becomes `.skipped` with a message that points to the escape hatches:

> *Unsupported camera: ILCE-7M5*
> *Try Adobe DNG Converter for newer cameras, or pre-convert with Lightroom Classic (Library → Convert Photo to DNG).*

Batch continues with remaining files. Doesn't abort the run.

### 3. App quit during processing

`applicationWillTerminate` calls `pipeline.cancel()`. SIGTERM to subprocess. No zombie processes. Closing the window (⌘W) does NOT cancel — only ⌘Q does, matching Mail/Finder convention.

### 4. Output folder problems

Writability checked on selection via `FileManager.isWritableFile`. Per-file: if the output already exists, overwrite silently (matches Windows behavior). Write failure → `.error("Permission denied")`, batch continues.

### 5. File disappearance

`FileManager.fileExists` check before processing each file. Missing → `.error("File no longer exists")`, skip. Prevents cascading dnglab failures from a moved folder.

### 6. Unsupported drop types

Filter on add against the supported-extensions set (same list as `fujify.py`). Unsupported files don't enter the list — inline note appears below the table: *"Ignored 3 unsupported files"*.

### 7. Sandboxing

**Off for v1.** Mac App Sandbox requires child-process entitlements that don't cleanly allow `/opt/homebrew/bin/dnglab` or `/Applications/Adobe DNG Converter.app/...`. Personal-use scope makes this fine; would matter only for Mac App Store distribution.

### 8. Idempotency

Running fujify on a DNG that's already been fujified just re-writes the same exiftool tags — no harm. User can drop the same folder twice without breaking anything.

## Tool setup sheet (first launch + Settings → Re-check)

Three-way choice, presented when no converter is configured:

```
┌──────────────────────────────────────────────────────────┐
│  Choose a RAW converter                                   │
│                                                           │
│  Fujify needs to convert RAW → DNG before applying       │
│  Fuji film simulations. Pick whichever works for you:    │
│                                                           │
│  ⦿  Adobe DNG Converter  (recommended)                   │
│     Best camera support, including newer bodies (A7 V).  │
│     ~700 MB free download from Adobe.                    │
│     [Download from Adobe]   [Re-check]                   │
│                                                           │
│  ○  dnglab  (lightweight)                                │
│     Open-source, ~12 MB. Doesn't yet support every       │
│     newer body — Sony A7 V isn't covered.                │
│     [brew install dnglab]   [Re-check]                   │
│                                                           │
│  ○  I'll pre-convert with Lightroom Classic              │
│     Use LRc's Library → Convert Photo to DNG, then drop  │
│     the DNGs into Fujify. No extra install needed.       │
│     [Continue in DNG-only mode]                          │
└──────────────────────────────────────────────────────────┘
```

**DNG-only mode** is a first-class state:
- Pipeline skips conversion entirely (`prepareDng` returns input URL unchanged when source is `.dng`).
- Drag-drop filter: only `.dng` files enter the list. Non-DNG drops show an inline note.
- Empty state hint changes to: *"Drop DNG files here"*.

**Settings sheet (⌘,)** exposes the same picker plus the embed-raw toggle:

```
RAW converter:  ◉ Auto  ○ Adobe DNG Converter  ○ dnglab  ○ DNG-only mode
Embed original RAW in DNG:  [ ]   (only relevant when a converter is active)
```

**Auto** prefers Adobe DNG Converter (better coverage) then falls back to dnglab. If neither installed, Auto reverts to DNG-only mode.

## Out of scope for v1

- Codesigning / notarization / distribution (Mac App Store, Homebrew cask, DMG)
- Parallel batch processing (TaskGroup) — serial works, easy v2 add
- Custom Fuji simulation selection (always X-T5, matches Windows default)
- Watching folders for new files
- Bundled Adobe DNG Converter or dnglab — both must be user-installed (license / size reasons)
- Lightroom plugin / direct catalog integration
- Linux build

## Implementation order

1. Create Xcode project, set deployment target macOS 14, configure entitlements (sandbox off).
2. `Engine/Subprocess.swift` — generic Process wrapper, unit-testable.
3. `Engine/ExifTool.swift` — readMakeModel + injectFujiMetadata. End-to-end test against a real DNG before any UI exists.
4. `Engine/ToolLocator.swift` — probes for all three tools, populates `@Observable` state.
5. `Models/FileItem.swift` + `Models/Pipeline.swift` — state machine, batch loop, cancellation. Test with hard-coded URLs.
6. Minimal `ContentView` — Table of files, Process button. Wire to Pipeline. First end-to-end batch test.
7. Drag/drop, output folder picker, status icons, progress bar.
8. `Engine/DngLab.swift` + `Engine/AdobeDngConverter.swift` — both converter backends.
9. `Views/ToolSetupSheet.swift` — first-launch flow.
10. `Views/SettingsView.swift` — converter picker + embed-raw toggle.
11. `Engine/Thumbnail.swift` + thumbnail column in the table.
12. Inspector (⌘I) — exiftool dump for selected file.
13. Polish: row context menu, app icon, empty state graphic.
