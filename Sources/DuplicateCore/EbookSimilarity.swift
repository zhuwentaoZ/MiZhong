import Foundation
import PDFKit

public enum EbookFormat: String, Codable, CaseIterable, Sendable {
    case pdf, epub, mobi, azw, azw3
}

public enum EbookExtractionState: String, Codable, Sendable {
    case ready, tooShort, scannedPDF, encrypted, unsupported, failed
}

public struct EbookDocument: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let url: URL
    public let format: EbookFormat
    public let title: String
    public let text: String
    public let characterCount: Int
    public let state: EbookExtractionState
    public let detail: String
    public var fileSize: UInt64?

    public init(url: URL, format: EbookFormat, title: String, text: String,
                state: EbookExtractionState = .ready, detail: String = "", fileSize: UInt64? = nil) {
        self.id = url.path
        self.url = url
        self.format = format
        self.title = title
        self.text = text
        self.characterCount = text.count
        self.state = state
        self.detail = detail
        self.fileSize = fileSize
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public struct EbookMatch: Identifiable, Hashable, Sendable {
    public let id: String
    public let first: EbookDocument
    public let second: EbookDocument
    public let similarity: Double
    public let firstCoverage: Double
    public let secondCoverage: Double
    public let evidence: [String]

    public init(first: EbookDocument, second: EbookDocument, similarity: Double,
                firstCoverage: Double, secondCoverage: Double, evidence: [String]) {
        self.id = [first.id, second.id].sorted().joined(separator: "|")
        self.first = first; self.second = second; self.similarity = similarity
        self.firstCoverage = firstCoverage; self.secondCoverage = secondCoverage; self.evidence = evidence
    }

    public var classification: String {
        if similarity >= 0.82 && min(firstCoverage, secondCoverage) >= 0.72 { return "高度一致" }
        if similarity >= 0.58 { return "较多重合" }
        return "局部重合"
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public struct EbookScanResult: Sendable {
    public let documents: [EbookDocument]
    public let matches: [EbookMatch]
    public let errors: [String]
    public let duration: TimeInterval
}

public enum EbookSimilarityLevel: String, CaseIterable, Sendable {
    case strict, standard, loose
    public var minimumScore: Double { switch self { case .strict: 0.72; case .standard: 0.48; case .loose: 0.28 } }
}

public enum EbookExtractor {
    public static func format(for url: URL) -> EbookFormat? { EbookFormat(rawValue: url.pathExtension.lowercased()) }

    public static func extract(_ url: URL) -> EbookDocument {
        guard let format = format(for: url) else {
            return EbookDocument(url: url, format: .pdf, title: url.deletingPathExtension().lastPathComponent,
                                 text: "", state: .unsupported, detail: "不支持的文件格式")
        }
        do {
            let raw: String
            switch format {
            case .pdf: return extractPDF(url)
            case .epub: raw = try extractEPUB(url)
            case .mobi, .azw, .azw3: raw = try extractMOBI(url)
            }
            let text = normalize(raw)
            let state: EbookExtractionState = text.count >= 200 ? .ready : .tooShort
            return EbookDocument(url: url, format: format, title: title(from: text, fallback: url), text: text,
                                 state: state, detail: state == .ready ? "正文已提取" : "可用正文过少，未参与比较")
        } catch {
            return EbookDocument(url: url, format: format, title: url.deletingPathExtension().lastPathComponent,
                                 text: "", state: .failed, detail: error.localizedDescription)
        }
    }

    private static func extractPDF(_ url: URL) -> EbookDocument {
        guard let document = PDFDocument(url: url) else {
            return EbookDocument(url: url, format: .pdf, title: url.deletingPathExtension().lastPathComponent,
                                 text: "", state: .failed, detail: "无法打开 PDF")
        }
        if document.isEncrypted && document.isLocked {
            return EbookDocument(url: url, format: .pdf, title: url.deletingPathExtension().lastPathComponent,
                                 text: "", state: .encrypted, detail: "PDF 已加密；觅重不会请求或保存密码")
        }
        var pages: [String] = []
        pages.reserveCapacity(document.pageCount)
        for index in 0..<document.pageCount {
            if let value = document.page(at: index)?.string, !value.isEmpty { pages.append(value) }
        }
        let text = normalize(pages.joined(separator: "\n"))
        let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        if text.count < 200 {
            return EbookDocument(url: url, format: .pdf, title: title ?? url.deletingPathExtension().lastPathComponent,
                                 text: text, state: .scannedPDF, detail: "未提取到足够文字，可能是扫描版 PDF")
        }
        return EbookDocument(url: url, format: .pdf, title: title ?? Self.title(from: text, fallback: url),
                             text: text, detail: "已提取 \(document.pageCount) 页文字")
    }

    private static func extractEPUB(_ url: URL) throws -> String {
        let entries = try runUnzip(["-Z1", url.path]).split(separator: "\n").map(String.init)
        let fallbackEntries = entries.filter {
            let lower = $0.lowercased()
            return lower.hasSuffix(".xhtml") || lower.hasSuffix(".html") || lower.hasSuffix(".htm")
        }
        var contentEntries: [String] = []
        if entries.contains("META-INF/container.xml"),
           let packagePath = firstCapture(try runUnzip(["-p", url.path, "META-INF/container.xml"]), pattern: #"full-path\s*=\s*["']([^"']+)["']"#),
           entries.contains(packagePath) {
            let package = try runUnzip(["-p", url.path, packagePath])
            let base = (packagePath as NSString).deletingLastPathComponent
            var manifest: [String: String] = [:]
            for match in captures(package, pattern: #"<item\b[^>]*\bid\s*=\s*["']([^"']+)["'][^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*/?>"#) {
                manifest[match[0]] = match[1]
            }
            // Some generators place href before id.
            for match in captures(package, pattern: #"<item\b[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*\bid\s*=\s*["']([^"']+)["'][^>]*/?>"#) {
                manifest[match[1]] = match[0]
            }
            let order = captures(package, pattern: #"<itemref\b[^>]*\bidref\s*=\s*["']([^"']+)["'][^>]*/?>"#).compactMap(\.first)
            contentEntries = order.compactMap { manifest[$0] }.map { href in
                let decoded = href.removingPercentEncoding ?? href
                return base.isEmpty ? decoded : (base as NSString).appendingPathComponent(decoded)
            }.filter { entries.contains($0) && !$0.hasPrefix("/") && !$0.contains("../") }
        }
        if contentEntries.isEmpty { contentEntries = fallbackEntries }
        guard !contentEntries.isEmpty else { throw ExtractionError("EPUB 中没有可读的正文页面") }
        var output: [String] = []
        for entry in contentEntries.prefix(10_000) {
            guard !entry.hasPrefix("/"), !entry.contains("../") else { continue }
            output.append(stripMarkup(try runUnzip(["-p", url.path, entry])))
        }
        return output.joined(separator: "\n")
    }

    private static func runUnzip(_ arguments: [String]) throws -> String {
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); task.arguments = arguments
        let output = Pipe(), errors = Pipe(); task.standardOutput = output; task.standardError = errors
        try task.run(); task.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard task.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ExtractionError(message.isEmpty ? "无法读取 EPUB 容器" : message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: data, as: UTF8.self)
    }

    // Lightweight PalmDOC reader. Uncompressed and PalmDOC-compressed MOBI/KF8 are supported.
    private static func extractMOBI(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count > 86 else { throw ExtractionError("文件过短，无法识别 MOBI/AZW3") }
        let recordCount = Int(be16(data, 76))
        guard recordCount > 1, data.count >= 78 + recordCount * 8 else { throw ExtractionError("Palm 数据库目录损坏") }
        var offsets: [Int] = []
        for index in 0..<recordCount { offsets.append(Int(be32(data, 78 + index * 8))) }
        offsets.append(data.count)
        guard offsets[0] + 16 <= data.count else { throw ExtractionError("MOBI 头损坏") }
        let compression = Int(be16(data, offsets[0]))
        let textRecords = min(Int(be16(data, offsets[0] + 8)), recordCount - 1)
        guard compression == 1 || compression == 2 else {
            throw ExtractionError(compression == 17480 ? "该电子书使用 HUFF/CDIC 压缩，当前轻量解析器暂不支持" : "不支持的 MOBI 压缩方式（\(compression)）")
        }
        var bytes: [UInt8] = []
        for index in 1...textRecords {
            let start = offsets[index], end = offsets[index + 1]
            guard start >= 0, end >= start, end <= data.count else { continue }
            let record = [UInt8](data[start..<end])
            bytes.append(contentsOf: compression == 2 ? palmDocDecompress(record) : record)
        }
        let decoded = String(data: Data(bytes), encoding: .utf8)
            ?? String(data: Data(bytes), encoding: .windowsCP1252)
            ?? String(decoding: bytes, as: UTF8.self)
        return stripMarkup(decoded)
    }

    private static func palmDocDecompress(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [], index = 0
        while index < input.count {
            let byte = input[index]; index += 1
            if byte == 0 || (byte >= 9 && byte <= 0x7f) { out.append(byte) }
            else if byte <= 8 {
                let count = min(Int(byte), input.count - index); out.append(contentsOf: input[index..<(index + count)]); index += count
            } else if byte >= 0xc0 { out.append(0x20); out.append(byte ^ 0x80) }
            else if index < input.count {
                let pair = (Int(byte) << 8) | Int(input[index]); index += 1
                let distance = (pair >> 3) & 0x7ff, count = (pair & 7) + 3
                if distance > 0 && distance <= out.count { for _ in 0..<count { out.append(out[out.count - distance]) } }
            }
        }
        return out
    }

    private static func be16(_ data: Data, _ offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }
    private static func be32(_ data: Data, _ offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16) | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    }
    private static func stripMarkup(_ value: String) -> String {
        value.replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
    private static func firstCapture(_ value: String, pattern: String) -> String? { captures(value, pattern: pattern).first?.first }
    private static func captures(_ value: String, pattern: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).map { match in
            (1..<match.numberOfRanges).compactMap { index in
                Range(match.range(at: index), in: value).map { String(value[$0]) }
            }
        }
    }
    public static func normalize(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "(?m)^\\s*\\d{1,5}\\s*$", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[\\s\\p{Z}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func title(from text: String, fallback: URL) -> String {
        let first = text.split(separator: "\n", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces)
        return (first?.count ?? 0) >= 2 && (first?.count ?? 0) <= 100 ? first! : fallback.deletingPathExtension().lastPathComponent
    }
    private struct ExtractionError: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
}

public enum EbookSimilarityEngine {
    public static func compare(_ documents: [EbookDocument], level: EbookSimilarityLevel = .standard,
                               filenamePrefilter: Bool = true) -> [EbookMatch] {
        let usable = documents.filter { $0.state == .ready }
        var matches: [EbookMatch] = []
        let pairs: [(Int, Int)]
        if filenamePrefilter && usable.count > 200 {
            pairs = filenameCandidatePairs(usable: usable, level: level)
        } else {
            pairs = usable.count > 200 ? allPairs(usable.count) : candidatePairs(usable: usable)
        }
        let involved = Set(pairs.flatMap { [$0.0, $0.1] })
        let signatures = Dictionary(uniqueKeysWithValues: involved.map { index in
            (usable[index].id, shingles(usable[index].text))
        })
        for (i, j) in pairs {
                let a = signatures[usable[i].id] ?? [], b = signatures[usable[j].id] ?? []
                guard !a.isEmpty, !b.isEmpty else { continue }
                let common = a.intersection(b), coverA = Double(common.count) / Double(a.count), coverB = Double(common.count) / Double(b.count)
                let harmonic = 2 * coverA * coverB / max(0.0001, coverA + coverB)
                let containment = max(coverA, coverB)
                let score = 0.72 * harmonic + 0.28 * containment
                guard score >= level.minimumScore else { continue }
                let evidence = matchingExcerpts(usable[i].text, usable[j].text)
                matches.append(EbookMatch(first: usable[i], second: usable[j], similarity: score,
                                          firstCoverage: coverA, secondCoverage: coverB, evidence: evidence))
        }
        return matches.sorted { $0.similarity > $1.similarity }
    }

    private static func filenameCandidatePairs(usable: [EbookDocument], level: EbookSimilarityLevel) -> [(Int, Int)] {
        // Index normalized filename trigrams first. Only books sharing a meaningful name
        // bucket enter the expensive正文 fingerprint stage. This is intentionally a
        // conservative performance mode for large libraries; small libraries remain exhaustive.
        var buckets: [String: [Int]] = [:]
        for (index, book) in usable.enumerated() {
            let grams = nameGrams(book.url.deletingPathExtension().lastPathComponent)
            for gram in grams { buckets[gram, default: []].append(index) }
        }
        var encoded: Set<Int> = []
        let minimum = level == .strict ? 0.55 : level == .standard ? 0.42 : 0.30
        var seenPairCount: [Int: Int] = [:]
        for indices in buckets.values {
            // Very generic names (e.g. “新建文档”) are not useful candidates and can create
            // millions of pairs. They are handled by exact normalized-name buckets below.
            guard indices.count > 1, indices.count <= 300 else { continue }
            for left in indices.indices {
                for right in indices.indices where right > left {
                    let i = indices[left], j = indices[right]
                    let similarity = nameSimilarity(usable[i], usable[j])
                    if similarity >= minimum {
                        let key = min(i, j) * usable.count + max(i, j)
                        encoded.insert(key); seenPairCount[key, default: 0] += 1
                    }
                }
            }
        }
        // Exact normalized names are always retained, including generic names; cap only
        // pathological all-identical libraries to keep the UI responsive.
        var exact: [String: [Int]] = [:]
        for (index, book) in usable.enumerated() { exact[normalizedName(book.url), default: []].append(index) }
        for indices in exact.values where indices.count > 1 {
            let cap = min(indices.count, 300)
            for left in 0..<cap { for right in (left + 1)..<cap {
                encoded.insert(indices[left] * usable.count + indices[right])
            }}
        }
        return encoded.sorted().map { ($0 / usable.count, $0 % usable.count) }
    }

    private static func normalizedName(_ url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        name = name.replacingOccurrences(of: #"(?i)(\s*[-_ ]?(copy|副本|重复|备份|\(\d+\)|（\d+）))+$"#, with: "", options: .regularExpression)
        return name.precomposedStringWithCompatibilityMapping.lowercased()
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }
    private static func nameGrams(_ name: String) -> Set<String> {
        let compact = normalizedName(URL(fileURLWithPath: name))
        let chars = Array(compact), width = 3
        guard chars.count >= width else { return compact.isEmpty ? [] : [compact] }
        return Set((0...(chars.count - width)).map { String(chars[$0..<$0 + width]) })
    }
    private static func nameSimilarity(_ first: EbookDocument, _ second: EbookDocument) -> Double {
        let a = nameGrams(first.url.deletingPathExtension().lastPathComponent)
        let b = nameGrams(second.url.deletingPathExtension().lastPathComponent)
        guard !a.isEmpty && !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    private static func candidatePairs(usable: [EbookDocument]) -> [(Int, Int)] {
        allPairs(usable.count)
    }
    private static func allPairs(_ count: Int) -> [(Int, Int)] {
        (0..<count).flatMap { i in ((i + 1)..<count).map { (i, $0) } }
    }
    private static func jIsAfter(_ i: Int, _ j: Int) -> Bool { j > i }

    private static func shingles(_ text: String) -> Set<UInt64> {
        // Rolling hashes plus winnowing keep a stable, bounded fingerprint even when a
        // chapter is moved or extracted from a larger edition. This avoids allocating an
        // Array<Character> proportional to the entire book and avoids positional sampling.
        let width = 18, window = 48, base: UInt64 = 1_099_511_628_211
        var power: UInt64 = 1
        for _ in 1..<width { power &*= base }
        var ring = [UInt64](repeating: 0, count: width), ringIndex = 0, filled = 0
        var rolling: UInt64 = 0, shingleIndex = 0
        var deque: [(Int, UInt64)] = [], dequeHead = 0
        var result: Set<UInt64> = []
        for scalar in text.lowercased().unicodeScalars {
            guard !CharacterSet.whitespacesAndNewlines.contains(scalar),
                  !CharacterSet.punctuationCharacters.contains(scalar) else { continue }
            let value = UInt64(scalar.value) &+ 1
            if filled < width {
                ring[filled] = value; rolling = rolling &* base &+ value; filled += 1
                if filled < width { continue }
            } else {
                let outgoing = ring[ringIndex]; ring[ringIndex] = value; ringIndex = (ringIndex + 1) % width
                rolling = (rolling &- outgoing &* power) &* base &+ value
            }
            while deque.count > dequeHead, deque.last!.1 >= rolling { deque.removeLast() }
            deque.append((shingleIndex, rolling))
            while deque.count > dequeHead, deque[dequeHead].0 <= shingleIndex - window { dequeHead += 1 }
            if shingleIndex >= window - 1, let minimum = deque.dropFirst(dequeHead).first?.1 { result.insert(minimum) }
            if dequeHead > 256 { deque.removeFirst(dequeHead); dequeHead = 0 }
            shingleIndex += 1
        }
        if result.isEmpty, filled == width { result.insert(rolling) }
        return result
    }

    private static func matchingExcerpts(_ first: String, _ second: String) -> [String] {
        let chunks = first.split(separator: "。", omittingEmptySubsequences: true)
        var found: [String] = []
        for chunk in chunks where chunk.count >= 24 {
            let excerpt = String(chunk.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
            if second.localizedCaseInsensitiveContains(excerpt), !found.contains(excerpt) { found.append(excerpt) }
            if found.count == 3 { break }
        }
        return found
    }
}

public struct EbookScanner: Sendable {
    private struct Source: Sendable { let url: URL; let isNetwork: Bool; let size: UInt64; let modifiedAt: Date? }
    private let cacheDirectory: URL?
    public init(cacheDirectory: URL? = nil) { self.cacheDirectory = cacheDirectory }
    public func scan(roots: [URL], recursive: Bool = true, level: EbookSimilarityLevel = .standard,
                     filenamePrefilter: Bool = true,
                     progress: @escaping @Sendable (Int, String) -> Void = { _, _ in }) async -> EbookScanResult {
        let started = Date()
        let discovered = await Task.detached(priority: .utility) { Self.discover(roots: roots, recursive: recursive) }.value
        let sources = discovered.0
        let usableCacheDirectory = cacheDirectory.flatMap { EbookTextCache.isSafeLocal($0) ? $0 : nil }
        var errors = discovered.1
        var ordered = [EbookDocument?](repeating: nil, count: sources.count), processed = 0
        for network in [false, true] where !Task.isCancelled {
            let batch = sources.enumerated().filter { $0.element.isNetwork == network }
            let limit = network ? 2 : 4
            await withTaskGroup(of: (Int, EbookDocument).self) { group in
                var next = 0
                func submit(_ item: (offset: Int, element: Source)) {
                    group.addTask {
                        let url = item.element.url
                        if let cacheDirectory = usableCacheDirectory, var cached = EbookTextCache.load(url: url, size: item.element.size,
                                                                                modifiedAt: item.element.modifiedAt,
                                                                                directory: cacheDirectory) {
                            cached.fileSize = item.element.size
                            return (item.offset, cached)
                        }
                        var extracted = EbookExtractor.extract(url); extracted.fileSize = item.element.size
                        if let cacheDirectory = usableCacheDirectory { try? EbookTextCache.save(extracted, source: url, size: item.element.size,
                                                                         modifiedAt: item.element.modifiedAt,
                                                                         directory: cacheDirectory) }
                        return (item.offset, extracted)
                    }
                }
                while next < min(limit, batch.count) { submit(batch[next]); next += 1 }
                while let (index, document) = await group.next() {
                    ordered[index] = document; processed += 1; progress(processed, document.url.path)
                    if next < batch.count, !Task.isCancelled { submit(batch[next]); next += 1 }
                }
                if Task.isCancelled { group.cancelAll() }
            }
        }
        let documents = ordered.compactMap { $0 }
        errors.append(contentsOf: documents.filter { $0.state == .failed }.map { "\($0.url.path)：\($0.detail)" })
        progress(documents.count, "正在比较正文指纹")
        let matches = await Task.detached(priority: .utility) { EbookSimilarityEngine.compare(documents, level: level, filenamePrefilter: filenamePrefilter) }.value
        return EbookScanResult(documents: documents, matches: matches, errors: errors, duration: Date().timeIntervalSince(started))
    }

    private static func discover(roots: [URL], recursive: Bool) -> ([Source], [String]) {
        var sources: [Source] = [], errors: [String] = []
        for root in roots {
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            let rootIsLocal = (try? root.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) ?? true
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                options: recursive ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else {
                errors.append("无法读取：\(root.path)"); continue
            }
            for case let url as URL in enumerator where EbookExtractor.format(for: url) != nil {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let rawSize = values.fileSize else { continue }
                sources.append(Source(url: url, isNetwork: !rootIsLocal, size: UInt64(max(0, rawSize)),
                                      modifiedAt: values.contentModificationDate))
            }
        }
        return (sources.sorted { $0.url.path < $1.url.path }, errors)
    }
}

private enum EbookTextCache {
    private struct Entry: Codable { let sourcePath: String; let size: UInt64; let modifiedAt: Date?; let document: EbookDocument }

    static func load(url: URL, size: UInt64, modifiedAt: Date?, directory: URL) -> EbookDocument? {
        let file = directory.appendingPathComponent(key(url.path)).appendingPathExtension("json")
        guard let data = try? Data(contentsOf: file), let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.sourcePath == url.path, entry.size == size, entry.modifiedAt == modifiedAt else { return nil }
        return entry.document
    }
    static func save(_ document: EbookDocument, source: URL, size: UInt64, modifiedAt: Date?, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entry = Entry(sourcePath: source.path, size: size, modifiedAt: modifiedAt, document: document)
        try JSONEncoder().encode(entry).write(to: directory.appendingPathComponent(key(source.path)).appendingPathExtension("json"), options: .atomic)
    }
    static func isSafeLocal(_ url: URL) -> Bool {
        let path = url.path
        guard path.hasPrefix("/"), !path.hasPrefix("/Volumes/") else { return false }
        var ancestor = url
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" { ancestor.deleteLastPathComponent() }
        return (try? ancestor.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true
    }
    private static func key(_ value: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(hash, radix: 16)
    }
}
