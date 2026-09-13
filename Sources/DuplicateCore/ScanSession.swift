import Darwin
import Foundation

public enum ScanSessionStatus: String, Codable, Sendable {
    case running, interrupted, completed, needsRetry
}

struct DirectoryTask: Codable, Sendable, Hashable {
    let url: URL
    let recursive: Bool
}

/// Only filesystem metadata is stored, never network URLs or credentials.
struct DirectoryStamp: Codable, Sendable, Equatable {
    let device: Int32
    let inode: UInt64
    let modified: Int64
    let modifiedNS: Int64
    let changed: Int64
    let changedNS: Int64
    static func read(_ url: URL) throws -> Self {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard value.st_mode & S_IFMT == S_IFDIR else { throw VerificationError.changed }
        return Self(device: value.st_dev, inode: value.st_ino,
                    modified: Int64(value.st_mtimespec.tv_sec), modifiedNS: Int64(value.st_mtimespec.tv_nsec),
                    changed: Int64(value.st_ctimespec.tv_sec), changedNS: Int64(value.st_ctimespec.tv_nsec))
    }
}

struct SessionDirectory: Codable, Sendable {
    let task: DirectoryTask
    let stamp: DirectoryStamp
}

struct SessionFile: Codable, Sendable {
    var file: FileRecord
    var stamp: FileStamp
    var sample: String?
    var full: String?
    var imageSignature: ImageSimilarity.Signature? = nil
}

public struct ScanSession: Codable, Sendable, Identifiable {
    public let version: Int
    public let id: UUID
    public let createdAt: Date
    public internal(set) var updatedAt: Date
    public let roots: [URL]
    public let options: ScanOptions
    public internal(set) var status: ScanSessionStatus
    public internal(set) var result: ScanResult?
    public var pendingCount: Int {
        pendingDirectories.count + blockedDirectories.count + failedFiles.count
    }
    var files: [String: SessionFile]
    var directories: [String: SessionDirectory]
    var pendingDirectories: [DirectoryTask]
    var blockedDirectories: [DirectoryTask]
    var failedFiles: Set<String>
    var phase: ScanProgress.Phase
    var elapsed: TimeInterval
    var shallowDirectories: Set<String>
    var networkRoots: Set<String>

    init(roots: [URL], options: ScanOptions) {
        version = 1; id = UUID(); createdAt = Date(); updatedAt = createdAt
        self.roots = roots; self.options = options; status = .running
        files = [:]; directories = [:]; blockedDirectories = []; failedFiles = []
        phase = .discovering; elapsed = 0; shallowDirectories = []; networkRoots = []
        pendingDirectories = roots.map {
            DirectoryTask(url: $0.standardizedFileURL,
                          recursive: options.recursive && !options.nonRecursivePaths.contains($0.standardizedFileURL.path))
        }
    }
}

public enum ScanSessionStore {
    public enum StoreError: LocalizedError {
        case unsupportedVersion, invalidPaths, referenceOverlap, storageInsideScan, invalidOptions, networkDisconnected
        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion: "此任务来自不兼容的觅重版本。"
            case .invalidPaths: "请选择系统已挂载的本地文件夹路径；任务不接受网络登录地址。"
            case .referenceOverlap: "A 库和 B 库必须分别选择，且不能相同或互相包含。"
            case .storageInsideScan: "任务文件必须保存在本机，并位于扫描目录之外。"
            case .invalidOptions: "扫描大小范围或相似图片阈值无效。"
            case .networkDisconnected: "原 NAS 位置当前不是网络卷，请在 Finder 中重新挂载同一共享后继续任务。"
            }
        }
    }
    public static func load(_ url: URL) throws -> ScanSession {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let session: ScanSession
        if data.starts(with: Data("bplist".utf8)) {
            session = try PropertyListDecoder().decode(ScanSession.self, from: data)
        } else {
            // Backward compatibility with sessions created by 0.4.x and 0.5.0/0.5.1.
            session = try JSONDecoder().decode(ScanSession.self, from: data)
        }
        guard session.version == 1 else { throw StoreError.unsupportedVersion }
        try validate(roots: session.roots, options: session.options)
        let paths = session.files.values.map(\.file.url)
            + session.directories.values.map(\.task.url)
            + session.pendingDirectories.map(\.url) + session.blockedDirectories.map(\.url)
            + session.failedFiles.map { URL(fileURLWithPath: $0) }
            + session.shallowDirectories.map { URL(fileURLWithPath: $0) }
        guard paths.allSatisfy({ candidate in
            isLocalPath(candidate) && session.roots.contains {
                within(candidate.standardizedFileURL.path, $0.standardizedFileURL.path)
            }
        }), session.files.allSatisfy({ key, value in
            key == value.file.id && key == value.file.url.standardizedFileURL.path && value.stamp.size >= 0
        }), session.directories.allSatisfy({ $0.key == $0.value.task.url.standardizedFileURL.path }),
        session.failedFiles.union(session.shallowDirectories).allSatisfy({ $0.hasPrefix("/") }),
        session.networkRoots.isSubset(of: Set(session.roots.map { $0.standardizedFileURL.path }))
        else { throw StoreError.invalidPaths }
        return session
    }
    static func isLocalPath(_ url: URL) -> Bool {
        url.isFileURL && url.user == nil && url.password == nil && (url.host == nil || url.host == "" || url.host == "localhost")
    }
    static func within(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
    public static func validate(roots: [URL], options: ScanOptions) throws {
        guard !roots.isEmpty, roots.allSatisfy(isLocalPath),
              options.referencePaths.allSatisfy({ $0.hasPrefix("/") }) else { throw StoreError.invalidPaths }
        guard options.maximumFileSize.map({ $0 >= options.minimumFileSize }) ?? true,
              (0...64).contains(options.similarityThreshold) else { throw StoreError.invalidOptions }
        if options.mode == .reference {
            let references = options.referencePaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            let paths = Set(roots.map { $0.standardizedFileURL.path })
            let targets = paths.subtracting(references)
            guard !references.isEmpty, !targets.isEmpty, Set(references).isSubset(of: paths),
                  !references.contains(where: { a in targets.contains { within(a, $0) || within($0, a) } })
            else { throw StoreError.referenceOverlap }
        }
    }
    static func save(_ session: ScanSession, to url: URL) throws {
        guard isLocalPath(url) else { throw StoreError.invalidPaths }
        let parent = url.deletingLastPathComponent()
        var existing = parent
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            existing.deleteLastPathComponent()
        }
        let local = try existing.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal == true
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let excluded = session.options.excludedPaths.contains { within(resolved, $0) }
        guard local, excluded || !session.roots.contains(where: {
            within(resolved, $0.resolvingSymlinksInPath().standardizedFileURL.path)
        }) else { throw StoreError.storageInsideScan }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(session).write(to: url, options: .atomic)
    }
}
