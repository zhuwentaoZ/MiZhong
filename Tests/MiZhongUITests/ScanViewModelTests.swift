@testable import MiZhong
import DuplicateCore
import Foundation
import XCTest

/// Tests the actual presentation model and its disk-backed workflow.
/// These checks do not launch a window or constitute visual/accessibility QA.
@MainActor
final class ScanViewModelTests: XCTestCase {
    private struct Fixture {
        let parent: URL
        let source: URL
        let support: URL
        let a: URL
        let b: URL
        let aFile: URL
        let bFile: URL
        let uniqueFile: URL
        let previousSupportOverride: String?

        init() throws {
            parent = FileManager.default.temporaryDirectory
                .appendingPathComponent("mizhong-model-test-" + UUID().uuidString, isDirectory: true)
                .standardizedFileURL
            source = parent.appendingPathComponent("source", isDirectory: true)
            support = parent.appendingPathComponent("app-support", isDirectory: true)
            a = source.appendingPathComponent("A", isDirectory: true)
            b = source.appendingPathComponent("B", isDirectory: true)
            aFile = a.appendingPathComponent("course/lesson.txt")
            bFile = b.appendingPathComponent("copy/lesson.txt")
            uniqueFile = b.appendingPathComponent("new.txt")
            try FileManager.default.createDirectory(at: aFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: bFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try Data("shared course content".utf8).write(to: aFile)
            try Data("shared course content".utf8).write(to: bFile)
            try Data("new material".utf8).write(to: uniqueFile)
            previousSupportOverride = ProcessInfo.processInfo.environment["MIZHONG_SUPPORT_DIR"]
            setenv("MIZHONG_SUPPORT_DIR", support.path, 1)
        }

        @MainActor func makeModel() throws -> ScanViewModel {
            guard ScanViewModel.support == support else { throw FixtureFailure.invalidSupportDirectory }
            let model = ScanViewModel()
            model.roots = [b]
            model.referenceRoots = [a]
            model.scanMode = .reference
            model.detectDuplicateFolders = true
            model.extensions = "txt"
            model.useCache = false
            return model
        }

        func remove() {
            if let previousSupportOverride { setenv("MIZHONG_SUPPORT_DIR", previousSupportOverride, 1) }
            else { unsetenv("MIZHONG_SUPPORT_DIR") }
            try? FileManager.default.removeItem(at: parent)
        }
    }

    private enum FixtureFailure: Error { case invalidSupportDirectory }
    private enum WaitFailure: Error { case timeout }

    private func waitUntilIdle(_ model: ScanViewModel, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(10)
        while model.isScanning || model.isLoadingHistory {
            guard Date() < deadline else {
                model.cancel()
                XCTFail("Presentation-model operation exceeded 10 seconds", file: file, line: line)
                throw WaitFailure.timeout
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testReferenceResultsAndFrozenProtectionSurviveSidebarEdits() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = try fixture.makeModel()
        defer { model.cancel() }
        XCTAssertFalse(model.similarImages)
        model.scan()
        try await waitUntilIdle(model)

        let result = try XCTUnwrap(model.result)
        XCTAssertFalse(result.isIncomplete, result.errors.joined(separator: "\n"))
        XCTAssertTrue(result.sessionSaved)
        XCTAssertEqual(result.mode, .reference)
        XCTAssertEqual(result.referencePaths, [fixture.a.path])
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(Set(result.uniqueFiles.map(\.url)), [fixture.uniqueFile])
        XCTAssertTrue(result.duplicateFolderGroups.contains {
            Set($0.folders) == [fixture.aFile.deletingLastPathComponent(), fixture.bFile.deletingLastPathComponent()]
        })
        let aFile = try XCTUnwrap(result.groups.flatMap(\.files).first { $0.url == fixture.aFile })
        let bFile = try XCTUnwrap(result.groups.flatMap(\.files).first { $0.url == fixture.bFile })
        XCTAssertFalse(model.canSelect(aFile))
        XCTAssertTrue(model.canSelect(bFile))

        model.referenceRoots = []
        model.roots = [fixture.a]
        model.scanMode = .standard
        model.protectedPaths = []
        XCTAssertTrue(model.isReference(aFile.url))
        XCTAssertFalse(model.canSelect(aFile), "The result's original A roots remain protected")
        model.autoSelect()
        XCTAssertEqual(model.selectedForTrash, [fixture.bFile])
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.aFile), Data("shared course content".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.bFile), Data("shared course content".utf8))
    }

    func testOfflineHistoryIsReadOnlyAndReviewReturnsOnlyAfterExplicitResume() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try fixture.makeModel()
        defer { original.cancel() }
        original.scan()
        try await waitUntilIdle(original)
        original.autoSelect()
        let sessionURL = try XCTUnwrap(original.activeSessionURL)
        XCTAssertEqual(original.selectedForTrash, [fixture.bFile])

        let offline = fixture.parent.appendingPathComponent("offline-source", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.source, to: offline)
        let restored = ScanViewModel()
        defer { restored.cancel() }
        restored.refreshHistory()
        try await waitUntilIdle(restored)
        XCTAssertEqual(restored.history.count, 1, "History must load without accessing the original directories")
        restored.restoreSession(sessionURL)
        try await waitUntilIdle(restored)
        XCTAssertTrue(restored.isRestoredSession)
        XCTAssertFalse(restored.canCleanResults)
        XCTAssertTrue(restored.selectedForTrash.isEmpty)
        let storedB = try XCTUnwrap(restored.result?.groups.flatMap(\.files).first { $0.url == fixture.bFile })
        XCTAssertFalse(restored.canSelect(storedB))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertTrue(restored.hasSavedTask)

        try FileManager.default.moveItem(at: offline, to: fixture.source)
        restored.referenceRoots = []
        restored.roots = [fixture.parent]
        restored.scanMode = .standard
        restored.extensions = "pdf"
        restored.resumeActiveSession()
        try await waitUntilIdle(restored)
        XCTAssertFalse(restored.isRestoredSession)
        XCTAssertTrue(restored.canCleanResults, restored.result?.errors.joined(separator: "\n") ?? "No result")
        XCTAssertEqual(restored.scanMode, .reference)
        XCTAssertEqual(restored.roots, [fixture.b])
        XCTAssertEqual(restored.referenceRoots, [fixture.a])
        XCTAssertEqual(restored.extensions, "txt")
        XCTAssertEqual(restored.selectedForTrash, [fixture.bFile])
        let storedA = try XCTUnwrap(restored.result?.groups.flatMap(\.files).first { $0.url == fixture.aFile })
        XCTAssertFalse(restored.canSelect(storedA))
        XCTAssertEqual(try Data(contentsOf: fixture.aFile), try Data(contentsOf: fixture.bFile))
    }

    func testResumeRechecksChangedFilesAndDropsObsoleteReviewSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try fixture.makeModel()
        defer { original.cancel() }
        original.scan()
        try await waitUntilIdle(original)
        original.autoSelect()
        let sessionURL = try XCTUnwrap(original.activeSessionURL)

        // Only this test's local fixtures are changed, to simulate edits between sessions.
        try Data("different course now!".utf8).write(to: fixture.bFile)
        let newReference = fixture.a.appendingPathComponent("new.txt")
        try Data("new material".utf8).write(to: newReference)
        let restored = ScanViewModel()
        defer { restored.cancel() }
        restored.restoreSession(sessionURL)
        try await waitUntilIdle(restored)
        XCTAssertTrue(restored.selectedForTrash.isEmpty)
        restored.resumeActiveSession()
        try await waitUntilIdle(restored)

        let result = try XCTUnwrap(restored.result)
        XCTAssertFalse(result.isIncomplete, result.errors.joined(separator: "\n"))
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(Set(result.groups.flatMap(\.files).map(\.url)), [newReference, fixture.uniqueFile])
        XCTAssertEqual(Set(result.uniqueFiles.map(\.url)), [fixture.bFile])
        XCTAssertTrue(restored.selectedForTrash.isEmpty, "A former duplicate that became unique must not remain selected")
        XCTAssertEqual(result.referencePaths, [fixture.a.path])
        for file in result.groups.flatMap(\.files) where file.url == newReference {
            XCTAssertFalse(restored.canSelect(file))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.bFile), Data("different course now!".utf8))
    }
}
