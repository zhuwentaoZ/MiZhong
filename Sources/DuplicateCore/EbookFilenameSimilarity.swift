import Foundation

public struct EbookFilenameMatch: Identifiable, Hashable, Sendable {
    public let id: String
    public let first: URL
    public let second: URL
    public let score: Double
    public init(first: URL, second: URL, score: Double) {
        self.first = first; self.second = second; self.score = score
        self.id = [first.path, second.path].sorted().joined(separator: "|")
    }
}

public struct EbookFilenameScanResult: Sendable {
    public let files: [URL]
    public let matches: [EbookFilenameMatch]
    public let errors: [String]
    public let duration: TimeInterval
    public init(files: [URL], matches: [EbookFilenameMatch], errors: [String], duration: TimeInterval) {
        self.files = files
        self.matches = matches
        self.errors = errors
        self.duration = duration
    }
}

public enum EbookFilenameScanner {
    public static func scan(roots: [URL], recursive: Bool, minimum: Double,
                            progress: @escaping @Sendable (Int, Int, String, String) -> Void) async -> EbookFilenameScanResult {
        let started = Date()
        let discoveryTask = Task.detached(priority: .utility) { discover(roots: roots, recursive: recursive, progress: progress) }
        let discovery = await withTaskCancellationHandler(operation: { await discoveryTask.value }, onCancel: { discoveryTask.cancel() })
        guard !Task.isCancelled else { return .init(files: discovery.0, matches: [], errors: discovery.1, duration: Date().timeIntervalSince(started)) }
        progress(discovery.0.count, discovery.2, "正在建立文件名索引", "索引")
        let comparisonTask = Task.detached(priority: .utility) { EbookFilenameSimilarity.compare(discovery.0, minimum: minimum) }
        let matches = await withTaskCancellationHandler(operation: { await comparisonTask.value }, onCancel: { comparisonTask.cancel() })
        return .init(files: discovery.0, matches: matches, errors: discovery.1, duration: Date().timeIntervalSince(started))
    }

    private static func discover(roots: [URL], recursive: Bool, progress: @escaping @Sendable (Int, Int, String, String) -> Void) -> ([URL], [String], Int) {
        var files: [URL] = [], errors: [String] = [], visited = 0
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: recursive ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { errors.append("无法读取：\(root.path)"); continue }
            while let item = enumerator.nextObject() as? URL {
                if Task.isCancelled { return (files, errors, visited) }
                visited += 1
                if EbookFilenameSimilarity.extensions.contains(item.pathExtension.lowercased()) { files.append(item) }
                if visited == 1 || visited.isMultiple(of: 100) { progress(files.count, visited, item.path, "枚举") }
            }
        }
        progress(files.count, visited, files.last?.path ?? "未发现支持的电子书", "枚举完成")
        return (files, errors, visited)
    }
}

public enum EbookFilenameSimilarity {
    public static let extensions: Set<String> = ["pdf", "epub", "mobi", "azw3"]

    /// Uses an inverted trigram index instead of comparing every pair. Generic grams are
    /// discarded to prevent a common prefix from producing millions of candidates.
    public static func compare(_ urls: [URL], minimum: Double = 0.55) -> [EbookFilenameMatch] {
        let items = urls.map { ($0, normalized($0)) }.filter { !$0.1.isEmpty }
        let gramSets = items.map { grams($0.1) }
        var buckets: [String: [Int]] = [:]
        for (index, set) in gramSets.enumerated() { if Task.isCancelled { return [] }; for gram in set { buckets[gram, default: []].append(index) } }

        var candidates: Set<UInt64> = []
        for indices in buckets.values where indices.count > 1 && indices.count <= 256 {
            if Task.isCancelled { return [] }
            for a in indices.indices { for b in indices.indices where b > a {
                candidates.insert(UInt64(indices[a]) << 32 | UInt64(indices[b]))
            }}
        }
        var exact: [String: [Int]] = [:]
        for (index, item) in items.enumerated() { exact[item.1, default: []].append(index) }
        for indices in exact.values where indices.count > 1 {
            for a in indices.indices { for b in indices.indices where b > a {
                candidates.insert(UInt64(indices[a]) << 32 | UInt64(indices[b]))
            }}
        }

        var result: [EbookFilenameMatch] = []
        result.reserveCapacity(min(candidates.count, 10_000))
        for pair in candidates {
            if Task.isCancelled { return [] }
            let i = Int(pair >> 32), j = Int(pair & 0xffff_ffff)
            let union = gramSets[i].union(gramSets[j]).count
            guard union > 0 else { continue }
            let score = Double(gramSets[i].intersection(gramSets[j]).count) / Double(union)
            if score >= minimum { result.append(.init(first: items[i].0, second: items[j].0, score: score)) }
        }
        return result.sorted { $0.score == $1.score ? $0.first.path < $1.first.path : $0.score > $1.score }
    }

    private static func normalized(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.precomposedStringWithCompatibilityMapping.lowercased()
            .replacingOccurrences(of: #"(?i)(\s*[-_ ]?(copy|副本|重复|备份|\(\d+\)|（\d+）))+$"#, with: "", options: .regularExpression)
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }
    private static func grams(_ value: String) -> Set<String> {
        let chars = Array(value)
        guard chars.count >= 3 else { return value.isEmpty ? [] : [value] }
        return Set((0...(chars.count - 3)).map { String(chars[$0..<$0 + 3]) })
    }
}
