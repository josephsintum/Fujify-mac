import Foundation

/// The camera identity Fujify writes into a DNG so Lightroom offers that
/// body's film simulation profiles.
///
/// See docs/PIPELINE-CONTRACT.md §2. The three strings are the whole trick:
/// Lightroom gates camera-matching profiles on them, so a DNG claiming to be
/// a Fujifilm X-T5 is offered the Fujifilm simulations whatever body actually
/// took the frame.
struct TargetCamera: Codable, Identifiable, Hashable, Sendable {
    /// Written to `CameraProfilesMake`.
    let make: String
    /// Written to `CameraProfilesModel`.
    let model: String
    /// Written to both `CameraProfilesUniqueCameraModel` and
    /// `UniqueCameraModel`.
    ///
    /// Stored rather than derived. For every built-in target it happens to be
    /// `"Fujifilm " + model`, but that is only *verified* for the X-T5 — see
    /// `derivedUniqueCameraModel(for:)`.
    let uniqueCameraModel: String
    /// One line in the picker saying what this body unlocks. Empty for
    /// user-added cameras, where we have nothing truthful to say.
    let note: String
    /// Built-ins ship with the app and cannot be removed.
    let isBuiltIn: Bool

    var id: String { "\(make)|\(model)" }

    /// "Fujifilm X-T5" — what the picker and the toolbar show.
    var displayName: String {
        make.caseInsensitiveCompare("FUJIFILM") == .orderedSame
            ? "Fujifilm \(model)" : "\(make) \(model)"
    }

    init(
        make: String,
        model: String,
        uniqueCameraModel: String? = nil,
        note: String = "",
        isBuiltIn: Bool = false
    ) {
        let trimmedMake = make.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.make = trimmedMake
        self.model = trimmedModel
        self.uniqueCameraModel =
            uniqueCameraModel ?? Self.derivedUniqueCameraModel(for: trimmedModel)
        self.note = note
        self.isBuiltIn = isBuiltIn
    }

    /// How `uniqueCameraModel` is guessed for a camera the user typed in.
    ///
    /// This matches what Adobe writes for the X-T5, which is the only case
    /// confirmed against a real file. If a body turns out to use a different
    /// string, that body gets an explicit `uniqueCameraModel` and this stays
    /// as the fallback.
    static func derivedUniqueCameraModel(for model: String) -> String {
        "Fujifilm \(model)"
    }
}

// MARK: - Built-ins

extension TargetCamera {
    /// The default target, and the fallback whenever a selection disappears.
    ///
    /// Verified end-to-end in Lightroom.
    static let xT5 = TargetCamera(
        make: "FUJIFILM",
        model: "X-T5",
        uniqueCameraModel: "Fujifilm X-T5",
        note: "Nostalgic Neg., Classic Neg., Eterna Bleach Bypass and the classics",
        isBuiltIn: true
    )

    /// Verified end-to-end in Lightroom on 2026-09-21: a Sony A7 V ARW
    /// tagged with this target offers Reala Ace v2 in the profile browser.
    static let x100VI = TargetCamera(
        make: "FUJIFILM",
        model: "X100VI",
        uniqueCameraModel: "Fujifilm X100VI",
        note: "Adds Reala Ace",
        isBuiltIn: true
    )

    /// Two entries, deliberately not a catalogue: the X-T5 for the classic
    /// simulations and the X100VI for Reala Ace. Anything else a user wants
    /// they add themselves, which also means we never ship a model string we
    /// haven't checked.
    static let builtIns: [TargetCamera] = [xT5, x100VI]
}

// MARK: - Comparing against a file

/// The camera-identity tags read back from a file, used by the already-tagged
/// skip (contract §9) and by the Inspector's tag highlighting.
struct CameraTags: Equatable, Sendable {
    var make: String = ""
    var model: String = ""
    var uniqueCameraModel: String = ""
    var profilesMake: String = ""
    var profilesModel: String = ""
    var profilesUniqueCameraModel: String = ""

    /// True when this file already claims to be `target`.
    ///
    /// Compares against *this* target rather than "is it Fujifilm at all", so
    /// re-tagging an X-T5 batch as X100VI to pick up Reala Ace still runs.
    /// That is the reason the target picker exists.
    func alreadyTagged(as target: TargetCamera) -> Bool {
        profilesMake == target.make
            && profilesModel == target.model
            && profilesUniqueCameraModel == target.uniqueCameraModel
    }

    /// True when some other target's tags are present — the file has been
    /// through Fujify before, but for a different camera.
    var hasAnyFujifyTags: Bool {
        !profilesMake.isEmpty && !profilesModel.isEmpty
    }
}
