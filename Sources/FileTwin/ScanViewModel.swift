import AppKit
import DuplicateCore
import Foundation

@MainActor
final class ScanViewModel: ObservableObject {
    @Published var roots: [URL] = []
    @Published var referenceRoots: [URL] = []
    @Published var scanMode: ScanMode = .standard
    @Published var recursive = true
    @Published var includeHidden = false
    @Published var similarImages = false
    @Published var minimumSizeMB = 0
    @Published var maximumSizeMB = 0
    @Published var threshold = 8
    @Published var extensions = ""
    @Published var exclusions: Set<String> = []
    @Published var protectedPaths: Set<String> = []
    @Published var shallowPaths: Set<String> = []
    @Published var isScanning = false
    @Published var isPaused = false
    @Published var isCancelling = false
    @Published var isCleaning = false
    @Published var useCache = true
    @Published var localWorkers = 4
    @Published var networkWorkers = 2
    @Published var searchText = ""
    @Published var progress = ScanProgress(phase: .discovering, discovered: 0, processed: 0, currentPath: "")
    @Published var result: ScanResult?
    @Published var alertMessage: String?
    @Published var selectedForTrash: Set<URL> = []
    @Published var showErrors = false
    @Published var preferredDirectory: URL?
    @Published var log: [String] = []
    @Published var showHistory = false
    @Published var history: [SessionHistoryItem] = []
    @Published var isLoadingHistory = false
    @Published var historyIssue: String?
    @Published var activeSessionURL: URL?
    @Published var isRestoredSession = false
    @Published var resultIncludesSimilarImages = false
    private var scanner: DuplicateScanner?
    private var scanTask: Task<Void, Never>?
    private var control = ScanControl()
    private var generation = UUID()
    private var resultProtectedPaths: Set<String> = []
    private var reviewedSelections: Set<URL> = []
    static var support: URL {
        // QA can use an isolated local support directory without changing real user settings.
        if let path = ProcessInfo.processInfo.environment["MIZHONG_SUPPORT_DIR"], path.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            var ancestor = candidate
            while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
                ancestor.deleteLastPathComponent()
            }
            if !candidate.path.hasPrefix("/Volumes/"),
               (try? ancestor.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true {
                return candidate
            }
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MiZhong")
    }
    static var sessionsDirectory: URL { support.appendingPathComponent("Sessions", isDirectory: true) }

    struct SessionHistoryItem: Identifiable, Sendable {
        let id: UUID
        let url: URL
        let updatedAt: Date
        let roots: [URL]
        let mode: ScanMode
        let status: ScanSessionStatus
        let pendingCount: Int
        let scannedFiles: Int
        let duplicateGroups: Int
        let hasResult: Bool
    }
    private struct ReviewState: Codable, Sendable {
        var selectedPaths: Set<String>
        var protectedPaths: Set<String>
    }
    private struct Settings: Codable {
        var recursive: Bool; var hidden: Bool; var min: Int; var max: Int
        var threshold: Int; var extensions: String; var exclusions: Set<String>; var protectedPaths: Set<String>
        var useCache: Bool; var local: Int; var network: Int
        var recentRoots: [String]? = nil
        var shallowPaths: Set<String>? = nil
        var preferredPath: String? = nil
        var mode: ScanMode? = nil
        var referenceRoots: [String]? = nil
    }
    init() {
        if let data = try? Data(contentsOf: Self.support.appendingPathComponent("settings.json")),
           let s = try? JSONDecoder().decode(Settings.self, from: data) {
            recursive = s.recursive; includeHidden = s.hidden; minimumSizeMB = s.min; maximumSizeMB = s.max
            threshold = s.threshold; extensions = s.extensions; exclusions = s.exclusions
            protectedPaths = s.protectedPaths; useCache = s.useCache; localWorkers = s.local; networkWorkers = s.network
            roots = (s.recentRoots ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
            shallowPaths = s.shallowPaths ?? []
            preferredDirectory = s.preferredPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            scanMode = s.mode ?? .standard
            referenceRoots = (s.referenceRoots ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        // Similarity is deliberately opt-in on every launch.
    }
    func saveSettings() {
        var s = Settings(recursive: recursive, hidden: includeHidden, min: minimumSizeMB, max: maximumSizeMB,
                         threshold: threshold, extensions: extensions, exclusions: exclusions,
                         protectedPaths: protectedPaths, useCache: useCache, local: localWorkers, network: networkWorkers)
        s.recentRoots = roots.map(\.path); s.shallowPaths = shallowPaths; s.preferredPath = preferredDirectory?.path
        s.mode = scanMode; s.referenceRoots = referenceRoots.map(\.path)
        do {
            try FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
            try JSONEncoder().encode(s).write(to: Self.support.appendingPathComponent("settings.json"), options: .atomic)
        } catch { alertMessage = "设置保存失败：\(error.localizedDescription)" }
    }
    func chooseFolder() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }
    func addFolder() { for url in chooseFolder() where !roots.contains(url) { roots.append(url) } }
    func addReferenceFolder() { for url in chooseFolder() where !referenceRoots.contains(url) { referenceRoots.append(url) } }
    func addExclusion() { exclusions.formUnion(chooseFolder().map(\.path)) }
    func addProtection() { protectedPaths.formUnion(chooseFolder().map(\.path)) }
    func choosePreferred() { preferredDirectory = chooseFolder().first }
    func canSelect(_ file: FileRecord) -> Bool {
        guard let result, !isRestoredSession, !result.wasCancelled, !result.isIncomplete else { return false }
        return !file.isNetworkVolume && !effectiveProtection.contains { Self.contains(file.id, in: $0) }
    }
    var canCleanResults: Bool {
        guard let result else { return false }
        return !isRestoredSession && !result.wasCancelled && !result.isIncomplete && !isScanning && !isCleaning
    }
    var hasSavedTask: Bool {
        guard let activeSessionURL else { return false }
        return FileManager.default.fileExists(atPath: activeSessionURL.path)
    }
    var canResumeSavedTask: Bool {
        hasSavedTask && !isScanning && !isCleaning && !isLoadingHistory
    }
    private var effectiveProtection: Set<String> {
        protectedPaths.union(resultProtectedPaths).union(result?.referencePaths ?? [])
    }
    func isReference(_ url: URL) -> Bool {
        (result?.referencePaths ?? []).contains { Self.contains(url.path, in: $0) }
    }
    private static func contains(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
    func autoSelect() {
        guard let result, canCleanResults else { return }
        selectedForTrash = []
        for group in result.groups {
            let ordered = group.files.sorted {
                let a = $0, b = $1
                @MainActor func rank(_ file: FileRecord) -> Int {
                    if !canSelect(file) { return 0 }
                    if let preferredDirectory, file.id.hasPrefix(preferredDirectory.path + "/") { return 1 }
                    return 2
                }
                if rank(a) != rank(b) { return rank(a) < rank(b) }
                if a.id.count != b.id.count { return a.id.count < b.id.count }
                return a.id < b.id
            }
            guard let keeper = ordered.first else { continue }
            for file in ordered where file.id != keeper.id && canSelect(file) { selectedForTrash.insert(file.url) }
        }
        saveReview()
    }
    func scan() {
        guard !isScanning, !isCleaning, !isLoadingHistory else { return }
        guard !roots.isEmpty else { alertMessage = "请先添加文件夹或已挂载的 NAS 位置。"; return }
        if scanMode == .reference {
            guard !referenceRoots.isEmpty else { alertMessage = "请添加 A 资料库作为只读对比基准。"; return }
            let aPaths = referenceRoots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
            let bPaths = roots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
            guard !aPaths.contains(where: { a in bPaths.contains { b in Self.contains(a, in: b) || Self.contains(b, in: a) } }) else {
                alertMessage = "A 资料库和 B 待整理目录不能相同或互相包含，请选择分开的目录。"; return
            }
        }
        guard minimumSizeMB >= 0, maximumSizeMB >= 0,
              minimumSizeMB <= Int.max / 1048576, maximumSizeMB <= Int.max / 1048576,
              maximumSizeMB == 0 || maximumSizeMB >= minimumSizeMB else {
            alertMessage = "请输入有效的大小范围：非负数，且最大值不小于最小值。"; return
        }
        saveSettings()
        var options = ScanOptions(recursive: recursive, includeHidden: includeHidden, similarImages: similarImages,
                                  minimumFileSize: max(1, UInt64(minimumSizeMB) * 1048576),
                                  maximumFileSize: maximumSizeMB == 0 ? nil : UInt64(maximumSizeMB) * 1048576,
                                  excludedPaths: exclusions.union([Self.support.path]))
        options.extensions = Set(extensions.lowercased().split { ",，; ".contains($0) }.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        options.nonRecursivePaths = shallowPaths; options.similarityThreshold = threshold
        options.localConcurrency = localWorkers; options.networkConcurrency = networkWorkers
        options.mode = scanMode
        options.referencePaths = scanMode == .reference ? Set(referenceRoots.map { $0.standardizedFileURL.path }) : []
        let sessionURL = Self.sessionsDirectory.appendingPathComponent(UUID().uuidString + ".json")
        do { try FileManager.default.createDirectory(at: Self.sessionsDirectory, withIntermediateDirectories: true) }
        catch { alertMessage = "无法创建任务记录：\(error.localizedDescription)"; return }
        resultProtectedPaths = protectedPaths.union(options.referencePaths)
        reviewedSelections = []
        selectedForTrash = []; isRestoredSession = false
        activeSessionURL = sessionURL
        saveReview()
        startScan(roots: roots + (scanMode == .reference ? referenceRoots : []), options: options, sessionURL: sessionURL, resume: false)
    }
    private func startScan(roots urls: [URL], options: ScanOptions, sessionURL: URL, resume: Bool) {
        isScanning = true; isPaused = false; isCancelling = false; isRestoredSession = false
        result = nil; selectedForTrash = []; searchText = ""; control = ScanControl(); generation = UUID()
        let id = generation, token = control
        resultIncludesSimilarImages = options.similarImages
        let engine = DuplicateScanner(cacheURL: useCache ? Self.support.appendingPathComponent("fingerprints-v2.json") : nil)
        scanner = engine
        progress = .init(phase: .discovering, discovered: 0, processed: 0, currentPath: "")
        scanTask = Task {
            let output = await engine.scan(roots: urls, options: options, control: token, sessionURL: sessionURL, resume: resume) { update in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == id, self.isScanning else { return }
                    self.progress = update
                }
            }
            guard generation == id else { return }
            result = output; isScanning = false; isPaused = false; isCancelling = false; scanTask = nil
            if !output.isIncomplete && !output.wasCancelled {
                selectedForTrash = Set(output.groups.flatMap(\.files).filter { reviewedSelections.contains($0.url) && canSelect($0) }.map(\.url))
                // A changed task may produce a different grouping: never retain a selection of every copy.
                for group in output.groups where group.files.allSatisfy({ selectedForTrash.contains($0.url) }) {
                    if let keeper = group.files.first { selectedForTrash.remove(keeper.url) }
                }
            }
            saveReview(retainingPreviousSelections: output.isIncomplete || output.wasCancelled)
            refreshHistory()
        }
    }
    func pauseResume() {
        guard isScanning else { return }
        isPaused.toggle()
        if isPaused { control.pause() } else { control.resume() }
    }
    func cancel() { guard isScanning else { return }; isCancelling = true; control.cancel() }
    func refreshHistory() {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true; historyIssue = nil
        let directory = Self.sessionsDirectory
        Task {
            let loaded = await Task.detached(priority: .utility) { () -> ([SessionHistoryItem], String?) in
                guard FileManager.default.fileExists(atPath: directory.path) else { return ([], nil) }
                do {
                    let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                        .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".review.json") }
                    var items: [SessionHistoryItem] = []
                    var failures = 0
                    for url in urls {
                        do {
                            let session = try ScanSessionStore.load(url)
                            items.append(SessionHistoryItem(id: session.id, url: url, updatedAt: session.updatedAt,
                                                            roots: session.roots, mode: session.options.mode,
                                                            status: session.status, pendingCount: session.pendingCount,
                                                            scannedFiles: session.result?.scannedFiles ?? 0,
                                                            duplicateGroups: session.result?.groups.count ?? 0,
                                                            hasResult: session.result != nil))
                        } catch { failures += 1 }
                    }
                    return (items.sorted { $0.updatedAt > $1.updatedAt }, failures == 0 ? nil : "有 \(failures) 个任务记录无法读取，原文件已保留。")
                } catch { return ([], "无法读取历史任务：\(error.localizedDescription)") }
            }.value
            history = loaded.0; historyIssue = loaded.1; isLoadingHistory = false
        }
    }
    func deleteSession(_ item: SessionHistoryItem) {
        guard !isScanning, !isCleaning, !isLoadingHistory else { return }
        do {
            try FileManager.default.removeItem(at: item.url)
            let reviewURL = item.url.deletingPathExtension().appendingPathExtension("review.json")
            if FileManager.default.fileExists(atPath: reviewURL.path) {
                try FileManager.default.removeItem(at: reviewURL)
            }
            if activeSessionURL == item.url { activeSessionURL = nil }
            history.removeAll { $0.id == item.id }
        } catch {
            alertMessage = "删除历史任务失败：\(error.localizedDescription)"
        }
    }
    func extendSession(_ item: SessionHistoryItem) {
        guard item.mode == .standard, !isScanning, !isCleaning, !isLoadingHistory else { return }
        let additions = chooseFolder()
        guard !additions.isEmpty else { return }
        let destination = Self.sessionsDirectory.appendingPathComponent(UUID().uuidString + ".json")
        isLoadingHistory = true
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    try ScanSessionStore.createIncrementalTask(from: item.url, adding: additions, to: destination)
                }.value
                isLoadingHistory = false; showHistory = false
                restoreSession(destination, resume: true)
            } catch {
                isLoadingHistory = false
                alertMessage = "无法创建增量任务：\(error.localizedDescription)"
            }
        }
    }
    func restoreSession(_ url: URL, resume: Bool = false) {
        guard !isScanning, !isCleaning, !isLoadingHistory else { return }
        isLoadingHistory = true
        Task {
            do {
                let payload = try await Task.detached(priority: .utility) {
                    let session = try ScanSessionStore.load(url)
                    let reviewURL = url.deletingPathExtension().appendingPathExtension("review.json")
                    let review = (try? Data(contentsOf: reviewURL)).flatMap { try? JSONDecoder().decode(ReviewState.self, from: $0) }
                    return (session, review)
                }.value
                let session = payload.0, options = session.options
                scanMode = options.mode; referenceRoots = options.referencePaths.sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
                roots = session.roots.filter { !options.referencePaths.contains($0.path) }
                recursive = options.recursive; includeHidden = options.includeHidden; similarImages = options.similarImages
                minimumSizeMB = Int(options.minimumFileSize / 1048576)
                maximumSizeMB = Int((options.maximumFileSize ?? 0) / 1048576)
                threshold = options.similarityThreshold; extensions = options.extensions.sorted().joined(separator: ", ")
                exclusions = options.excludedPaths.subtracting([Self.support.path]); shallowPaths = options.nonRecursivePaths
                localWorkers = options.localConcurrency; networkWorkers = options.networkConcurrency
                resultIncludesSimilarImages = options.similarImages
                activeSessionURL = url
                resultProtectedPaths = (payload.1?.protectedPaths ?? []).union(options.referencePaths)
                reviewedSelections = Set((payload.1?.selectedPaths ?? []).map { URL(fileURLWithPath: $0) })
                selectedForTrash = []; isLoadingHistory = false; showHistory = false
                if resume {
                    startScan(roots: session.roots, options: options, sessionURL: url, resume: true)
                } else {
                    result = session.result
                    isRestoredSession = true
                    if result == nil {
                        alertMessage = "任务检查点已恢复。此任务尚未生成结果，点击“继续原任务”完成扫描。"
                    }
                }
            } catch {
                isLoadingHistory = false
                alertMessage = "任务恢复失败：\(error.localizedDescription)"
            }
        }
    }
    func resumeActiveSession() {
        guard let activeSessionURL, canResumeSavedTask else { return }
        restoreSession(activeSessionURL, resume: true)
    }
    func saveReview(retainingPreviousSelections: Bool = false) {
        guard let activeSessionURL, !isRestoredSession else { return }
        let selections = retainingPreviousSelections ? reviewedSelections.union(selectedForTrash) : selectedForTrash
        let review = ReviewState(selectedPaths: Set(selections.map(\.path)), protectedPaths: resultProtectedPaths)
        do {
            try JSONEncoder().encode(review).write(to: activeSessionURL.deletingPathExtension().appendingPathExtension("review.json"), options: .atomic)
        } catch { alertMessage = "审核选择保存失败：\(error.localizedDescription)" }
    }
    func clearCache() {
        guard !isScanning else { return }
        Task {
            do {
                let engine = DuplicateScanner(cacheURL: Self.support.appendingPathComponent("fingerprints-v2.json"))
                try await engine.clearCache(); alertMessage = "本地指纹缓存已清空。"
            } catch { alertMessage = error.localizedDescription }
        }
    }
    func exportCSV(json: Bool = false) {
        guard let result else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = json ? "觅重查重报告.json" : "觅重查重报告.csv"
        panel.allowedContentTypes = json ? [.json] : [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if json { try ReportExporter.json(result).write(to: url, options: .atomic) }
            else { try ReportExporter.csv(result).write(to: url, atomically: true, encoding: .utf8) }
        } catch { alertMessage = "导出失败：\(error.localizedDescription)" }
    }
    func trashSelected() {
        guard let result, !selectedForTrash.isEmpty, canCleanResults else { return }
        let selected = selectedForTrash, protection = effectiveProtection
        isCleaning = true
        Task {
            let lines = await Task.detached(priority: .utility) {
                var lines: [String] = []
                do {
                    for group in result.groups {
                        let targets = Set(group.files.map(\.url)).intersection(selected)
                        if result.candidateOnly == true { try SafeCleaner.validateCandidates(targets, in: group, protectedPaths: protection) }
                        else { try SafeCleaner.validate(targets, in: group, protectedPaths: protection) }
                    }
                } catch { return ["未执行清理：\(error.localizedDescription)"] }
                for group in result.groups {
                    let targets = Set(group.files.map(\.url)).intersection(selected)
                    guard !targets.isEmpty else { continue }
                    do {
                        let failures = result.candidateOnly == true
                            ? try SafeCleaner.trashCandidates(targets, in: group, protectedPaths: protection)
                            : try SafeCleaner.trash(targets, in: group, protectedPaths: protection)
                        for url in targets {
                            lines.append("\(url.path)：\(failures[url].map { "失败 " + $0 } ?? "已移至废纸篓")")
                        }
                    } catch { lines.append(error.localizedDescription) }
                }
                return lines
            }.value
            log = lines; isCleaning = false; selectedForTrash = []
            do {
                let data = try JSONEncoder().encode(["date": Date().description, "operations": lines.joined(separator: "\n")])
                try FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
                try data.write(to: Self.support.appendingPathComponent("cleanup-\(UUID().uuidString).json"), options: .atomic)
            } catch { log.append("日志写入失败：\(error.localizedDescription)") }
            alertMessage = log.joined(separator: "\n")
            self.result = nil
        }
    }
}
