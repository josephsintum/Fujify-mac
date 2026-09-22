import Foundation
import Testing

@testable import Fujify

/// Locks in docs/PIPELINE-CONTRACT.md §2 and §9.
@Suite("Target cameras")
struct TargetCameraTests {

    @Test("the built-in list is the two the contract names, X-T5 first")
    func builtIns() {
        // allSatisfy is rethrows, and the #expect macro decomposes the call,
        // so it has to be evaluated before the assertion.
        let everyOneIsBuiltIn = TargetCamera.builtIns.allSatisfy(\.isBuiltIn)

        #expect(TargetCamera.builtIns.count == 2)
        #expect(TargetCamera.builtIns.first == .xT5)
        #expect(everyOneIsBuiltIn)
        #expect(TargetCamera.builtIns.map(\.model) == ["X-T5", "X100VI"])
    }

    @Test("the X-T5's tags are exactly what the contract says to write")
    func xT5Tags() {
        // The only target verified end-to-end in Lightroom. If this changes,
        // every DNG the app has ever written stops matching.
        #expect(TargetCamera.xT5.make == "FUJIFILM")
        #expect(TargetCamera.xT5.model == "X-T5")
        #expect(TargetCamera.xT5.uniqueCameraModel == "Fujifilm X-T5")
    }

    @Test("a user-added camera gets a derived unique model")
    func derivedUniqueModel() {
        let camera = TargetCamera(make: "FUJIFILM", model: "X-M5")
        #expect(camera.uniqueCameraModel == "Fujifilm X-M5")
    }

    @Test("whitespace around typed input is trimmed, so IDs stay comparable")
    func trimsInput() {
        let camera = TargetCamera(make: "  FUJIFILM \n", model: " X-M5 ")
        #expect(camera.make == "FUJIFILM")
        #expect(camera.model == "X-M5")
        #expect(camera.id == "FUJIFILM|X-M5")
    }

    @Test("display name reads as a person would say it")
    func displayName() {
        #expect(TargetCamera.xT5.displayName == "Fujifilm X-T5")
        #expect(TargetCamera.x100VI.displayName == "Fujifilm X100VI")
    }

    // MARK: The skip rule (§9)

    @Test("a file tagged as the target is recognised")
    func alreadyTaggedMatches() {
        let tags = CameraTags(
            make: "SONY", model: "ILCE-7M5", uniqueCameraModel: "Fujifilm X-T5",
            profilesMake: "FUJIFILM", profilesModel: "X-T5",
            profilesUniqueCameraModel: "Fujifilm X-T5")

        #expect(tags.alreadyTagged(as: .xT5))
    }

    /// The reason the target picker exists. A batch tagged for the X-T5 must
    /// still be re-taggable for the X100VI to pick up Reala Ace; if this
    /// returned true the feature would silently do nothing.
    @Test("a file tagged as a DIFFERENT target is not skipped")
    func differentTargetIsNotSkipped() {
        let taggedAsXT5 = CameraTags(
            profilesMake: "FUJIFILM", profilesModel: "X-T5",
            profilesUniqueCameraModel: "Fujifilm X-T5")

        #expect(taggedAsXT5.alreadyTagged(as: .xT5))
        #expect(!taggedAsXT5.alreadyTagged(as: .x100VI))
    }

    @Test("an untouched file is never considered tagged")
    func untouchedFile() {
        let tags = CameraTags(
            make: "NIKON CORPORATION", model: "NIKON D1H",
            uniqueCameraModel: "Nikon D1H")

        #expect(!tags.alreadyTagged(as: .xT5))
        #expect(!tags.hasAnyFujifyTags)
    }

    @Test("a partial match does not count as tagged")
    func partialMatch() {
        // Make and model right, unique model left over from another target:
        // Lightroom would see a mixed identity, so this needs rewriting.
        let tags = CameraTags(
            profilesMake: "FUJIFILM", profilesModel: "X-T5",
            profilesUniqueCameraModel: "Fujifilm X100VI")

        #expect(!tags.alreadyTagged(as: .xT5))
    }
}

@Suite("Camera store")
@MainActor
struct CameraStoreTests {

    /// A throwaway UserDefaults per test, so tests can run in parallel
    /// without fighting over the real one.
    private static func isolatedDefaults() -> UserDefaults {
        let suite = "fujify.tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test("a fresh store offers the built-ins and selects the X-T5")
    func freshStore() {
        let store = CameraStore(defaults: Self.isolatedDefaults())

        #expect(store.allCameras.count == 2)
        #expect(store.selectedTarget == .xT5)
        #expect(store.userCameras.isEmpty)
    }

    @Test("adding a camera selects it and puts it after the built-ins")
    func addSelects() {
        let store = CameraStore(defaults: Self.isolatedDefaults())

        #expect(store.add(make: "FUJIFILM", model: "X-M5") == .added)
        #expect(store.selectedTarget.model == "X-M5")
        #expect(store.allCameras.last?.model == "X-M5")
    }

    @Test("adding the same camera twice is refused rather than duplicated")
    func addDuplicate() {
        let store = CameraStore(defaults: Self.isolatedDefaults())
        store.add(make: "FUJIFILM", model: "X-M5")

        #expect(store.add(make: "FUJIFILM", model: "X-M5") == .duplicate(existing:
            TargetCamera(make: "FUJIFILM", model: "X-M5")))
        #expect(store.userCameras.count == 1)
    }

    @Test("adding a built-in again is refused")
    func addExistingBuiltIn() {
        let store = CameraStore(defaults: Self.isolatedDefaults())

        if case .added = store.add(make: "FUJIFILM", model: "X-T5") {
            Issue.record("X-T5 is built in and should not be addable again")
        }
        #expect(store.userCameras.isEmpty)
    }

    @Test("blank fields are refused with something to show the user")
    func addBlank() {
        let store = CameraStore(defaults: Self.isolatedDefaults())

        guard case .invalid(let makeReason) = store.add(make: "  ", model: "X-M5") else {
            Issue.record("a blank make should be refused")
            return
        }
        #expect(!makeReason.isEmpty)

        guard case .invalid = store.add(make: "FUJIFILM", model: "") else {
            Issue.record("a blank model should be refused")
            return
        }
    }

    @Test("built-in cameras cannot be removed")
    func cannotRemoveBuiltIn() {
        let store = CameraStore(defaults: Self.isolatedDefaults())

        #expect(store.remove(.xT5) == false)
        #expect(store.allCameras.count == 2)
    }

    @Test("removing the selected camera falls back to the X-T5")
    func removeSelectedFallsBack() throws {
        let store = CameraStore(defaults: Self.isolatedDefaults())
        store.add(make: "FUJIFILM", model: "X-M5")
        let added = try #require(store.userCameras.first)

        #expect(store.remove(added))
        #expect(store.selectedTarget == .xT5)
        #expect(store.userCameras.isEmpty)
    }

    @Test("user cameras and the selection survive a relaunch")
    func persistence() {
        let defaults = Self.isolatedDefaults()
        let first = CameraStore(defaults: defaults)
        first.add(make: "FUJIFILM", model: "X-M5")

        let second = CameraStore(defaults: defaults)
        #expect(second.userCameras.map(\.model) == ["X-M5"])
        #expect(second.selectedTarget.model == "X-M5")
    }

    @Test("a selection pointing at a camera that no longer exists falls back")
    func staleSelection() {
        let defaults = Self.isolatedDefaults()
        defaults.set("FUJIFILM|GONE", forKey: "targetCamera")

        let store = CameraStore(defaults: defaults)
        #expect(store.selectedTarget == .xT5)
    }
}
