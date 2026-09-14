@testable import DuplicateCore
import CoreGraphics
import Foundation
import ImageIO
import XCTest

final class ScanSessionTests: XCTestCase {
    func testIncrementalTaskAddsRootAndReusesHistoricalRange() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let bytes = Data("same content".utf8)
        _ = try fixture.write("original.bin", bytes)
        let options = ScanOptions()
        _ = await DuplicateScanner().scan(roots: [fixture.root], options: options,
                                           sessionURL: fixture.session) { _ in }

        let added = fixture.parent.appendingPathComponent("added", isDirectory: true)
        try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
        try bytes.write(to: added.appendingPathComponent("copy.bin"))
        let incremental = fixture.parent.appendingPathComponent("sessions/incremental.mizhong")
        try ScanSessionStore.createIncrementalTask(from: fixture.session, adding: [added], to: incremental)
        let prepared = try ScanSessionStore.load(incremental)
        XCTAssertEqual(Set(prepared.roots.map(\.path)), Set([fixture.root.path, added.path]))

        let result = await DuplicateScanner().scan(roots: [], options: .init(), sessionURL: incremental,
                                                    resume: true) { _ in }
        XCTAssertEqual(result.groups.first?.files.count, 2)
    }

    private struct Fixture {
        let parent: URL
        let root: URL
        let session: URL

        init() throws {
            parent = FileManager.default.temporaryDirectory
                .appendingPathComponent("mizhong-session-test-" + UUID().uuidString, isDirectory: true)
            root = parent.appendingPathComponent("source", isDirectory: true)
            session = parent.appendingPathComponent("sessions/task.mizhong")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        @discardableResult
        func write(_ name: String, _ data: Data) throws -> URL {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        }

        func remove() { try? FileManager.default.removeItem(at: parent) }
    }

    private struct SourceSnapshot: Equatable {
        var data: [String: Data] = [:]
        var files: [String: FileStamp] = [:]
        var directories: [String: DirectoryStamp] = [:]

        init(_ root: URL) throws {
            directories[root.path] = try DirectoryStamp.read(root)
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: Array(keys)))
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: keys)
                if values.isDirectory == true {
                    directories[url.path] = try DirectoryStamp.read(url)
                } else if values.isRegularFile == true {
                    files[url.path] = try FileStamp.read(url)
                    data[url.path] = try Data(contentsOf: url)
                }
            }
        }
    }

    /// A deterministic, local-only file-read failure during a progress callback.
    private final class OneShotMove: @unchecked Sendable {
        let source: URL
        let destination: URL
        private let lock = NSLock()
        private var attempted = false
        private var failure: String?

        init(source: URL, destination: URL) {
            self.source = source
            self.destination = destination
        }

        func perform() {
            lock.lock(); defer { lock.unlock() }
            guard !attempted else { return }
            attempted = true
            do { try FileManager.default.moveItem(at: source, to: destination) }
            catch { failure = error.localizedDescription }
        }

        var succeeded: Bool {
            lock.lock(); defer { lock.unlock() }
            return attempted && failure == nil
        }
    }

    private func duplicatePaths(_ result: ScanResult) -> Set<Set<String>> {
        Set(result.groups.map { Set($0.files.map(\.id)) })
    }

    private func writeImageFixture(to url: URL, type: String = "public.png") throws {
        let side = 32
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in 0..<side {
            for x in 0..<side {
                context.setFillColor(red: CGFloat(x) / CGFloat(side), green: CGFloat(y) / CGFloat(side),
                                     blue: CGFloat((x + y) % side) / CGFloat(side), alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testCancelledDiscoveryResumesUsingAnotherScannerWithoutChangingSources() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        for folder in 0..<4 {
            for file in 0..<4 {
                try fixture.write("folder-\(folder)/file-\(file).bin", Data("payload \(file)".utf8))
            }
        }
        let before = try SourceSnapshot(fixture.root)
        let control = ScanControl()
        let interrupted = await DuplicateScanner().scan(
            roots: [fixture.root], options: .init(), control: control, sessionURL: fixture.session
        ) { update in
            if update.phase == .discovering { control.cancel() }
        }
        XCTAssertTrue(interrupted.wasCancelled)
        XCTAssertTrue(interrupted.isIncomplete)
        let saved = try ScanSessionStore.load(fixture.session)
        XCTAssertEqual(saved.status, .interrupted)
        XCTAssertGreaterThan(saved.pendingCount, 0)

        let resumed = await DuplicateScanner().scan(
            roots: [fixture.root], options: .init(), sessionURL: fixture.session, resume: true
        ) { _ in }
        XCTAssertFalse(resumed.wasCancelled)
        XCTAssertFalse(resumed.isIncomplete)
        XCTAssertTrue(resumed.errors.isEmpty, resumed.errors.joined(separator: "\n"))
        XCTAssertEqual(resumed.scannedFiles, 16)
        XCTAssertEqual(resumed.groups.count, 4)
        XCTAssertTrue(resumed.groups.allSatisfy { $0.files.count == 4 })
        XCTAssertEqual(resumed.sessionID, saved.id)
        let completed = try ScanSessionStore.load(fixture.session)
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.pendingCount, 0)
        XCTAssertEqual(try SourceSnapshot(fixture.root), before)
    }

    func testCancelledFingerprintPhaseResumesFastCandidateScan() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let payload = Data(repeating: 37, count: 400_001)
        let a = try fixture.write("a.bin", payload)
        let b = try fixture.write("nested/b.bin", payload)
        let before = try SourceSnapshot(fixture.root)
        let control = ScanControl()
        let interrupted = await DuplicateScanner().scan(
            roots: [fixture.root], options: .init(), control: control, sessionURL: fixture.session
        ) { update in
            if update.phase == .fingerprinting { control.cancel() }
        }
        XCTAssertTrue(interrupted.wasCancelled)
        let saved = try ScanSessionStore.load(fixture.session)
        XCTAssertEqual(saved.status, .interrupted)
        XCTAssertEqual(saved.files.count, 2)

        let resumed = await DuplicateScanner().scan(
            roots: [fixture.root], options: .init(), sessionURL: fixture.session, resume: true
        ) { _ in }
        XCTAssertFalse(resumed.isIncomplete)
        XCTAssertTrue(resumed.errors.isEmpty, resumed.errors.joined(separator: "\n"))
        XCTAssertEqual(duplicatePaths(resumed), [Set([a.path, b.path])])
        XCTAssertEqual(resumed.sessionID, saved.id)
        XCTAssertEqual(try SourceSnapshot(fixture.root), before)
    }

    func testCompletedSessionLoadsOfflineWithoutReadingSourceDirectory() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.write("a", Data("offline report".utf8))
        try fixture.write("b", Data("offline report".utf8))
        let result = await DuplicateScanner().scan(
            roots: [fixture.root], options: .init(), sessionURL: fixture.session
        ) { _ in }
        XCTAssertFalse(result.isIncomplete)
        let offline = fixture.parent.appendingPathComponent("source-offline")
        try FileManager.default.moveItem(at: fixture.root, to: offline)
        let before = try SourceSnapshot(offline)

        let loaded = try ScanSessionStore.load(fixture.session)
        let restored = try XCTUnwrap(loaded.result)
        XCTAssertEqual(loaded.status, .completed)
        XCTAssertEqual(restored.scannedFiles, result.scannedFiles)
        XCTAssertEqual(duplicatePaths(restored), duplicatePaths(result))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
        XCTAssertEqual(try SourceSnapshot(offline), before)
    }

    func testImageSignaturesPersistReuseAndInvalidateWhenImageBecomesCorrupt() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let a = fixture.root.appendingPathComponent("image-a.png")
        let b = fixture.root.appendingPathComponent("image-b.tiff")
        try writeImageFixture(to: a)
        try writeImageFixture(to: b, type: "public.tiff")
        // Different container sizes bypass exact-hash candidates, so cache hits below
        // demonstrate image-signature reuse rather than ordinary duplicate hash reuse.
        XCTAssertNotEqual(try FileStamp.read(a).size, try FileStamp.read(b).size)
        let before = try SourceSnapshot(fixture.root)
        let options = ScanOptions(similarImages: true)
        let first = await DuplicateScanner().scan(
            roots: [fixture.root], options: options, sessionURL: fixture.session
        ) { _ in }
        XCTAssertFalse(first.isIncomplete)
        XCTAssertTrue(first.errors.isEmpty, first.errors.joined(separator: "\n"))
        XCTAssertTrue(first.sessionSaved)
        XCTAssertEqual(first.similarImageGroups.count, 1)
        let saved = try ScanSessionStore.load(fixture.session)
        XCTAssertNotNil(saved.files[a.path]?.imageSignature)
        XCTAssertNotNil(saved.files[b.path]?.imageSignature)

        let resumed = await DuplicateScanner().scan(
            roots: [fixture.root], options: options, sessionURL: fixture.session, resume: true
        ) { _ in }
        XCTAssertFalse(resumed.isIncomplete)
        XCTAssertTrue(resumed.sessionSaved)
        XCTAssertTrue(resumed.errors.isEmpty, resumed.errors.joined(separator: "\n"))
        XCTAssertEqual(resumed.similarImageGroups, first.similarImageGroups)
        XCTAssertEqual(first.cacheHits, 0)
        XCTAssertEqual(resumed.cacheHits, 2)
        let reused = try ScanSessionStore.load(fixture.session)
        XCTAssertEqual(reused.files[a.path]?.imageSignature?.hashes, saved.files[a.path]?.imageSignature?.hashes)
        XCTAssertEqual(reused.files[b.path]?.imageSignature?.hashes, saved.files[b.path]?.imageSignature?.hashes)
        XCTAssertEqual(try SourceSnapshot(fixture.root), before)

        try Data("corrupt replacement, not PNG data".utf8).write(to: b)
        let changedBeforeScan = try SourceSnapshot(fixture.root)
        let changed = await DuplicateScanner().scan(
            roots: [fixture.root], options: options, sessionURL: fixture.session, resume: true
        ) { _ in }
        XCTAssertTrue(changed.isIncomplete)
        XCTAssertTrue(changed.sessionSaved)
        XCTAssertFalse(changed.errors.isEmpty)
        XCTAssertTrue(changed.pendingPaths.contains(b.path))
        XCTAssertTrue(changed.similarImageGroups.isEmpty)
        let invalidated = try ScanSessionStore.load(fixture.session)
        XCTAssertEqual(invalidated.status, .needsRetry)
        XCTAssertNil(invalidated.files[b.path]?.imageSignature)
        XCTAssertNotNil(invalidated.files[a.path]?.imageSignature)
        XCTAssertEqual(try SourceSnapshot(fixture.root), changedBeforeScan)
    }

    func testMissingRootCanBeRetriedAfterItBecomesAvailable() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let missing = fixture.root.appendingPathComponent("temporarily-offline")
        var options = ScanOptions(); options.retryCount = 0
        let failed = await DuplicateScanner().scan(
            roots: [missing], options: options, sessionURL: fixture.session
        ) { _ in }
        XCTAssertTrue(failed.isIncomplete)
        XCTAssertFalse(failed.errors.isEmpty)
        let pending = try ScanSessionStore.load(fixture.session)
        XCTAssertEqual(pending.status, .needsRetry)
        XCTAssertGreaterThan(pending.pendingCount, 0)
        XCTAssertTrue(failed.pendingPaths.contains(missing.path))

        let a = try fixture.write("temporarily-offline/a", Data("reconnected".utf8))
        let b = try fixture.write("temporarily-offline/b", Data("reconnected".utf8))
        let before = try SourceSnapshot(fixture.root)
        let recovered = await DuplicateScanner().scan(
            roots: [missing], options: options, sessionURL: fixture.session, resume: true
        ) { _ in }
        XCTAssertFalse(recovered.isIncomplete)
        XCTAssertTrue(recovered.errors.isEmpty, recovered.errors.joined(separator: "\n"))
        XCTAssertTrue(recovered.pendingPaths.isEmpty)
        XCTAssertEqual(duplicatePaths(recovered), [Set([a.path, b.path])])
        XCTAssertEqual(recovered.sessionID, pending.id)
        XCTAssertEqual(try ScanSessionStore.load(fixture.session).status, .completed)
        XCTAssertEqual(try SourceSnapshot(fixture.root), before)
    }

    func testFailedFileReadIsRetriedAfterFileReturns() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let payload = Data(repeating: 29, count: 400_001)
        let a = try fixture.write("a.bin", payload)
        let b = try fixture.write("b.bin", payload)
        let moved = fixture.parent.appendingPathComponent("temporarily-unavailable.bin")
        let mover = OneShotMove(source: b, destination: moved)
        var options = ScanOptions(); options.retryCount = 0
        let failed = await DuplicateScanner().scan(
            roots: [fixture.root], options: options, sessionURL: fixture.session
        ) { update in
            if update.phase == .fingerprinting { mover.perform() }
        }
        XCTAssertTrue(mover.succeeded)
        XCTAssertTrue(failed.isIncomplete)
        XCTAssertTrue(failed.pendingPaths.contains(b.path))
        XCTAssertEqual(try ScanSessionStore.load(fixture.session).status, .needsRetry)
        try FileManager.default.moveItem(at: moved, to: b)
        let before = try SourceSnapshot(fixture.root)

        let recovered = await DuplicateScanner().scan(
            roots: [fixture.root], options: options, sessionURL: fixture.session, resume: true
        ) { _ in }
        XCTAssertFalse(recovered.isIncomplete)
        XCTAssertTrue(recovered.errors.isEmpty, recovered.errors.joined(separator: "\n"))
        XCTAssertEqual(duplicatePaths(recovered), [Set([a.path, b.path])])
        XCTAssertTrue(recovered.pendingPaths.isEmpty)
        XCTAssertEqual(try SourceSnapshot(fixture.root), before)
    }

    func testResumeInvalidatesModifiedDeletedAndNewFilesAndReusesUnchangedHashes() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let oldPayload = Data(repeating: 51, count: 400_001)
        let a = try fixture.write("a.bin", oldPayload)
        let changed = try fixture.write("changed.bin", oldPayload)
        let deleted = try fixture.write("deleted.bin", oldPayload)
        let stableA = try fixture.write("stable/a.bin", Data(repeating: 91, count: 410_003))
        let stableB = try fixture.write("stable/b.bin", Data(repeating: 91, count: 410_003))
        let first = await DuplicateScanner().scan(
            roots: [fixture.root], options: .init(), sessionURL: fixture.session
        ) { _ in }
        XCTAssertEqual(first.groups.count, 2)

        // Keep size and mtime unchanged: the stored ctime must still invalidate this hash.
        let originalDate = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: changed.path))[.modificationDate] as? Date)
        try Data(repeating: 52, count: oldPayload.count).write(to: changed)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: changed.path)
        try FileManager.default.removeItem(at: deleted)
        let added = try fixture.write("new/nested/copy.bin", oldPayload)
        let before = try SourceSnapshot(fixture.root)

        let resumed = await DuplicateScanner().scan(
            roots: [fixture.root], options: .init(), sessionURL: fixture.session, resume: true
        ) { _ in }
        XCTAssertFalse(resumed.isIncomplete)
        XCTAssertTrue(resumed.errors.isEmpty, resumed.errors.joined(separator: "\n"))
        XCTAssertEqual(resumed.scannedFiles, 5)
        XCTAssertEqual(duplicatePaths(resumed), [Set([a.path, added.path]), Set([stableA.path, stableB.path])])
        XCTAssertGreaterThan(resumed.cacheHits, 0)
        let saved = try ScanSessionStore.load(fixture.session)
        XCTAssertNil(saved.files[deleted.path])
        XCTAssertNotNil(saved.files[added.path])
        XCTAssertEqual(saved.id, first.sessionID)
        XCTAssertEqual(try SourceSnapshot(fixture.root), before)
    }

    func testResumeUsesStoredReferenceOptionsAndWithholdsUniqueFilesWhileReferenceIsMissing() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let reference = fixture.root.appendingPathComponent("A")
        let target = fixture.root.appendingPathComponent("B")
        let shared = try fixture.write("B/shared.bin", Data("shared payload".utf8))
        let unique = try fixture.write("B/unique.bin", Data("only in target".utf8))
        var original = ScanOptions()
        original.mode = .reference
        original.referencePaths = [reference.path]
        original.retryCount = 0
        let incomplete = await DuplicateScanner().scan(
            roots: [reference, target], options: original, sessionURL: fixture.session
        ) { _ in }
        XCTAssertTrue(incomplete.isIncomplete)
        XCTAssertTrue(incomplete.uniqueFiles.isEmpty)
        XCTAssertEqual(incomplete.mode, .reference)

        let referenceCopy = try fixture.write("A/shared.bin", Data("shared payload".utf8))
        let before = try SourceSnapshot(fixture.root)
        let unrelated = fixture.parent.appendingPathComponent("must-not-be-scanned")
        let changedOptions = ScanOptions(minimumFileSize: UInt64.max)
        let resumed = await DuplicateScanner().scan(
            roots: [unrelated], options: changedOptions, sessionURL: fixture.session, resume: true
        ) { _ in }
        XCTAssertFalse(resumed.isIncomplete)
        XCTAssertTrue(resumed.errors.isEmpty, resumed.errors.joined(separator: "\n"))
        XCTAssertEqual(resumed.mode, .reference)
        XCTAssertEqual(resumed.referencePaths, [reference.path])
        XCTAssertEqual(resumed.scannedFiles, 3)
        XCTAssertEqual(duplicatePaths(resumed), [Set([referenceCopy.path, shared.path])])
        XCTAssertEqual(Set(resumed.uniqueFiles.map(\.id)), [unique.path])
        XCTAssertEqual(try ScanSessionStore.load(fixture.session).options.minimumFileSize, original.minimumFileSize)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertEqual(try SourceSnapshot(fixture.root), before)
    }

    func testMalformedAndUnsupportedSessionsAreRejected() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.session.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a scan session".utf8).write(to: fixture.session)
        XCTAssertThrowsError(try ScanSessionStore.load(fixture.session))

        let valid = ScanSession(roots: [fixture.root], options: .init())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        object["version"] = 999
        try JSONSerialization.data(withJSONObject: object).write(to: fixture.session)
        XCTAssertThrowsError(try ScanSessionStore.load(fixture.session)) { error in
            guard case ScanSessionStore.StoreError.unsupportedVersion = error else {
                return XCTFail("Expected incompatible session version, got \(error)")
            }
        }
    }

    func testCredentialAndNetworkLoginURLsAreRejectedBeforeSessionUse() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        for raw in ["smb://example.invalid/share", "file://user:secret@localhost/tmp/source", "file://server.invalid/share"] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertThrowsError(try ScanSessionStore.validate(roots: [url], options: .init()))
            let crafted = ScanSession(roots: [url], options: .init())
            try FileManager.default.createDirectory(at: fixture.session.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(crafted).write(to: fixture.session)
            XCTAssertThrowsError(try ScanSessionStore.load(fixture.session))
        }
    }

    func testInvalidResumeDoesNotFallBackToStartingANewScan() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.write("a", Data("must not be silently scanned".utf8))
        try fixture.write("b", Data("must not be silently scanned".utf8))
        try FileManager.default.createDirectory(at: fixture.session.deletingLastPathComponent(), withIntermediateDirectories: true)
        let malformed = Data("invalid saved task".utf8)
        try malformed.write(to: fixture.session)
        let before = try SourceSnapshot(fixture.root)

        let result = await DuplicateScanner().scan(
            roots: [fixture.root], options: .init(), sessionURL: fixture.session, resume: true
        ) { _ in }
        XCTAssertTrue(result.isIncomplete)
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertEqual(result.scannedFiles, 0)
        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.session), malformed)
        XCTAssertEqual(try SourceSnapshot(fixture.root), before)
    }

    func testSessionStorageInsideSourceIsRejectedWithoutWritingAFile() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.write("a", Data("source remains unchanged".utf8))
        let before = try SourceSnapshot(fixture.root)
        let inside = fixture.root.appendingPathComponent("must-not-create/task.mizhong")
        let session = ScanSession(roots: [fixture.root], options: .init())
        XCTAssertThrowsError(try ScanSessionStore.save(session, to: inside)) { error in
            guard case ScanSessionStore.StoreError.storageInsideScan = error else {
                return XCTFail("Expected storage outside source requirement, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: inside.path))
        XCTAssertEqual(try SourceSnapshot(fixture.root), before)
        try ScanSessionStore.save(session, to: fixture.session)
        XCTAssertEqual(try ScanSessionStore.load(fixture.session).id, session.id)
    }

    func testFailedSessionSaveIsReportedWithoutClaimingTaskWasSaved() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.write("a", Data("read-only source".utf8))
        try fixture.write("b", Data("read-only source".utf8))
        let before = try SourceSnapshot(fixture.root)
        let forbidden = fixture.root.appendingPathComponent("must-not-create/task.mizhong")
        let result = await DuplicateScanner().scan(
            roots: [fixture.root], options: .init(), sessionURL: forbidden
        ) { _ in }
        XCTAssertFalse(result.sessionSaved)
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: forbidden.path))
        XCTAssertEqual(try SourceSnapshot(fixture.root), before)
    }
}
