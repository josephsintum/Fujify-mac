import Foundation

extension URL {
    /// The path as a person should read it: `~/Pictures/Fujified`.
    ///
    /// Five places showed a folder or file path to the user and each did the
    /// `NSString` bridge itself.
    var displayPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
