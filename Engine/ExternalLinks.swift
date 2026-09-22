import Foundation

/// Every URL the app sends people to, in one place.
///
/// Adobe reorganises these pages periodically. When one moves, a single
/// edit here fixes every link instead of leaving one of two identical
/// "Adobe's supported cameras list" buttons pointing at a 404.
enum ExternalLinks {
    /// The camera names Camera Raw knows, which is the set Lightroom matches
    /// against — the spelling a user must copy exactly when adding a camera.
    static let adobeCameraList = URL(
        string: "https://helpx.adobe.com/camera-raw/kb/camera-raw-plug-supported-cameras.html"
    )!

    static let adobeDngConverter = URL(
        string: "https://helpx.adobe.com/camera-raw/using/adobe-dng-converter.html"
    )!

    static let dnglab = URL(string: "https://github.com/dnglab/dnglab")!
}
