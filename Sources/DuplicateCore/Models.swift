import Foundation

public enum ScanMode: String, Sendable, Codable { case standard, reference }

public struct ScanOptions: Sendable, Codable {
    public var recursive: Bool
    public var includeHidden: Bool
    public var similarImages: Bool
    public var minimumFileSize: UInt64
    public var maximumFileSize: UInt64?
    public var excludedPaths: Set<String>
    public var nonRecursivePaths: Set<String> = []
    public var extensions: Set<String> = []
    public var similarityThreshold: Int = 8
    public var localConcurrency: Int = 4
    public var networkConcurrency: Int = 2
    public var retryCount: Int = 2
    public var mode: ScanMode = .standard
    public var referencePaths: Set<String> = []

    public init(recursive: Bool = true, includeHidden: Bool = false, similarImages: Bool = false,
                minimumFileSize: UInt64 = 1, maximumFileSize: UInt64? = nil,
                excludedPaths: Set<String> = []) {
        self.recursive = recursive
        self.includeHidden = includeHidden
        self.similarImages = similarImages
        self.minimumFileSize = minimumFileSize
        self.maximumFileSize = maximumFileSize
        self.excludedPaths = excludedPaths
    }
}

public struct FileRecord: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let url: URL
    public let size: UInt64
    public let modifiedAt: Date?
    public let isNetworkVolume: Bool

    public init(url: URL, size: UInt64, modifiedAt: Date?, isNetworkVolume: Bool) {
        self.id = url.standardizedFileURL.path
        self.url = url
        self.size = size
        self.modifiedAt = modifiedAt
        self.isNetworkVolume = isNetworkVolume
    }

    private enum CodingKeys: String, CodingKey { case url, size, modifiedAt, isNetworkVolume }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        url = try values.decode(URL.self, forKey: .url)
        id = url.standardizedFileURL.path
        size = try values.decode(UInt64.self, forKey: .size)
        modifiedAt = try values.decodeIfPresent(Date.self, forKey: .modifiedAt)
        isNetworkVolume = try values.decode(Bool.self, forKey: .isNetworkVolume)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(url, forKey: .url); try values.encode(size, forKey: .size)
        try values.encodeIfPresent(modifiedAt, forKey: .modifiedAt)
        try values.encode(isNetworkVolume, forKey: .isNetworkVolume)
    }
}

public struct DuplicateGroup: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let hash: String
    public let files: [FileRecord]
    public var reclaimableBytes: UInt64 { UInt64(max(0, files.count - 1)) * (files.first?.size ?? 0) }

    public init(hash: String, files: [FileRecord]) {
        self.id = hash
        self.hash = hash
        self.files = files
    }

    private enum CodingKeys: String, CodingKey { case hash, files }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hash = try values.decode(String.self, forKey: .hash); id = hash
        files = try values.decode([FileRecord].self, forKey: .files)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(hash, forKey: .hash); try values.encode(files, forKey: .files)
    }
}

public struct SimilarImageGroup: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let files: [FileRecord]
    public let similarity: Double

    public init(id: String, files: [FileRecord], similarity: Double) {
        self.id = id
        self.files = files
        self.similarity = similarity
    }
}

public struct ScanProgress: Sendable {
    public enum Phase: String, Sendable, Codable { case validatingSession, discovering, fingerprinting, hashing, analyzingImages, comparingFolders, finished }
    public let phase: Phase
    public let discovered: Int
    public let processed: Int
    public let currentPath: String
    public init(phase: Phase, discovered: Int, processed: Int, currentPath: String) {
        self.phase = phase; self.discovered = discovered; self.processed = processed; self.currentPath = currentPath
    }
}

public struct ScanResult: Sendable, Codable {
    public let groups: [DuplicateGroup]
    public let similarImageGroups: [SimilarImageGroup]
    public let scannedFiles: Int
    public var errors: [String]
    public let duration: TimeInterval
    public var wasCancelled: Bool = false
    public var cacheHits: Int = 0
    public var mode: ScanMode = .standard
    public var referencePaths: Set<String> = []
    public var uniqueFiles: [FileRecord] = []
    public var duplicateFolderGroups: [DuplicateFolderGroup] = []
    public var isIncomplete: Bool = false
    public var pendingPaths: [String] = []
    public var sessionID: UUID? = nil
    public var sessionSaved: Bool = false
    public var candidateOnly: Bool? = nil
    public var duplicateFiles: Int { groups.reduce(0) { $0 + $1.files.count } }
    public var reclaimableBytes: UInt64 { groups.reduce(0) { $0 + $1.reclaimableBytes } }
}

public struct DuplicateFolderGroup: Identifiable, Sendable, Codable, Hashable {
    public let id: String
    public let folders: [URL]
    public let fileCount: Int
    public let totalBytes: UInt64
    public init(id: String, folders: [URL], fileCount: Int, totalBytes: UInt64) {
        self.id = id; self.folders = folders; self.fileCount = fileCount; self.totalBytes = totalBytes
    }
}
