import Testing

@testable import Fujify

/// Locks in docs/PIPELINE-CONTRACT.md §5.1.
///
/// The Windows port reads its accepted-extension list from the same clause,
/// so a change here that isn't a deliberate contract change will silently
/// make the two apps disagree about which files they will even look at.
@Suite("Accepted input extensions")
@MainActor
struct SupportedExtensionsTests {

    /// Transcribed from the contract, not from `Pipeline`, so that editing
    /// one without the other fails.
    static let fromContract: Set<String> = [
        "dng", "cr3", "cr2", "crw", "erf", "raf", "3fr", "kdc", "dcs", "dcr",
        "iiq", "mos", "mef", "mrw", "nef", "nrw", "orf", "rw2", "pef", "srw",
        "arw", "srf", "sr2", "ari",
    ]

    @Test("the code accepts exactly what the contract lists")
    func matchesContract() {
        #expect(Pipeline.supportedExtensions == Self.fromContract)
        #expect(Pipeline.supportedExtensions.count == 24)
    }

    @Test("every entry is lower-cased, since lookups lower-case the input")
    func allLowercase() {
        for ext in Pipeline.supportedExtensions {
            #expect(ext == ext.lowercased(), "\(ext) would never match")
        }
    }

    @Test(
        "the formats the fixture set covers are accepted",
        arguments: ["arw", "cr3", "nef", "raf", "dng"]
    )
    func fixtureFormatsAccepted(_ ext: String) {
        #expect(Pipeline.supportedExtensions.contains(ext))
    }

    @Test(
        "formats that are images but not camera RAW are rejected",
        arguments: ["jpg", "jpeg", "png", "tif", "tiff", "heic", "psd", "mov"]
    )
    func nonRawRejected(_ ext: String) {
        #expect(!Pipeline.supportedExtensions.contains(ext))
    }
}
