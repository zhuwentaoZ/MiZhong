import Foundation

public enum SafeCleaner {
    public enum CleanerError: LocalizedError {
        case lastCopy, unknownSelection, networkVolume, protectedFile, staleFile
        public var errorDescription: String? {
            switch self {
            case .lastCopy: "每组必须至少保留一个不同的真实文件。"
            case .unknownSelection: "选择包含不属于当前重复组的文件。"
            case .networkVolume: "网络卷仅支持只读扫描；请在 NAS 管理界面处理文件。"
            case .protectedFile: "所选文件位于保护目录中。"
            case .staleFile: "文件已变化或内容不再一致，请重新扫描。"
            }
        }
    }
    /// Read-only preflight, also used in tests. Never trusts a cached digest for cleanup.
    public static func validate(_ selected: Set<URL>, in group: DuplicateGroup,
                                protectedPaths: Set<String> = []) throws {
        let members = Set(group.files.map { $0.url.standardizedFileURL.path })
        let paths = Set(selected.map { $0.standardizedFileURL.path })
        guard paths.isSubset(of: members) else { throw CleanerError.unknownSelection }
        guard !selected.isEmpty else { return }
        guard let keeper = group.files.first(where: { !paths.contains($0.url.standardizedFileURL.path) }),
              paths.count < members.count else { throw CleanerError.lastCopy }
        let control = ScanControl()
        let keptStamp = try FileStamp.read(keeper.url)
        guard try FileVerification.hash(keeper.url, expected: keptStamp, control: control) == group.hash else { throw CleanerError.staleFile }
        for url in selected {
            guard !protectedPaths.contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") }) else { throw CleanerError.protectedFile }
            let volume = try url.resourceValues(forKeys: [.volumeIsLocalKey])
            guard volume.volumeIsLocal == true,
                  group.files.first(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path })?.isNetworkVolume == false else { throw CleanerError.networkVolume }
            guard try FileVerification.equal(url, keeper.url) else { throw CleanerError.staleFile }
        }
    }
    public static func trash(_ selected: Set<URL>, in group: DuplicateGroup,
                             protectedPaths: Set<String> = []) throws -> [URL: String] {
        try validate(selected, in: group, protectedPaths: protectedPaths)
        var failures: [URL: String] = [:]
        for url in selected {
            do {
                // Validate each target and a surviving original again immediately before moving.
                let current = DuplicateGroup(hash: group.hash, files: group.files.filter {
                    $0.url.standardizedFileURL.path == url.standardizedFileURL.path ||
                    !Set(selected.map { $0.standardizedFileURL.path }).contains($0.url.standardizedFileURL.path)
                })
                try validate([url], in: current, protectedPaths: protectedPaths)
                _ = try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch { failures[url] = error.localizedDescription }
        }
        return failures
    }

    /// Validates a sample-fingerprint candidate group without trusting the sampled digest.
    public static func validateCandidates(_ selected: Set<URL>, in group: DuplicateGroup,
                                          protectedPaths: Set<String> = []) throws {
        let members = Set(group.files.map { $0.url.standardizedFileURL.path })
        let paths = Set(selected.map { $0.standardizedFileURL.path })
        guard paths.isSubset(of: members) else { throw CleanerError.unknownSelection }
        guard !selected.isEmpty else { return }
        guard let keeper = group.files.first(where: { !paths.contains($0.url.standardizedFileURL.path) }), paths.count < members.count else { throw CleanerError.lastCopy }
        for url in selected {
            guard !protectedPaths.contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") }) else { throw CleanerError.protectedFile }
            let volume = try url.resourceValues(forKeys: [.volumeIsLocalKey])
            guard volume.volumeIsLocal == true,
                  group.files.first(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path })?.isNetworkVolume == false else { throw CleanerError.networkVolume }
            guard try FileVerification.equal(url, keeper.url) else { throw CleanerError.staleFile }
        }
    }

    public static func trashCandidates(_ selected: Set<URL>, in group: DuplicateGroup,
                                       protectedPaths: Set<String> = []) throws -> [URL: String] {
        try validateCandidates(selected, in: group, protectedPaths: protectedPaths)
        var failures: [URL: String] = [:]
        for url in selected {
            do {
                let selectedPaths = Set(selected.map { $0.standardizedFileURL.path })
                let current = DuplicateGroup(hash: group.hash, files: group.files.filter {
                    $0.url.standardizedFileURL.path == url.standardizedFileURL.path || !selectedPaths.contains($0.url.standardizedFileURL.path)
                })
                try validateCandidates([url], in: current, protectedPaths: protectedPaths)
                _ = try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch { failures[url] = error.localizedDescription }
        }
        return failures
    }
}
