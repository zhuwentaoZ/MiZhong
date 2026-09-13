import CryptoKit
import Foundation

/// Content comparisons inside the active scan filters. This type never reads or modifies source files.
public enum LibraryComparison {
    public static func isReference(_ file: FileRecord, referencePaths: Set<String>) -> Bool {
        contains(file.id, in: normalized(referencePaths))
    }

    /// A reference comparison only reports groups connecting A with B, not duplicates wholly in either side.
    public static func crossGroups(_ groups: [DuplicateGroup], referencePaths: Set<String>) -> [DuplicateGroup] {
        let roots = normalized(referencePaths)
        guard !roots.isEmpty else { return [] }
        return groups.compactMap { group in
            let reference = group.files.contains { contains($0.id, in: roots) }
            let target = group.files.contains { !contains($0.id, in: roots) }
            guard reference && target else { return nil }
            return DuplicateGroup(hash: group.hash, files: group.files.sorted { $0.id < $1.id })
        }.sorted {
            $0.reclaimableBytes == $1.reclaimableBytes ? $0.id < $1.id : $0.reclaimableBytes > $1.reclaimableBytes
        }
    }

    /// Uniqueness means absent from all observed reference content, not unique within B.
    /// The caller must also withhold this result when reference directory discovery was incomplete.
    public static func uniqueTargets(files: [FileRecord], hashes: [String: String], referencePaths: Set<String>) -> [FileRecord] {
        let roots = normalized(referencePaths)
        guard !roots.isEmpty else { return [] }
        var referenceContent = Set<ContentKey>()
        for file in files where contains(file.id, in: roots) {
            // A failed A hash could match any B file. Do not make an unsupported absence claim.
            guard let hash = hashes[file.id] else { return [] }
            referenceContent.insert(ContentKey(size: file.size, hash: hash))
        }
        var seen = Set<String>()
        return files.filter { file in
            guard !contains(file.id, in: roots), seen.insert(file.id).inserted,
                  let hash = hashes[file.id] else { return false }
            return !referenceContent.contains(ContentKey(size: file.size, hash: hash))
        }.sorted { $0.id < $1.id }
    }

    /// Matches complete nonempty subtrees by relative names, file sizes, full hashes and directory structure.
    /// `directories` must include all visited directories, including empty ones. Any failed enumeration,
    /// metadata read or intentionally incomplete directory must be supplied in `incompleteDirectories`.
    /// Active size/extension/hidden-file filters define the scope; this does not authorize whole-folder deletion.
    public static func duplicateFolders(
        files: [FileRecord], hashes: [String: String], directories: [URL], referencePaths: Set<String>,
        mode: ScanMode, control: ScanControl, incompleteDirectories: Set<String> = []
    ) -> [DuplicateFolderGroup] {
        let roots = normalized(referencePaths)
        if mode == .reference && roots.isEmpty { return [] }
        var nodes: [String: FolderNode] = [:]
        for directory in directories {
            if (try? control.checkpoint()) == nil { return [] }
            let path = directory.standardizedFileURL.path
            nodes[path] = FolderNode(path: path)
        }
        for node in nodes.values {
            let parent = parentPath(node.path)
            if parent != node.path, let parentNode = nodes[parent] { parentNode.children.append(node.path) }
        }
        var seen = Set<String>()
        for file in files {
            if (try? control.checkpoint()) == nil { return [] }
            guard seen.insert(file.id).inserted else { continue }
            let path = parentPath(file.id)
            guard let node = nodes[path] else {
                invalidateAncestors(of: path, nodes: nodes)
                continue
            }
            guard let hash = hashes[file.id] else { node.complete = false; continue }
            node.files.append(FileEntry(name: file.url.lastPathComponent, size: file.size, hash: hash))
        }
        for path in normalized(incompleteDirectories) { invalidateAncestors(of: path, nodes: nodes) }

        // Every parent path sorts before its descendants. Reversing this visits children first
        // without constructing each file's relative path for every ancestor.
        let bottomUp = nodes.keys.sorted(by: >)
        var matches: [String: [FolderNode]] = [:]
        for path in bottomUp {
            if (try? control.checkpoint()) == nil { return [] }
            guard let node = nodes[path] else { continue }
            var digest = SHA256()
            append("MiZhong.folder.v1", to: &digest)
            for file in node.files.sorted(by: { $0.name < $1.name }) {
                if (try? control.checkpoint()) == nil { return [] }
                append("file", to: &digest)
                append(file.name, to: &digest)
                append(String(file.size), to: &digest)
                append(file.hash, to: &digest)
                let (bytes, overflow) = node.totalBytes.addingReportingOverflow(file.size)
                node.totalBytes = bytes; node.complete = node.complete && !overflow
                node.fileCount += 1
            }
            for childPath in node.children.sorted() {
                if (try? control.checkpoint()) == nil { return [] }
                guard let child = nodes[childPath], child.complete, let signature = child.signature else {
                    node.complete = false; continue
                }
                append("directory", to: &digest)
                append(URL(fileURLWithPath: childPath).lastPathComponent, to: &digest)
                append(signature, to: &digest)
                let (bytes, overflow) = node.totalBytes.addingReportingOverflow(child.totalBytes)
                node.totalBytes = bytes; node.complete = node.complete && !overflow
                node.fileCount += child.fileCount
            }
            guard node.complete else { continue }
            node.signature = digest.finalize().map { String(format: "%02x", $0) }.joined()
            guard node.fileCount > 0 else { continue }
            // An ancestor containing an A root is a mixed scope, not a B folder.
            if mode == .reference, roots.contains(where: { $0 != path && isWithin($0, root: path) }) { continue }
            matches[node.signature!, default: []].append(node)
        }

        var result: [DuplicateFolderGroup] = []
        for (signature, matchingNodes) in matches {
            if (try? control.checkpoint()) == nil { return [] }
            let ordered = matchingNodes.sorted { $0.path < $1.path }
            guard ordered.count > 1 else { continue }
            // A complete finite nonempty tree cannot equal its own subtree, but retain the
            // explicit restriction so the API never returns an ancestor/descendant pair.
            var separate: [FolderNode] = []
            for node in ordered where !separate.contains(where: { isWithin(node.path, root: $0.path) }) {
                separate.append(node)
            }
            guard separate.count > 1 else { continue }
            if mode == .reference {
                guard separate.contains(where: { contains($0.path, in: roots) }),
                      separate.contains(where: { !contains($0.path, in: roots) }) else { continue }
            }
            result.append(DuplicateFolderGroup(id: signature, folders: separate.map { URL(fileURLWithPath: $0.path) },
                                               fileCount: separate[0].fileCount, totalBytes: separate[0].totalBytes))
        }
        return result.sorted {
            if $0.totalBytes != $1.totalBytes { return $0.totalBytes > $1.totalBytes }
            if $0.fileCount != $1.fileCount { return $0.fileCount > $1.fileCount }
            return $0.id < $1.id
        }
    }

    private struct ContentKey: Hashable { let size: UInt64; let hash: String }
    private struct FileEntry { let name: String; let size: UInt64; let hash: String }
    private final class FolderNode {
        let path: String
        var children: [String] = []
        var files: [FileEntry] = []
        var complete = true
        var signature: String?
        var fileCount = 0
        var totalBytes: UInt64 = 0
        init(path: String) { self.path = path }
    }

    private static func normalized(_ paths: Set<String>) -> [String] {
        paths.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0).standardizedFileURL.path }.sorted()
    }
    private static func isWithin(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
    private static func contains(_ path: String, in roots: [String]) -> Bool {
        roots.contains { isWithin(path, root: $0) }
    }
    private static func parentPath(_ path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
    }
    private static func invalidateAncestors(of originalPath: String, nodes: [String: FolderNode]) {
        var path = originalPath
        while true {
            nodes[path]?.complete = false
            let parent = parentPath(path)
            if parent == path { break }
            path = parent
        }
    }
    private static func append(_ value: String, to digest: inout SHA256) {
        let data = Data(value.utf8)
        // Length framing prevents names containing separators or control characters from
        // producing the same serialized signature as a different directory layout.
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) { digest.update(data: Data($0)) }
        digest.update(data: data)
    }
}
