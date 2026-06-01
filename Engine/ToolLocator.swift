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
        case .auto: return "Auto"
        case .adobe: return "Adobe DNG Converter"
        case .dnglab: return "dnglab"
        case .dngOnly: return "DNG-only mode"
        }
    }
}

/// The converter Pipeline should actually use, after resolving the user's
/// preference against what is installed on disk.
enum ResolvedConverter: Equatable {
    case adobe(URL)
    case dnglab(URL)
    case dngOnly

    var displayName: String {
        switch self {
        case .adobe: return "Adobe DNG Converter"
        case .dnglab: return "dnglab"
        case .dngOnly: return "DNG-only (pre-convert manually)"
        }
    }
}

/// Discovers exiftool and the available DNG converters at known install
/// paths. SwiftUI apps don't inherit the shell PATH, so probing known
/// absolute locations is required.
@Observable @MainActor
final class ToolLocator {
    private(set) var exiftool: URL?
    private(set) var dnglab: URL?
    private(set) var adobeDngConverter: URL?

    var preferredConverter: ConverterPreference {
        didSet {
            UserDefaults.standard.set(
                preferredConverter.rawValue,
                forKey: Self.preferenceKey
            )
        }
    }

    private static let preferenceKey = "preferredConverter"

    private static let exiftoolPaths = [
        "/opt/homebrew/bin/exiftool",
        "/usr/local/bin/exiftool",
        "/usr/bin/exiftool",
    ]

    private static let dnglabPaths = [
        "/opt/homebrew/bin/dnglab",
        "/usr/local/bin/dnglab",
        "/usr/bin/dnglab",
    ]

    private static let adobeDngConverterPath =
        "/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter"

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.preferenceKey)
        self.preferredConverter = saved.flatMap(ConverterPreference.init(rawValue:)) ?? .auto
        probe()
    }

    /// Re-scans disk for installed tools. Called on init and from the
    /// "Re-check" button in the tool-setup sheet after the user installs
    /// something.
    func probe() {
        exiftool = Self.firstExisting(Self.exiftoolPaths)
        dnglab = Self.firstExisting(Self.dnglabPaths)
        adobeDngConverter = Self.firstExisting([Self.adobeDngConverterPath])
    }

    /// exiftool is non-optional — without it the app can't do anything.
    var hasMinimumTools: Bool { exiftool != nil }

    /// Resolves the active converter from the user's preference and what's
    /// actually installed. An explicit preference (Adobe or dnglab) falls
    /// back to DNG-only mode if the chosen tool isn't installed, rather than
    /// silently switching backends — making the user's choice meaningful.
    var activeConverter: ResolvedConverter {
        switch preferredConverter {
        case .auto:
            if let url = adobeDngConverter { return .adobe(url) }
            if let url = dnglab { return .dnglab(url) }
            return .dngOnly
        case .adobe:
            if let url = adobeDngConverter { return .adobe(url) }
            return .dngOnly
        case .dnglab:
            if let url = dnglab { return .dnglab(url) }
            return .dngOnly
        case .dngOnly:
            return .dngOnly
        }
    }

    private static func firstExisting(_ paths: [String]) -> URL? {
        for path in paths where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
