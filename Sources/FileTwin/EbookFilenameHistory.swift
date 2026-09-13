import Foundation
import DuplicateCore

struct EbookFilenameHistory: Codable, Identifiable {
    struct Pair: Codable, Identifiable { let id: String; let first: String; let second: String; let score: Double }
    let id: UUID; let date: Date; let roots: [String]; let fileCount: Int; let duration: Double; let pairs: [Pair]
    init(roots: [URL], result: EbookFilenameScanResult) {
        id = UUID(); date = Date(); self.roots = roots.map(\.path); fileCount = result.files.count; duration = result.duration
        pairs = result.matches.map { .init(id: $0.id, first: $0.first.path, second: $0.second.path, score: $0.score) }
    }
}

enum EbookFilenameHistoryStore {
    private static var url: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MiZhong/EbookFilenameHistory.json") }
    static func load() -> [EbookFilenameHistory] { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([EbookFilenameHistory].self, from: $0) } ?? [] }
    static func save(_ entry: EbookFilenameHistory) {
        var entries = load(); entries.insert(entry, at: 0); entries = Array(entries.prefix(30))
        write(entries)
    }
    static func delete(_ id: UUID) {
        write(load().filter { $0.id != id })
    }
    private static func write(_ entries: [EbookFilenameHistory]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: url, options: .atomic) }
    }
}
