import Testing

@testable import Fujify

/// Locks in docs/PIPELINE-CONTRACT.md §8.1.
///
/// Every string in here was captured from the real tool, not invented. That
/// matters: the obvious guess for a permissions failure is "permission
/// denied", and exiftool never says it. Getting this wrong doesn't crash
/// anything — the user just sees "unknown error" and loses the Choose Folder
/// button that would have fixed it, which is the kind of bug nobody reports.
@Suite("Failure classification")
struct FailureClassificationTests {

    // MARK: Real output, captured from the tools

    /// exiftool 13.59 writing to a file in a read-only directory.
    /// Note the complete absence of the word "permission".
    static let exiftoolReadOnly = """
        Error: Error creating file: rotest/ro.dng_exiftool_tmp - rotest/ro.dng
            0 image files updated
            1 files weren't updated due to errors
        """

    /// dnglab 0.8.0 converting into a read-only directory.
    static let dnglabReadOnly = "Error: I/O error: Permission denied (os error 13)"

    /// dnglab 0.8.0 on a Nikon D1H. Handled as a skip before classification
    /// ever runs, but asserted here so the two paths can't both claim it.
    static let dnglabUnknownCamera = """
        Error: Unsupported file: Error: Unknown camera, model 'NIKON D1H', \
        make: 'NIKON CORPORATION', mode: '12bit'
        """

    // MARK: Read-only output

    @Test("exiftool's read-only message is recognised despite saying nothing about permissions")
    func exiftoolReadOnlyIsReadOnly() {
        let failure = ProcessingFailure.classify(
            stderr: Self.exiftoolReadOnly, step: .writeTags, tool: .exiftool)

        #expect(failure.cause == .readOnlyOutput)
        #expect(failure.shortReason == "Output folder is read-only")
        #expect(failure.recovery.contains("The RAW file is untouched."))
    }

    @Test("dnglab's read-only message is recognised")
    func dnglabReadOnlyIsReadOnly() {
        let failure = ProcessingFailure.classify(
            stderr: Self.dnglabReadOnly, step: .convert, tool: .dnglab)

        #expect(failure.cause == .readOnlyOutput)
        #expect(failure.summary.contains("read-only"))
    }

    @Test(
        "other ways the platforms phrase a permissions problem",
        arguments: [
            "Error: Read-only file system",
            "error: Access is denied. (os error 5)",
            "Operation not permitted",
        ]
    )
    func otherPermissionPhrasings(_ stderr: String) {
        let failure = ProcessingFailure.classify(
            stderr: stderr, step: .convert, tool: .dnglab)
        #expect(failure.cause == .readOnlyOutput)
    }

    // MARK: Disk full

    @Test(
        "a full disk is told apart from a permissions problem",
        arguments: [
            "Error: No space left on device",
            "Error: I/O error: No space left on device (os error 28)",
            "Not enough space on the disk.",
        ]
    )
    func diskFull(_ stderr: String) {
        let failure = ProcessingFailure.classify(
            stderr: stderr, step: .convert, tool: .dnglab)
        #expect(failure.cause == .diskFull)
        #expect(failure.shortReason == "Disk is full")
    }

    // MARK: Missing tool

    @Test("a missing executable points the user at Settings")
    func missingTool() {
        // The message SubprocessError.toolNotFound produces.
        let failure = ProcessingFailure.classify(
            stderr: "Tool not found at /Applications/Adobe DNG Converter.app/Contents/MacOS/x",
            step: .convert,
            tool: .adobeDngConverter
        )
        #expect(failure.cause == .toolMissing)
    }

    // MARK: Anything else

    @Test("an unrecognised error keeps its first line so the user sees something real")
    func unknownKeepsDetail() {
        let failure = ProcessingFailure.classify(
            stderr: "Error: the DNG is structurally invalid\nsecond line ignored",
            step: .convert,
            tool: .adobeDngConverter
        )

        #expect(failure.cause == .other)
        #expect(failure.summary.contains("structurally invalid"))
        #expect(!failure.summary.contains("second line"))
    }

    @Test("empty output still produces a sentence naming the tool and the step")
    func emptyOutput() {
        let failure = ProcessingFailure.classify(
            stderr: "", step: .writeTags, tool: .exiftool)

        #expect(failure.cause == .other)
        #expect(failure.summary == "exiftool failed while writing tags.")
    }

    @Test("the raw output is always kept for the Copy button, whatever the cause")
    func outputPreserved() {
        let failure = ProcessingFailure.classify(
            stderr: Self.exiftoolReadOnly, step: .writeTags, tool: .exiftool)
        #expect(failure.toolOutput == Self.exiftoolReadOnly)
    }

    // MARK: The skip that must not become a failure

    @Test("dnglab's unsupported-camera line is parsed into the model name")
    func unsupportedCameraParsed() throws {
        let model = try #require(
            DngLab.unsupportedCameraModel(in: Self.dnglabUnknownCamera))
        #expect(model == "NIKON D1H")
    }

    @Test("ordinary dnglab errors are not mistaken for an unsupported camera")
    func notEveryErrorIsUnsupported() {
        #expect(DngLab.unsupportedCameraModel(in: Self.dnglabReadOnly) == nil)
        #expect(DngLab.unsupportedCameraModel(in: "") == nil)
    }
}
