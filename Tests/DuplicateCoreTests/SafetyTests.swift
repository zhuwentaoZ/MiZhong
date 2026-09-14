@testable import DuplicateCore
import Foundation
import XCTest

final class SafetyTests: XCTestCase {
    func testFastCandidateIsFullyVerifiedBeforeAppearingInResults() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var first = Data(repeating: 7, count: 400_000), second = first
        first[100_000] = 1; second[100_000] = 2
        let a = root.appendingPathComponent("candidate-a.bin"), b = root.appendingPathComponent("candidate-b.bin")
        try first.write(to: a); try second.write(to: b)
        let result = await DuplicateScanner().scan(roots: [root], options: .init()) { _ in }
        XCTAssertEqual(result.candidateOnly, false)
        XCTAssertFalse(result.groups.contains { group in
            let paths = Set(group.files.map(\.url.standardizedFileURL.path))
            return paths.contains(a.standardizedFileURL.path) || paths.contains(b.standardizedFileURL.path)
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }
    func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mizhong-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("original bytes".utf8).write(to: root.appendingPathComponent("a"))
        try Data("original bytes".utf8).write(to: root.appendingPathComponent("b"))
        return root
    }
    func testOverlapHardlinksAndSymlinkAreNotCopies() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.linkItem(at: root.appendingPathComponent("a"), to: root.appendingPathComponent("hardlink"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        let r = await DuplicateScanner().scan(roots: [root, root], options: .init()) { _ in }
        XCTAssertEqual(r.scannedFiles, 2); XCTAssertEqual(r.groups.count, 1)
    }
    func testPreflightRejectsUnknownAndLastCopyAndChangedSurvivor() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let r = await DuplicateScanner().scan(roots: [root], options: .init()) { _ in }
        let group = try XCTUnwrap(r.groups.first)
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        XCTAssertThrowsError(try SafeCleaner.validate([a,b], in: group))
        XCTAssertThrowsError(try SafeCleaner.validate([root.appendingPathComponent("outsider")], in: group))
        XCTAssertThrowsError(try SafeCleaner.validate([b], in: group, protectedPaths: [root.path]))
        try SafeCleaner.validate([b], in: group)
        try Data("changed bytes!".utf8).write(to: a)
        XCTAssertThrowsError(try SafeCleaner.validate([b], in: group))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }
    func testCacheInvalidationAndPersistence() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache.json")
        var options = ScanOptions(); options.excludedPaths = [cache.path]
        _ = await DuplicateScanner(cacheURL: cache).scan(roots: [root], options: options) { _ in }
        let warm = await DuplicateScanner(cacheURL: cache).scan(roots: [root], options: options) { _ in }
        XCTAssertGreaterThan(warm.cacheHits, 0)
        try Data("changed bytes!".utf8).write(to: root.appendingPathComponent("b"))
        let changed = await DuplicateScanner(cacheURL: cache).scan(roots: [root], options: options) { _ in }
        XCTAssertTrue(changed.groups.isEmpty)
    }
    func testTrashMovesOnlyGeneratedTemporaryDuplicate() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let r = await DuplicateScanner().scan(roots: [root], options: .init()) { _ in }
        let group = try XCTUnwrap(r.groups.first)
        let victim = group.files[1].url, survivor = group.files[0].url
        let failures = try SafeCleaner.trash([victim], in: group)
        XCTAssertTrue(failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: survivor.path))
    }
    func testCancelledRunAndPauseResume() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let token = ScanControl(); token.pause()
        let task = Task.detached { await DuplicateScanner().scan(roots: [root], options: .init(), control: token) { _ in } }
        try await Task.sleep(for: .milliseconds(50)); token.resume()
        let completed = await task.value; XCTAssertEqual(completed.groups.count, 1)
        let cancelled = ScanControl(); cancelled.cancel()
        let result = await DuplicateScanner().scan(roots: [root], options: .init(), control: cancelled) { _ in }
        XCTAssertTrue(result.wasCancelled); XCTAssertEqual(result.scannedFiles, 0)
    }
    func testExclusionAndExtensionAndMissingRoot() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var options = ScanOptions(); options.excludedPaths = [root.appendingPathComponent("a").path]
        let r = await DuplicateScanner().scan(roots: [root], options: options) { _ in }
        XCTAssertEqual(r.scannedFiles, 1)
        options.extensions = ["jpg"]
        let filtered = await DuplicateScanner().scan(roots: [root], options: options) { _ in }
        XCTAssertEqual(filtered.scannedFiles, 0)
        let missing = await DuplicateScanner().scan(roots: [root.appendingPathComponent("absent")], options: .init()) { _ in }
        XCTAssertFalse(missing.errors.isEmpty)
    }
    func testSimilarityDoesNotChainAndSeparatesSolidImages() {
        let a = FileRecord(url: URL(fileURLWithPath: "/a"), size: 1, modifiedAt: nil, isNetworkVolume: false)
        let b = FileRecord(url: URL(fileURLWithPath: "/b"), size: 1, modifiedAt: nil, isNetworkVolume: false)
        let c = FileRecord(url: URL(fileURLWithPath: "/c"), size: 1, modifiedAt: nil, isNetworkVolume: false)
        let groups = ImageSimilarity.makeGroups([(a,.init(hashes:[0],mean:120,deviation:20)),
             (b,.init(hashes:[15],mean:120,deviation:20)),(c,.init(hashes:[255],mean:120,deviation:20))], threshold: 4)
        XCTAssertEqual(groups.first?.files.count, 2)
        let solids = ImageSimilarity.makeGroups([(a,.init(hashes:[0],mean:0,deviation:0)),
            (b,.init(hashes:[0],mean:255,deviation:0))])
        XCTAssertTrue(solids.isEmpty)
    }
}
