@testable import DuplicateCore
import Foundation
import XCTest

final class LibraryComparisonTests: XCTestCase {
    func testReferenceMembershipUsesPathComponentsAndNormalizesRoots() {
        XCTAssertTrue(LibraryComparison.isReference(file("/library/A/course/lesson.pdf"), referencePaths: ["/library/tmp/../A/"]))
        XCTAssertFalse(LibraryComparison.isReference(file("/library/AB/lesson.pdf"), referencePaths: ["/library/A"]))
        XCTAssertTrue(LibraryComparison.isReference(file("/library/A/file"), referencePaths: ["/"]))
        XCTAssertFalse(LibraryComparison.isReference(file("/library/A/file"), referencePaths: []))
    }

    func testCrossGroupsExcludeDuplicatesWhollyWithinOneSide() {
        let shared = DuplicateGroup(hash: "shared", files: [file("/B/copy"), file("/A/original"), file("/B/second-copy")])
        let onlyA = DuplicateGroup(hash: "only-a", files: [file("/A/one"), file("/A/two")])
        let onlyB = DuplicateGroup(hash: "only-b", files: [file("/B/one"), file("/B/two")])
        let groups = LibraryComparison.crossGroups([onlyA, onlyB, shared], referencePaths: ["/A"])
        XCTAssertEqual(groups.map(\.hash), ["shared"])
        XCTAssertEqual(groups[0].files.map(\.id), ["/A/original", "/B/copy", "/B/second-copy"])
    }

    func testUniqueTargetsRequireFullHashesAndCanContainDuplicatesWithinB() {
        let files = [file("/A/one"), file("/B/copy"), file("/B/new-one"), file("/B/new-two"), file("/B/unreadable")]
        let hashes = ["/A/one": "old", "/B/copy": "old", "/B/new-one": "new", "/B/new-two": "new"]
        let unique = LibraryComparison.uniqueTargets(files: files, hashes: hashes, referencePaths: ["/A"])
        XCTAssertEqual(unique.map(\.id), ["/B/new-one", "/B/new-two"])
        XCTAssertTrue(LibraryComparison.uniqueTargets(files: files, hashes: hashes.filter { $0.key != "/A/one" },
                                                     referencePaths: ["/A"]).isEmpty)
    }

    func testFolderMatchesDependOnRelativeNamesAndEmptyDirectoryStructure() {
        let files = [file("/A/course/lesson.pdf"), file("/B/course/lesson.pdf"),
                     file("/C/course/renamed.pdf"), file("/D/course/lesson.pdf")]
        let directories = ["/A/course", "/A/course/empty", "/B/course", "/B/course/empty", "/C/course", "/C/course/empty", "/D/course"]
        let groups = folders(files, directories: directories)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].folders.map(\.path), ["/A/course", "/B/course"])
        XCTAssertEqual(groups[0].fileCount, 1)
        XCTAssertEqual(groups[0].totalBytes, 10)
    }

    func testUnknownChildHashInvalidatesWholeAncestorsWithoutHidingIndependentFolders() {
        let files = [file("/A/course/lesson"), file("/A/course/sub/unknown"),
                     file("/B/course/lesson"), file("/B/course/sub/unknown"),
                     file("/C/other/item"), file("/D/other/item")]
        let directories = ["/A", "/A/course", "/A/course/sub", "/B", "/B/course", "/B/course/sub", "/C/other", "/D/other"]
        var hashes = Dictionary(uniqueKeysWithValues: files.map { ($0.id, "same") })
        hashes.removeValue(forKey: "/A/course/sub/unknown")
        let groups = LibraryComparison.duplicateFolders(files: files, hashes: hashes, directories: directories.map(url),
                                                        referencePaths: [], mode: .standard, control: ScanControl())
        XCTAssertFalse(groups.flatMap(\.folders).contains { $0.path == "/A" || $0.path.hasPrefix("/A/") })
        XCTAssertTrue(groups.contains { $0.folders.map(\.path) == ["/C/other", "/D/other"] })
    }

    func testFailedDirectoryEnumerationCannotMasqueradeAsEmptyFolder() {
        let files = [file("/A/course/lesson"), file("/B/course/lesson")]
        let directories = ["/A/course", "/B/course"]
        let groups = LibraryComparison.duplicateFolders(
            files: files, hashes: Dictionary(uniqueKeysWithValues: files.map { ($0.id, "same") }),
            directories: directories.map(url), referencePaths: [], mode: .standard, control: ScanControl(),
            incompleteDirectories: ["/A/course/unreadable-child"])
        XCTAssertTrue(groups.isEmpty)
    }

    func testReferenceFoldersRequireBothSidesAndDoNotClassifyMixedAncestorAsB() {
        let files = [file("/A/c1/file"), file("/A/c2/file"), file("/B/c3/file"),
                     file("/B/new/file"), file("/C/new/file")]
        let directories = ["/A/c1", "/A/c2", "/B/c3", "/B/new", "/C/new"]
        let hashes = ["/A/c1/file": "shared", "/A/c2/file": "shared", "/B/c3/file": "shared",
                      "/B/new/file": "b-only", "/C/new/file": "b-only"]
        let groups = LibraryComparison.duplicateFolders(files: files, hashes: hashes, directories: directories.map(url),
                                                        referencePaths: ["/A"], mode: .reference, control: ScanControl())
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].folders.map(\.path), ["/A/c1", "/A/c2", "/B/c3"])

        let mixedFiles = [file("/library/reference/item"), file("/elsewhere/reference/item")]
        let mixed = folders(mixedFiles, directories: ["/library", "/library/reference", "/elsewhere", "/elsewhere/reference"],
                            references: ["/library/reference"], mode: .reference)
        XCTAssertEqual(mixed.count, 1)
        XCTAssertEqual(mixed[0].folders.map(\.path), ["/elsewhere/reference", "/library/reference"])
    }

    func testFolderAnalysisIsDeterministicAndCancellationReturnsNoClaims() {
        let files = [file("/A/course/sub/one"), file("/A/course/two", size: 20),
                     file("/B/course/sub/one"), file("/B/course/two", size: 20)]
        let directories = ["/A/course", "/A/course/sub", "/B/course", "/B/course/sub"]
        let forward = folders(files, directories: directories)
        let reverse = folders(Array(files.reversed()), directories: Array(directories.reversed()))
        XCTAssertEqual(forward.map(\.id), reverse.map(\.id))
        XCTAssertEqual(forward.map { $0.folders.map(\.path) }, reverse.map { $0.folders.map(\.path) })
        XCTAssertEqual(forward.first?.fileCount, 2)
        XCTAssertEqual(forward.first?.totalBytes, 30)
        let control = ScanControl(); control.cancel()
        XCTAssertTrue(LibraryComparison.duplicateFolders(files: files, hashes: [:], directories: directories.map(url),
                                                        referencePaths: [], mode: .standard, control: control).isEmpty)
        XCTAssertTrue(folders([], directories: ["/A/empty", "/B/empty"]).isEmpty)
    }

    func testShallowScanDoesNotClaimUnvisitedSubtreesAreDuplicateFolders() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mizhong-shallow-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let a = base.appendingPathComponent("A"), b = base.appendingPathComponent("B")
        try write("same", to: a.appendingPathComponent("lesson"))
        try write("same", to: b.appendingPathComponent("lesson"))
        try write("different A", to: a.appendingPathComponent("sub/only-a"))
        try write("different B", to: b.appendingPathComponent("sub/only-b"))
        var options = ScanOptions(recursive: false)
        options.detectDuplicateFolders = true
        let result = await DuplicateScanner().scan(roots: [a, b], options: options) { _ in }
        XCTAssertFalse(result.groups.isEmpty)
        XCTAssertTrue(result.duplicateFolderGroups.isEmpty, "Unvisited subtrees cannot establish folder equality")
    }

    func testResumeDoesNotFollowAReplacedDirectorySymlink() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mizhong-resume-link-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let scan = base.appendingPathComponent("scan")
        let a = scan.appendingPathComponent("A"), b = scan.appendingPathComponent("B")
        let replaced = a.appendingPathComponent("sub")
        let outside = base.appendingPathComponent("outside")
        let session = base.appendingPathComponent("session/task.mizhong")
        try write("same bytes", to: replaced.appendingPathComponent("lesson"))
        try write("same bytes", to: b.appendingPathComponent("lesson"))
        try write("same bytes", to: outside.appendingPathComponent("lesson"))
        var options = ScanOptions(); options.detectDuplicateFolders = true
        let first = await DuplicateScanner().scan(roots: [a, b], options: options, sessionURL: session) { _ in }
        XCTAssertEqual(first.groups.count, 1)
        try FileManager.default.removeItem(at: replaced)
        try FileManager.default.createSymbolicLink(at: replaced, withDestinationURL: outside)
        let resumed = await DuplicateScanner().scan(roots: [a, b], options: options, sessionURL: session, resume: true) { _ in }
        XCTAssertFalse(resumed.groups.flatMap(\.files).contains { $0.id.hasPrefix(replaced.path + "/") },
                       "A directory replaced with a symlink must not keep old descendants in the resumed inventory")
    }

    func testResumePrunesQueuedChildrenWhoseDeletionWasConfirmedByParentListing() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mizhong-resume-deleted-frontier-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let scan = base.appendingPathComponent("scan"), session = base.appendingPathComponent("session/task.mizhong")
        let a = scan.appendingPathComponent("A"), b = scan.appendingPathComponent("B")
        try write("same", to: a.appendingPathComponent("lesson"))
        try write("same", to: b.appendingPathComponent("lesson"))
        let control = ScanControl()
        let first = await DuplicateScanner().scan(roots: [scan], options: .init(), control: control, sessionURL: session) { update in
            if update.phase == .discovering { control.cancel() }
        }
        XCTAssertTrue(first.wasCancelled)
        try FileManager.default.removeItem(at: a)
        try FileManager.default.removeItem(at: b)
        let resumed = await DuplicateScanner().scan(roots: [scan], options: .init(), sessionURL: session, resume: true) { _ in }
        XCTAssertFalse(resumed.isIncomplete, "Deleted queued children should not remain permanently blocked after parent confirms deletion")
        XCTAssertTrue(resumed.pendingPaths.isEmpty)
        XCTAssertEqual(resumed.scannedFiles, 0)
    }

    func testResumeReconcilesFilesChangedToDirectoriesAndDirectoriesChangedToFiles() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mizhong-resume-type-change-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let scan = base.appendingPathComponent("scan"), session = base.appendingPathComponent("session/task.mizhong")
        let oldFile = scan.appendingPathComponent("file-becomes-directory")
        let oldDirectory = scan.appendingPathComponent("directory-becomes-file")
        let unchanged = scan.appendingPathComponent("unchanged")
        try write("shared", to: oldFile)
        try write("shared", to: oldDirectory.appendingPathComponent("child"))
        try write("shared", to: unchanged)
        var options = ScanOptions(); options.detectDuplicateFolders = true
        _ = await DuplicateScanner().scan(roots: [scan], options: options, sessionURL: session) { _ in }
        try FileManager.default.removeItem(at: oldFile)
        try write("shared", to: oldFile.appendingPathComponent("new-child"))
        try FileManager.default.removeItem(at: oldDirectory)
        try write("shared", to: oldDirectory)
        let resumed = await DuplicateScanner().scan(roots: [scan], options: options, sessionURL: session, resume: true) { _ in }
        XCTAssertFalse(resumed.isIncomplete, resumed.errors.joined(separator: "\n"))
        XCTAssertTrue(resumed.pendingPaths.isEmpty)
        XCTAssertEqual(resumed.scannedFiles, 3)
        XCTAssertEqual(resumed.groups.count, 1)
        XCTAssertEqual(Set(resumed.groups.flatMap(\.files).map(\.id)),
                       [oldFile.appendingPathComponent("new-child").path, oldDirectory.path, unchanged.path])
    }

    func testResumeDoesNotAcceptLocalReplacementOfANetworkReferenceRoot() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mizhong-resume-network-root-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let a = base.appendingPathComponent("scan/A"), b = base.appendingPathComponent("scan/B")
        let session = base.appendingPathComponent("session/task.mizhong")
        try write("shared", to: a.appendingPathComponent("lesson"))
        try write("shared", to: b.appendingPathComponent("lesson"))
        try write("only B", to: b.appendingPathComponent("new"))
        var options = ScanOptions(); options.mode = .reference; options.referencePaths = [a.path]
        _ = await DuplicateScanner().scan(roots: [a, b], options: options, sessionURL: session) { _ in }
        var checkpoint = try ScanSessionStore.load(session)
        // This is a local simulation of a previously network-backed mountpoint. No NAS is changed.
        checkpoint.networkRoots = [a.standardizedFileURL.path]
        try ScanSessionStore.save(checkpoint, to: session)
        let resumed = await DuplicateScanner().scan(roots: [a, b], options: options, sessionURL: session, resume: true) { _ in }
        XCTAssertTrue(resumed.isIncomplete)
        XCTAssertTrue(resumed.pendingPaths.contains(a.standardizedFileURL.path))
        XCTAssertTrue(resumed.uniqueFiles.isEmpty, "Unavailable A must not make observed B files appear absent from A")
        XCTAssertTrue(resumed.groups.isEmpty)
        XCTAssertEqual(try ScanSessionStore.load(session).status, .needsRetry)
    }

    func testSessionLoadRejectsUnscopedNetworkAndShallowDirectoryMetadata() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mizhong-session-scope-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let scan = base.appendingPathComponent("scan"), session = base.appendingPathComponent("session/task.mizhong")
        try FileManager.default.createDirectory(at: scan, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalidRoots = ["smb://example-user:example-password@example.invalid/share",
                            base.appendingPathComponent("outside").path,
                            scan.appendingPathComponent("nested").path, scan.path + "/../outside"]
        for path in invalidRoots {
            var checkpoint = ScanSession(roots: [scan], options: .init())
            checkpoint.networkRoots = [path]
            try JSONEncoder().encode(checkpoint).write(to: session)
            XCTAssertThrowsError(try ScanSessionStore.load(session), "Invalid network root accepted: \(path)")
        }
        for path in [base.appendingPathComponent("outside").path, scan.path + "/../outside", "smb://example.invalid/share"] {
            var checkpoint = ScanSession(roots: [scan], options: .init())
            checkpoint.shallowDirectories = [path]
            try JSONEncoder().encode(checkpoint).write(to: session)
            XCTAssertThrowsError(try ScanSessionStore.load(session), "Invalid shallow scope accepted: \(path)")
        }
    }

    func testSessionLoadRejectsDirectoryKeyMismatch() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mizhong-session-directory-key-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let scan = base.appendingPathComponent("scan"), session = base.appendingPathComponent("session/task.mizhong")
        try FileManager.default.createDirectory(at: scan, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        var checkpoint = ScanSession(roots: [scan], options: .init())
        checkpoint.directories[base.appendingPathComponent("outside").path] = .init(
            task: .init(url: scan, recursive: true), stamp: try DirectoryStamp.read(scan))
        try JSONEncoder().encode(checkpoint).write(to: session)
        XCTAssertThrowsError(try ScanSessionStore.load(session))
    }

    private func folders(_ files: [FileRecord], directories: [String], references: Set<String> = [],
                         mode: ScanMode = .standard) -> [DuplicateFolderGroup] {
        LibraryComparison.duplicateFolders(files: files, hashes: Dictionary(uniqueKeysWithValues: files.map { ($0.id, "same") }),
                                           directories: directories.map(url), referencePaths: references, mode: mode, control: ScanControl())
    }
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }
    private func file(_ path: String, size: UInt64 = 10) -> FileRecord {
        FileRecord(url: url(path), size: size, modifiedAt: nil, isNetworkVolume: false)
    }
    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
}
