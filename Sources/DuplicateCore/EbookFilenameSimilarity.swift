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

public struct EbookFilenameGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let files: [URL]
    public let matches: [EbookFilenameMatch]
    public var highestScore: Double { matches.first?.score ?? 0 }

    public init(files: [URL], matches: [EbookFilenameMatch]) {
        self.files = files.sorted { $0.path < $1.path }
        self.matches = matches.sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
        id = self.files.map(\.path).joined(separator: "|")
    }

    /// Estimated duplicate bytes when the largest file in this candidate group is kept.
    /// Returns nil when an older history entry has no size for one or more members.
    public func duplicateBytes(fileSizes: [String: Int64]) -> Int64? {
        let sizes = files.compactMap { fileSizes[$0.path] }
        guard sizes.count == files.count, let largest = sizes.max() else { return nil }
        return sizes.reduce(0, +) - largest
    }
}

public enum EbookDRMStatus: String, Codable, Sendable {
    case suspected, notDetected, unknown
}

public struct EbookFilenameScanResult: Sendable {
    public let files: [URL]
    public let matches: [EbookFilenameMatch]
    public let errors: [String]
    public let duration: TimeInterval
    public let drmStatuses: [String: EbookDRMStatus]
    public let fileSizes: [String: Int64]
    public init(files: [URL], matches: [EbookFilenameMatch], errors: [String], duration: TimeInterval,
                drmStatuses: [String: EbookDRMStatus] = [:], fileSizes: [String: Int64] = [:]) {
        self.files = files
        self.matches = matches
        self.errors = errors
        self.duration = duration
        self.drmStatuses = drmStatuses
        self.fileSizes = fileSizes
    }
}

public enum EbookFilenameScanner {
    public static func scan(roots: [URL], recursive: Bool, minimum: Double, quickDRMCheck: Bool = false,
                            progress: @escaping @Sendable (Int, Int, String, String) -> Void) async -> EbookFilenameScanResult {
        let started = Date()
        let discoveryTask = Task.detached(priority: .utility) { discover(roots: roots, recursive: recursive, progress: progress) }
        let discovery = await withTaskCancellationHandler(operation: { await discoveryTask.value }, onCancel: { discoveryTask.cancel() })
        guard !Task.isCancelled else { return .init(files: discovery.files, matches: [], errors: discovery.errors, duration: Date().timeIntervalSince(started), fileSizes: discovery.sizes) }
        var drmStatuses: [String: EbookDRMStatus] = [:]
        if quickDRMCheck {
            let drmFiles = discovery.files.filter { ["mobi", "azw", "azw3"].contains($0.pathExtension.lowercased()) }
            await withTaskGroup(of: (URL, EbookDRMStatus).self) { group in
                var next = 0, done = 0
                func submit(_ url: URL) { group.addTask { (url, EbookDRMDetector.check(url)) } }
                while next < min(2, drmFiles.count) { submit(drmFiles[next]); next += 1 }
                while let (url, status) = await group.next() {
                    drmStatuses[url.path] = status; done += 1
                    if done == 1 || done.isMultiple(of: 25) { progress(drmFiles.count, done, url.path, "DRM") }
                    if next < drmFiles.count && !Task.isCancelled { submit(drmFiles[next]); next += 1 }
                }
            }
        }
        progress(discovery.files.count, 0, "正在建立文件名索引", "索引")
        let comparisonTask = Task.detached(priority: .utility) {
            EbookFilenameSimilarity.compare(discovery.files, minimum: minimum, fileSizes: discovery.sizes) { done, path in
                progress(discovery.files.count, done, path, "索引")
            }
        }
        let matches = await withTaskCancellationHandler(operation: { await comparisonTask.value }, onCancel: { comparisonTask.cancel() })
        progress(discovery.files.count, discovery.files.count, "正在整理结果", "完成")
        return .init(files: discovery.files, matches: matches, errors: discovery.errors, duration: Date().timeIntervalSince(started), drmStatuses: drmStatuses, fileSizes: discovery.sizes)
    }

    private static func discover(roots: [URL], recursive: Bool, progress: @escaping @Sendable (Int, Int, String, String) -> Void) -> (files: [URL], errors: [String], visited: Int, sizes: [String: Int64]) {
        var files: [URL] = [], errors: [String] = [], visited = 0, sizes: [String: Int64] = [:]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: recursive ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { errors.append("无法读取：\(root.path)"); continue }
            while let item = enumerator.nextObject() as? URL {
                if Task.isCancelled { return (files, errors, visited, sizes) }
                visited += 1
                if EbookFilenameSimilarity.extensions.contains(item.pathExtension.lowercased()) {
                    files.append(item)
                    if let size = try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize { sizes[item.path] = Int64(size) }
                }
                if visited == 1 || visited.isMultiple(of: 100) { progress(files.count, visited, item.path, "枚举") }
            }
        }
        progress(files.count, visited, files.last?.path ?? "未发现支持的电子书", "枚举完成")
        return (files, errors, visited, sizes)
    }
}

public enum EbookDRMDetector {
    public static func check(_ url: URL) -> EbookDRMStatus {
        do {
            switch url.pathExtension.lowercased() {
            case "mobi", "azw", "azw3":
                let data = try prefixData(url, byteCount: 96)
                guard data.count >= 94 else { return .unknown }
                let firstRecord = Int(be32(data, 78))
                let header = try rangeData(url, offset: UInt64(firstRecord), byteCount: 16)
                guard header.count >= 14 else { return .unknown }
                return be16(header, 12) == 0 ? .notDetected : .suspected
            default: return .unknown
            }
        } catch { return .unknown }
    }

    private static func prefixData(_ url: URL, byteCount: Int) throws -> Data { try rangeData(url, offset: 0, byteCount: byteCount) }
    private static func rangeData(_ url: URL, offset: UInt64, byteCount: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: byteCount) ?? Data()
    }
    private static func be16(_ data: Data, _ offset: Int) -> UInt16 { (UInt16(data[offset]) << 8) | UInt16(data[offset + 1]) }
    private static func be32(_ data: Data, _ offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16) | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    }
}

public enum EbookFilenameSimilarity {
    public static let extensions: Set<String> = ["pdf", "epub", "mobi", "azw", "azw3"]

    /// Threshold-aware prefix filtering keeps every pair that can reach the requested
    /// Jaccard score while avoiding the candidate explosion caused by common title grams.
    public static func compare(_ urls: [URL], minimum: Double = 0.55, fileSizes: [String: Int64] = [:],
                               progress: (@Sendable (Int, String) -> Void)? = nil) -> [EbookFilenameMatch] {
        let items = urls.map { ($0, normalized($0)) }.filter { !$0.1.isEmpty }
        let gramSets = items.map { grams($0.1) }
        var frequencies: [String: Int] = [:]
        for set in gramSets { for gram in set { frequencies[gram, default: 0] += 1 } }
        let orderedGrams = gramSets.map { set in
            set.sorted { (frequencies[$0] ?? 0, $0) < (frequencies[$1] ?? 0, $1) }
        }
        var prefixBuckets: [String: [Int]] = [:]
        var candidates: Set<UInt64> = []
        for index in items.indices {
            if Task.isCancelled { return [] }
            let count = gramSets[index].count
            let prefixCount = max(1, count - Int(ceil(minimum * Double(count))) + 1)
            for gram in orderedGrams[index].prefix(prefixCount) {
                for other in prefixBuckets[gram] ?? [] {
                    let otherCount = gramSets[other].count
                    guard Double(min(count, otherCount)) / Double(max(count, otherCount)) >= minimum else { continue }
                    candidates.insert(UInt64(other) << 32 | UInt64(index))
                }
                prefixBuckets[gram, default: []].append(index)
            }
            if index == 0 || index.isMultiple(of: 100) { progress?(index + 1, items[index].0.path) }
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
        for (position, pair) in candidates.enumerated() {
            if Task.isCancelled { return [] }
            let i = Int(pair >> 32), j = Int(pair & 0xffff_ffff)
            let union = gramSets[i].union(gramSets[j]).count
            guard union > 0 else { continue }
            let score = Double(gramSets[i].intersection(gramSets[j]).count) / Double(union)
            if score >= minimum {
                if minimum >= 0.85 {
                    guard let firstSize = fileSizes[items[i].0.path], let secondSize = fileSizes[items[j].0.path] else { continue }
                    let larger = max(firstSize, secondSize)
                    let sizeRatio = larger == 0 ? 1 : Double(min(firstSize, secondSize)) / Double(larger)
                    guard sizeRatio >= 0.60 else { continue }
                }
                result.append(.init(first: items[i].0, second: items[j].0, score: score))
            }
            if position.isMultiple(of: 500) { progress?(items.count, "正在比较候选 \(position + 1)/\(candidates.count)") }
        }
        // The UI performs the single final size/score sort off the main actor.
        return result
    }

    /// Merge overlapping pair matches into stable candidate groups. Pair evidence is
    /// retained so transitive members are not presented as a directly verified pair.
    public static func groups(from matches: [EbookFilenameMatch]) -> [EbookFilenameGroup] {
        var parent: [String: String] = [:]
        var urls: [String: URL] = [:]
        func root(_ path: String, in parents: inout [String: String]) -> String {
            var current = path
            while let next = parents[current], next != current { current = next }
            var node = path
            while let next = parents[node], next != current { parents[node] = current; node = next }
            return current
        }
        for match in matches {
            let a = match.first.path, b = match.second.path
            urls[a] = match.first; urls[b] = match.second
            if parent[a] == nil { parent[a] = a }
            if parent[b] == nil { parent[b] = b }
            let ra = root(a, in: &parent), rb = root(b, in: &parent)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }
        var matchesByRoot: [String: [EbookFilenameMatch]] = [:]
        for match in matches { matchesByRoot[root(match.first.path, in: &parent), default: []].append(match) }
        return matchesByRoot.map { key, componentMatches in
            let paths = Set(componentMatches.flatMap { [$0.first.path, $0.second.path] })
            return EbookFilenameGroup(files: paths.compactMap { urls[$0] }, matches: componentMatches)
        }.sorted { $0.id < $1.id }
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
