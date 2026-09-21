import Foundation
import Observation

/// The list of target cameras and which one new batches use.
///
/// Built-ins come from `TargetCamera.builtIns`; anything the user adds is
/// persisted as JSON in UserDefaults. See docs/PIPELINE-CONTRACT.md §2.
@Observable @MainActor
final class CameraStore {
    private(set) var userCameras: [TargetCamera] = []

    /// The target new batches are processed with. Persisted by `id`, so a
    /// user camera that is later removed falls back to the X-T5 rather than
    /// leaving the app pointing at a camera that no longer exists.
    var selectedTarget: TargetCamera {
        didSet { defaults.set(selectedTarget.id, forKey: Self.selectedKey) }
    }

    /// Built-ins first, then user-added, which is the order the picker shows
    /// them in with a separator between the groups.
    var allCameras: [TargetCamera] { TargetCamera.builtIns + userCameras }

    private let defaults: UserDefaults

    private static let userCamerasKey = "userCameras"
    private static let selectedKey = "targetCamera"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let stored: [TargetCamera] =
            defaults.data(forKey: Self.userCamerasKey)
            .flatMap { try? JSONDecoder().decode([TargetCamera].self, from: $0) } ?? []
        // Anything persisted is user-added by definition; don't trust a
        // decoded isBuiltIn flag to decide what can be removed.
        let user = stored.filter { !$0.isBuiltIn }
        self.userCameras = user

        let selectedID = defaults.string(forKey: Self.selectedKey)
        self.selectedTarget =
            (TargetCamera.builtIns + user).first { $0.id == selectedID } ?? .xT5
    }

    // MARK: Editing

    enum AddResult: Equatable {
        case added
        case duplicate(existing: TargetCamera)
        case invalid(reason: String)
    }

    /// Adds a user camera and selects it.
    ///
    /// Fujify cannot check that Lightroom knows the name — only Lightroom can
    /// — so the only validation here is that the fields are non-empty and not
    /// a duplicate. The UI says as much next to the field.
    @discardableResult
    func add(make: String, model: String) -> AddResult {
        let camera = TargetCamera(make: make, model: model)

        guard !camera.make.isEmpty else {
            return .invalid(reason: "Enter a make, such as FUJIFILM.")
        }
        guard !camera.model.isEmpty else {
            return .invalid(reason: "Enter a model, such as X100VI.")
        }
        if let existing = allCameras.first(where: { $0.id == camera.id }) {
            return .duplicate(existing: existing)
        }

        userCameras.append(camera)
        persistUserCameras()
        selectedTarget = camera
        return .added
    }

    /// Removes a user camera. Built-ins are refused.
    @discardableResult
    func remove(_ camera: TargetCamera) -> Bool {
        guard !camera.isBuiltIn,
            let index = userCameras.firstIndex(where: { $0.id == camera.id })
        else { return false }

        userCameras.remove(at: index)
        persistUserCameras()
        if selectedTarget.id == camera.id {
            selectedTarget = .xT5
        }
        return true
    }

    private func persistUserCameras() {
        guard let data = try? JSONEncoder().encode(userCameras) else { return }
        defaults.set(data, forKey: Self.userCamerasKey)
    }
}
