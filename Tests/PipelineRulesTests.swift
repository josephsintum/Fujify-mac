import Foundation
import Testing

@testable import Fujify

/// Locks in the batch rules from docs/PIPELINE-CONTRACT.md §7, §8.3 and §9.
///
/// These exercise the decisions, not the subprocesses: no file has to exist
/// and no tool has to run, which is what keeps them fast enough to be worth
/// having.
@Suite("Pipeline rules")
@MainActor
struct PipelineRulesTests {

    private static func makePipeline() -> Pipeline {
        let suite = "fujify.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return Pipeline(toolLocator: ToolLocator(), defaults: defaults)
    }

    private static func queue(_ pipeline: Pipeline, _ names: [String]) -> [FileItem] {
        let items = names.map {
            FileItem(url: URL(fileURLWithPath: "/Users/someone/Pictures/\($0)"))
        }
        pipeline.files = items
        return items
    }

    // MARK: Restoring the saved output folder

    @Test("a saved output folder that still exists is restored")
    func savedFolderIsRestored() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let defaults = UserDefaults(suiteName: "fujify.tests.\(UUID().uuidString)")!
        defaults.set(folder.path, forKey: "defaultOutputFolder")

        let pipeline = Pipeline(toolLocator: ToolLocator(), defaults: defaults)
        #expect(pipeline.defaultOutputFolder?.path == folder.path)
        #expect(pipeline.outputFolder?.path == folder.path)
    }

    @Test("a saved folder that has gone away falls back to in place")
    func missingSavedFolderFallsBack() {
        // The real case is an external drive left unmounted. Restoring the
        // path regardless meant the toolbar claimed the folder was fine and
        // then every file in the batch failed at the write step.
        let gone = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let defaults = UserDefaults(suiteName: "fujify.tests.\(UUID().uuidString)")!
        defaults.set(gone.path, forKey: "defaultOutputFolder")

        let pipeline = Pipeline(toolLocator: ToolLocator(), defaults: defaults)
        #expect(pipeline.defaultOutputFolder == nil)
        #expect(pipeline.outputFolder == nil)
    }

    @Test("a saved path that is now a file, not a folder, falls back too")
    func savedPathThatIsAFileFallsBack() throws {
        let file = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).txt")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let defaults = UserDefaults(suiteName: "fujify.tests.\(UUID().uuidString)")!
        defaults.set(file.path, forKey: "defaultOutputFolder")

        let pipeline = Pipeline(toolLocator: ToolLocator(), defaults: defaults)
        #expect(pipeline.outputFolder == nil)
    }

    // MARK: Outcome wording shared by the status bar and the notification

    @Test("the outcome summary leaves out whatever is zero")
    func outcomeSummaryOmitsZeros() {
        #expect(Pipeline.Counts(done: 2046, skipped: 9, failed: 2).outcomeSummary
            == "2,046 done · 9 skipped · 2 failed")
        #expect(Pipeline.Counts(done: 5).outcomeSummary == "5 done")
        #expect(Pipeline.Counts(skipped: 1, failed: 3).outcomeSummary
            == "1 skipped · 3 failed")
        #expect(Pipeline.Counts().outcomeSummary.isEmpty)
    }

    @Test("retryable counts the outcomes Retry All would pick up")
    func retryableCountsSkippedAndFailed() {
        let counts = Pipeline.Counts(pending: 4, processing: 1, done: 10, skipped: 2, failed: 3)
        #expect(counts.retryable == 5)
        #expect(counts.settled == 15)
    }

    // MARK: The already-tagged skip (§9)

    @Test("only DNG input is worth checking, since a RAW is never tagged")
    func onlyDngIsChecked() {
        let dng = URL(fileURLWithPath: "/p/a.dng")
        let raw = URL(fileURLWithPath: "/p/a.arw")

        #expect(Pipeline.mightBeAlreadyTagged(
            url: dng, skipEnabled: true, forceReprocess: false))
        #expect(!Pipeline.mightBeAlreadyTagged(
            url: raw, skipEnabled: true, forceReprocess: false))
    }

    @Test("the extension check ignores case, as the rest of the app does")
    func extensionCaseInsensitive() {
        #expect(Pipeline.mightBeAlreadyTagged(
            url: URL(fileURLWithPath: "/p/A.DNG"), skipEnabled: true, forceReprocess: false))
    }

    @Test("turning the setting off skips the check entirely")
    func settingOff() {
        #expect(!Pipeline.mightBeAlreadyTagged(
            url: URL(fileURLWithPath: "/p/a.dng"),
            skipEnabled: false, forceReprocess: false))
    }

    /// Process Again has to be able to re-write tags on a file that already
    /// has them; otherwise the menu item would appear to do nothing.
    @Test("Process Again bypasses the skip")
    func forceReprocessBypasses() {
        #expect(!Pipeline.mightBeAlreadyTagged(
            url: URL(fileURLWithPath: "/p/a.dng"),
            skipEnabled: true, forceReprocess: true))
    }

    // MARK: The in-place confirmation (§7)

    @Test("queued DNGs with no output folder are counted, so the user is asked")
    func inPlaceCounted() {
        let pipeline = Self.makePipeline()
        Self.queue(pipeline, ["a.dng", "b.dng", "c.arw"])
        pipeline.outputFolder = nil

        #expect(pipeline.pendingInPlaceDngCount == 2)
    }

    @Test("choosing an output folder means nothing is rewritten, so nothing is asked")
    func outputFolderSuppressesTheQuestion() {
        let pipeline = Self.makePipeline()
        Self.queue(pipeline, ["a.dng", "b.dng"])
        pipeline.outputFolder = URL(fileURLWithPath: "/Users/someone/Pictures/Fujified")

        #expect(pipeline.pendingInPlaceDngCount == 0)
    }

    @Test("a RAW-only batch never triggers the question")
    func rawOnlyBatch() {
        let pipeline = Self.makePipeline()
        Self.queue(pipeline, ["a.arw", "b.cr3", "c.nef"])

        #expect(pipeline.pendingInPlaceDngCount == 0)
    }

    @Test("DNGs that are already done or skipped are not counted again")
    func onlyPendingCounts() {
        let pipeline = Self.makePipeline()
        let items = Self.queue(pipeline, ["a.dng", "b.dng", "c.dng"])
        items[0].status = .done
        items[1].status = .skipped(.alreadyTagged(as: "Fujifilm X-T5"))

        #expect(pipeline.pendingInPlaceDngCount == 1)
    }

    // MARK: Counts

    @Test("counts split the queue by status")
    func counts() {
        let pipeline = Self.makePipeline()
        let items = Self.queue(pipeline, ["a.arw", "b.arw", "c.arw", "d.arw", "e.arw"])
        items[0].status = .done
        items[1].status = .done
        items[2].status = .skipped(.dngOnlyMode)
        items[3].status = .failed(
            ProcessingFailure(
                step: .convert, tool: .dnglab, cause: .readOnlyOutput, toolOutput: ""))
        // items[4] stays pending

        let counts = pipeline.counts
        #expect(counts.done == 2)
        #expect(counts.skipped == 1)
        #expect(counts.failed == 1)
        #expect(counts.pending == 1)
        #expect(counts.total == 5)
        #expect(counts.settled == 4)
    }

    // MARK: Retry and Process Again (§8.3)

    @Test("Retry returns failed and skipped files to pending, and leaves done alone")
    func retryOnlyTouchesRetryable() {
        let pipeline = Self.makePipeline()
        let items = Self.queue(pipeline, ["a.arw", "b.arw", "c.arw"])
        items[0].status = .failed(
            ProcessingFailure(
                step: .convert, tool: .dnglab, cause: .other, toolOutput: ""))
        items[1].status = .skipped(.unsupportedCamera(model: "NIKON D1H"))
        items[2].status = .done

        pipeline.retry(Set(items.map(\.id)))

        #expect(items[0].status.isPending)
        #expect(items[1].status.isPending)
        #expect(items[2].status.isDone, "a finished file should need Process Again")
    }

    @Test("Retry does not set the force flag, so the skip rule still applies")
    func retryDoesNotForce() {
        let pipeline = Self.makePipeline()
        let items = Self.queue(pipeline, ["a.dng"])
        items[0].status = .failed(
            ProcessingFailure(
                step: .writeTags, tool: .exiftool, cause: .other, toolOutput: ""))

        pipeline.retry([items[0].id])

        #expect(items[0].status.isPending)
        #expect(!items[0].forceReprocess)
    }

    @Test("Process Again re-queues a finished file and forces it past the skip")
    func reprocessForces() {
        let pipeline = Self.makePipeline()
        let items = Self.queue(pipeline, ["a.dng"])
        items[0].status = .done

        pipeline.reprocess([items[0].id])

        #expect(items[0].status.isPending)
        #expect(items[0].forceReprocess)
    }

    @Test("Retry All picks up everything that failed or was skipped")
    func retryAll() {
        let pipeline = Self.makePipeline()
        let items = Self.queue(pipeline, ["a.arw", "b.arw", "c.arw"])
        items[0].status = .failed(
            ProcessingFailure(
                step: .convert, tool: .dnglab, cause: .diskFull, toolOutput: ""))
        items[1].status = .skipped(.dngOnlyMode)
        items[2].status = .done

        pipeline.retryAll()

        #expect(pipeline.counts.pending == 2)
        #expect(pipeline.counts.done == 1)
    }

    // MARK: Status presentation (§11)

    @Test("every status leads with one word")
    func statusLabels() {
        #expect(FileItem.Status.pending.label == "Pending")
        #expect(FileItem.Status.processing(.convert).label == "Converting…")
        #expect(FileItem.Status.processing(.writeTags).label == "Writing tags…")
        #expect(FileItem.Status.done.label == "Done")
        #expect(FileItem.Status.skipped(.dngOnlyMode).label == "Skipped")
    }

    @Test("only the outcomes that need explaining carry a reason")
    func shortReasons() {
        #expect(FileItem.Status.pending.shortReason == nil)
        #expect(FileItem.Status.done.shortReason == nil)
        #expect(
            FileItem.Status.skipped(.alreadyTagged(as: "Fujifilm X-T5")).shortReason
                == "Already tagged as Fujifilm X-T5")
    }

    @Test("a done file points later actions at its output, not its source")
    func inspectionURLPrefersOutput() {
        let item = FileItem(url: URL(fileURLWithPath: "/p/a.arw"))
        #expect(item.inspectionURL.lastPathComponent == "a.arw")

        item.outputURL = URL(fileURLWithPath: "/out/a.dng")
        #expect(item.inspectionURL.lastPathComponent == "a.dng")
    }
}
