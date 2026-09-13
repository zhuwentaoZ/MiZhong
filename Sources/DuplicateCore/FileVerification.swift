import CryptoKit
import Darwin
import Foundation

struct FileStamp: Codable, Hashable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modified: Int64
    let modifiedNS: Int64
    let changed: Int64
    let changedNS: Int64
    var identity: String { "\(device):\(inode)" }
    init(_ v: stat) {
        device = v.st_dev; inode = v.st_ino; size = v.st_size
        modified = Int64(v.st_mtimespec.tv_sec); modifiedNS = Int64(v.st_mtimespec.tv_nsec)
        changed = Int64(v.st_ctimespec.tv_sec); changedNS = Int64(v.st_ctimespec.tv_nsec)
    }
    static func read(_ url: URL) throws -> FileStamp {
        var v = stat()
        guard lstat(url.path, &v) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard v.st_mode & S_IFMT == S_IFREG else { throw VerificationError.changed }
        return FileStamp(v)
    }
}
enum VerificationError: LocalizedError {
    case changed
    var errorDescription: String? { "文件已变化或内容校验失败；已跳过，请重新扫描。" }
}
enum FileVerification {
    static func open(_ url: URL, expected: FileStamp) throws -> FileHandle {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var v = stat()
        guard fstat(fd, &v) == 0, FileStamp(v) == expected else { Darwin.close(fd); throw VerificationError.changed }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    static func hash(_ url: URL, expected: FileStamp, sample: Bool = false, control: ScanControl) throws -> String {
        let handle = try open(url, expected: expected)
        defer { try? handle.close() }
        var digest = SHA256()
        if sample && expected.size > 196608 {
            for offset in [Int64(0), expected.size / 2, expected.size - 65536] {
                try control.checkpoint(); try handle.seek(toOffset: UInt64(offset))
                digest.update(data: try handle.read(upToCount: 65536) ?? Data())
            }
        } else {
            while true {
                try control.checkpoint()
                let data = try handle.read(upToCount: 1048576) ?? Data()
                if data.isEmpty { break }; digest.update(data: data)
            }
        }
        var v = stat()
        guard fstat(handle.fileDescriptor, &v) == 0, FileStamp(v) == expected,
              try FileStamp.read(url) == expected else { throw VerificationError.changed }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func equal(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let a = try FileStamp.read(lhs), b = try FileStamp.read(rhs)
        guard a.size == b.size, a.identity != b.identity else { return false }
        let x = try open(lhs, expected: a), y = try open(rhs, expected: b)
        defer { try? x.close(); try? y.close() }
        while true {
            let d = try x.read(upToCount: 1048576) ?? Data(), e = try y.read(upToCount: 1048576) ?? Data()
            if d != e { return false }; if d.isEmpty { break }
        }
        return try FileStamp.read(lhs) == a && FileStamp.read(rhs) == b
    }
}
