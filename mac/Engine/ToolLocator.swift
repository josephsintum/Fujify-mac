import Foundation
import Observation

/// User's chosen RAW converter. Persisted to UserDefaults.
enum ConverterPreference: String, CaseIterable, Codable, Sendable {
    case auto
    case adobe
    case dnglab
    case dngOnly = "dng-only"

    var displayName: String {
        switch self {
        case .auto: return "Automatic"
        case .adobe: return "Adobe DNG Converter"
        case .dnglab: return "dnglab"
        case .dngOnly: return "DNG only"
        }
    }
}

/// The converter Pipeline should actually use, after resolving the user's
/// preference against what is installed on disk.
enum ResolvedConverter: Equatable, Sendable {
    case adobe(URL)
    case dnglab(URL)
    case dngOnly

    var displayName: String {
        switch self {
        case .adobe: return "Adobe DNG Converter"
        case .dnglab: return "Built-in dnglab"
        case .dngOnly: return "DNG-only (pre-convert manually)"
        }
    }

    var toolName: ToolName? {
        switch self {
        case .adobe: return .adobeDngConverter
        case .dnglab: return .dnglab
        case .dngOnly: return nil
        }
    }
}

/// Where a tool came from, so Settings can say "Built in" rather than
/// printing a path nobody needs to see.
enum ToolSource: Equatable, Sendable {
    /// Shipped inside the app bundle. Nothing to install.
    case bundled
    /// Found on disk, usually via Homebrew. The path is worth showing.
    case installed(URL)

    var isBundled: Bool { self == .bundled }
}

/// A tool that was found and proved it runs here.
struct LocatedTool: Equatable, Sendable {
    let url: URL
    let version: String
    let source: ToolSource

    /// "13.59" or "13.59 · /opt/homebrew/bin/exiftool" for Settings.
    var summary: String {
        switch source {
        case .bundled: return version
        case .installed(let url): return "\(version) · \(url.path)"
        }
    }
}

/// Finds exiftool, dnglab and Adobe DNG Converter.
///
/// exiftool and dnglab ship inside the app bundle, so the common case needs
/// no install at all. A Homebrew copy is preferred when it is *newer*, which
/// lets a user pick up camera support ahead of the next Fujify release.
///
/// Every candidate is verified by actually running it and reading back a
/// version string. That is what catches the bundled arm64 dnglab on an Intel
/// Mac: it is present but cannot execute, so it is discarded and the app
/// falls back to Homebrew or to Adobe. See docs/PIPELINE-CONTRACT.md §4.
@Observable @MainActor
final class ToolLocator {
    private(set) var exiftool: LocatedTool?
    private(set) var dnglab: LocatedTool?
    private(set) var adobeDngConverter: LocatedTool?

    /// Defines the XMP-fujify namespace. Bundled beside exiftool.
    private(set) var exiftoolConfig: URL?

    /// True once the first probe has finished, so Settings can show a
    /// spinner rather than "Not installed" while it is still looking.
    private(set) var hasProbed = false

    var preferredConverter: ConverterPreference {
        didSet {
            UserDefaults.standard.set(
                preferredConverter.rawValue,
                forKey: Self.preferenceKey
            )
        }
    }

    private static let preferenceKey = "preferredConverter"

    /// The system Perl, which runs the bundled exiftool script. Present on
    /// every macOS install; Apple has shipped 5.34 since Sonoma.
    private static let systemPerl = URL(fileURLWithPath: "/usr/bin/perl")

    /// Homebrew and MacPorts locations, checked only to see whether the user
    /// has something newer than what we ship.
    private static let installedExiftoolPaths = [
        "/opt/homebrew/bin/exiftool",
        "/usr/local/bin/exiftool",
        "/usr/bin/exiftool",
    ]

    private static let installedDnglabPaths = [
        "/opt/homebrew/bin/dnglab",
        "/usr/local/bin/dnglab",
        "/usr/bin/dnglab",
    ]

    private static let adobeDngConverterPath =
        "/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter"

    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        let saved = UserDefaults.standard.string(forKey: Self.preferenceKey)
        self.preferredConverter = saved.flatMap(ConverterPreference.init(rawValue:)) ?? .auto
    }

    // MARK: Probing

    /// Re-scans for tools. Called on launch and from "Check Again" in
    /// Settings after the user installs Adobe DNG Converter.
    ///
    /// Runs each candidate to confirm it works, so this touches disk and
    /// spawns a few short-lived processes — hence async.
    func probe() async {
        exiftoolConfig = bundle.url(forResource: "exiftool-fujify", withExtension: "config")

        async let exif = Self.locateExiftool(bundle: bundle)
        async let lab = Self.locateDnglab(bundle: bundle)
        async let adobe = Self.locateAdobe()

        let (foundExif, foundLab, foundAdobe) = await (exif, lab, adobe)
        exiftool = foundExif
        dnglab = foundLab
        adobeDngConverter = foundAdobe
        hasProbed = true
    }

    /// exiftool bundled inside the app, preferred only if nothing newer is
    /// installed. Both are run to read their version, so a broken copy is
    /// never selected.
    private static func locateExiftool(bundle: Bundle) async -> LocatedTool? {
        guard FileManager.default.isExecutableFile(atPath: systemPerl.path) else {
            return nil
        }

        var candidates: [LocatedTool] = []

        // The exiftool distribution is copied in as a folder reference, so
        // the script sits at Resources/exiftool/exiftool with its lib/
        // alongside it — the layout the script expects to find itself in.
        if let script = bundle.resourceURL?.appendingPathComponent("exiftool/exiftool"),
            FileManager.default.fileExists(atPath: script.path),
            let version = await perlScriptVersion(script)
        {
            candidates.append(LocatedTool(url: script, version: version, source: .bundled))
        }

        if let path = firstExisting(installedExiftoolPaths) {
            // A Homebrew exiftool is a wrapper script with its own Perl lib
            // path baked in, so it is run directly rather than through our
            // Perl — the two are not interchangeable.
            if let version = await executableVersion(path, arguments: ["-ver"]) {
                candidates.append(
                    LocatedTool(url: path, version: version, source: .installed(path)))
            }
        }

        return preferringNewest(candidates)
    }

    private static func locateDnglab(bundle: Bundle) async -> LocatedTool? {
        var candidates: [LocatedTool] = []

        if let binary = bundle.url(forResource: "dnglab", withExtension: nil),
            let version = await dnglabVersion(binary)
        {
            candidates.append(LocatedTool(url: binary, version: version, source: .bundled))
        }

        if let path = firstExisting(installedDnglabPaths),
            let version = await dnglabVersion(path)
        {
            candidates.append(LocatedTool(url: path, version: version, source: .installed(path)))
        }

        return preferringNewest(candidates)
    }

    private static func locateAdobe() async -> LocatedTool? {
        guard let path = firstExisting([adobeDngConverterPath]) else { return nil }
        // Adobe's CLI has no --version flag; the app bundle's Info.plist does.
        let appBundle = path
            .deletingLastPathComponent()  // MacOS
            .deletingLastPathComponent()  // Contents
            .deletingLastPathComponent()  // .app
        let version =
            Bundle(url: appBundle)?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return LocatedTool(
            url: path,
            version: version ?? "installed",
            source: .installed(path)
        )
    }

    /// Picks the highest version among candidates, preferring the bundled
    /// copy on a tie so the app's behaviour stays predictable.
    private static func preferringNewest(_ candidates: [LocatedTool]) -> LocatedTool? {
        candidates.max { a, b in
            let order = a.version.compare(b.version, options: .numeric)
            if order == .orderedSame {
                return a.source.isBundled && !b.source.isBundled ? false : true
            }
            return order == .orderedAscending
        }
    }

    // MARK: Running candidates

    private static func perlScriptVersion(_ script: URL) async -> String? {
        await executableVersion(systemPerl, arguments: [script.path, "-ver"])
    }

    /// dnglab prints "dnglab 0.8.0"; we want just the number.
    private static func dnglabVersion(_ binary: URL) async -> String? {
        guard let raw = await executableVersion(binary, arguments: ["--version"]) else {
            return nil
        }
        return raw.split(separator: " ").last.map(String.init) ?? raw
    }

    /// Runs a tool purely to see whether it works here and what it reports.
    /// Any failure — missing, wrong architecture, not executable — is a nil,
    /// which is exactly the behaviour the Intel-Mac dnglab case needs.
    private static func executableVersion(
        _ tool: URL,
        arguments: [String]
    ) async -> String? {
        guard let result = try? await runSubprocess(tool, arguments),
            result.didSucceed
        else { return nil }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func firstExisting(_ paths: [String]) -> URL? {
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // MARK: Resolution

    /// exiftool is non-negotiable — without it nothing can be tagged. It is
    /// bundled, so this is only false if the app bundle is damaged or the
    /// system has no Perl.
    var hasMinimumTools: Bool { exiftool != nil }

    /// Builds the exiftool wrapper for the located copy.
    func makeExifTool() -> ExifTool? {
        guard let exiftool else { return nil }
        switch exiftool.source {
        case .bundled:
            return ExifTool(
                perl: Self.systemPerl, script: exiftool.url, configFile: exiftoolConfig)
        case .installed(let path):
            // A Homebrew exiftool runs itself; there is no separate script to
            // hand to Perl. Invoking it as its own interpreter works because
            // the file starts with a shebang.
            return ExifTool(perl: path, script: path, configFile: exiftoolConfig)
        }
    }

    /// Resolves the active converter from the user's preference and what is
    /// actually available. An explicit preference falls back to DNG-only
    /// rather than silently switching backends, so the user's choice stays
    /// meaningful. See docs/PIPELINE-CONTRACT.md §4.4.
    var activeConverter: ResolvedConverter {
        switch preferredConverter {
        case .auto:
            if let adobe = adobeDngConverter { return .adobe(adobe.url) }
            if let lab = dnglab { return .dnglab(lab.url) }
            return .dngOnly
        case .adobe:
            if let adobe = adobeDngConverter { return .adobe(adobe.url) }
            return .dngOnly
        case .dnglab:
            if let lab = dnglab { return .dnglab(lab.url) }
            return .dngOnly
        case .dngOnly:
            return .dngOnly
        }
    }
}
