import Foundation
import DuplicateCore

struct EbookFilenameHistory: Codable, Identifiable, Sendable {
    struct EncryptedFile: Codable, Sendable { let path: String; let size: Int64? }
    struct Pair: Codable, Identifiable, Sendable {
        let id: String; let first: String; let second: String; let score: Double
        let firstSize: Int64?; let secondSize: Int64?
        let firstDRM: EbookDRMStatus?; let secondDRM: EbookDRMStatus?
    }
    let id: UUID; let date: Date; let roots: [String]; let fileCount: Int; let duration: Double; let pairs: [Pair]
    let drmCheckedCount: Int?; let drmEncryptedCount: Int?; let drmUnknownCount: Int?
    let encryptedFiles: [EncryptedFile]?
    init(roots: [URL], result: EbookFilenameScanResult) {
        id = UUID(); date = Date(); self.roots = roots.map(\.path); fileCount = result.files.count; duration = result.duration
        drmCheckedCount = result.drmStatuses.values.filter { $0 != .unknown }.count
        drmEncryptedCount = result.drmStatuses.values.filter { $0 == .suspected }.count
        drmUnknownCount = result.drmStatuses.values.filter { $0 == .unknown }.count
        encryptedFiles = result.files.filter { result.drmStatuses[$0.path] == .suspected }
            .map { .init(path: $0.path, size: result.fileSizes[$0.path]) }
        pairs = result.matches.map {
            .init(id: $0.id, first: $0.first.path, second: $0.second.path, score: $0.score,
                  firstSize: result.fileSizes[$0.first.path], secondSize: result.fileSizes[$0.second.path],
                  firstDRM: result.drmStatuses[$0.first.path], secondDRM: result.drmStatuses[$0.second.path])
        }
    }
}

enum EbookFilenameHistoryStore {
    private static var url: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MiZhong/EbookFilenameHistory.json") }
    static func load() -> [EbookFilenameHistory] { (try? loadThrowing()) ?? [] }
    static func loadThrowing() throws -> [EbookFilenameHistory] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([EbookFilenameHistory].self,
                                        from: Data(contentsOf: url, options: [.mappedIfSafe]))
    }
    @discardableResult static func save(_ entry: EbookFilenameHistory) throws -> [EbookFilenameHistory] {
        let existing: [EbookFilenameHistory]
        if FileManager.default.fileExists(atPath: url.path) {
            existing = try JSONDecoder().decode([EbookFilenameHistory].self, from: Data(contentsOf: url))
        } else { existing = [] }
        var entries = existing; entries.insert(entry, at: 0); entries = Array(entries.prefix(30))
        try write(entries)
        return entries
    }
    @discardableResult static func delete(_ id: UUID) throws -> [EbookFilenameHistory] {
        let entries = load().filter { $0.id != id }
        try write(entries)
        return entries
    }
    private static func write(_ entries: [EbookFilenameHistory]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
