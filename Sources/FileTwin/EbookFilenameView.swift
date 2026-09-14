import AppKit
import DuplicateCore
import SwiftUI

struct EbookFilenameView: View {
    private struct DRMStats: Sendable { let checked: Int; let encrypted: Int; let unknown: Int }
    private struct PreparedHistoryResult: Sendable {
        let result: EbookFilenameScanResult; let fileSizes: [String: Int64]; let drmStatuses: [String: EbookDRMStatus]
        let drmStats: DRMStats?; let matches: [EbookFilenameMatch]; let groups: [EbookFilenameGroup]; let groupsByID: [String: EbookFilenameGroup]
        let encryptedFiles: [URL]; let date: Date; let fileCount: Int
    }
    private struct PreparedScanResult: Sendable {
        let formattedSizes: [String: String]
        let drmStats: DRMStats?
        let matches: [EbookFilenameMatch]
        let groups: [EbookFilenameGroup]
        let groupsByID: [String: EbookFilenameGroup]
        let encryptedFiles: [URL]
    }
    @State private var roots: [URL] = []
    @State private var recursive = true
    @State private var quickDRMCheck = false
    @State private var minimum = 0.55
    @State private var scanning = false
    @State private var foundCount = 0
    @State private var visitedCount = 0
    @State private var phase = ""
    @State private var currentPath = ""
    @State private var result: EbookFilenameScanResult?
    @State private var resultFileCountOverride: Int?
    @State private var historicalResultDate: Date?
    @State private var fileSizes: [String: Int64] = [:]
    @State private var formattedFileSizes: [String: String] = [:]
    @State private var drmStatuses: [String: EbookDRMStatus] = [:]
    @State private var drmStats: DRMStats?
    @State private var displayedMatches: [EbookFilenameMatch] = []
    @State private var displayedGroups: [EbookFilenameGroup] = []
    @State private var groupsByID: [String: EbookFilenameGroup] = [:]
    @State private var selectedGroupID: String?
    @State private var task: Task<Void, Never>?
    @State private var history: [EbookFilenameHistory] = []
    @State private var isLoadingHistoryList = true
    @State private var showingHistory = false
    @State private var pendingHistoryDeletion: EbookFilenameHistory?
    @State private var resultTab = 0
    @State private var selectedFormat = "pdf"
    @State private var selectedForTrash: Set<String> = []
    @State private var removedPaths: Set<String> = []
    @State private var showingTrashConfirmation = false
    @State private var pendingTrashSelection: Set<String> = []
    @State private var cleanupMessage: String?
    @State private var encryptedFiles: [URL] = []
    @State private var loadingHistoryResultID: UUID?
    @State private var visibleMatchCount = 300
    @State private var visibleEncryptedCount = 300

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 14) {
                Label("电子书文件名快速查重", systemImage: "books.vertical.fill").font(.title2.bold())
                Text("只读取文件名，不打开正文；结果由你人工确认。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("查找位置").font(.headline)
                if roots.isEmpty { Text("尚未选择目录").font(.caption).foregroundStyle(.secondary) }
                ScrollView { VStack(spacing: 8) { ForEach(roots, id: \.self, content: rootRow) } }.frame(maxHeight: 190)
                Button("添加文件夹或 NAS…", systemImage: "plus", action: addFolder).disabled(scanning)
                Toggle("搜索子目录", isOn: $recursive).disabled(scanning)
                Toggle("快速判断 DRM", isOn: $quickDRMCheck).disabled(scanning)
                Text("仅检查 MOBI、AZW、AZW3 的加密字段；只标记检测到加密的文件。").font(.caption2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    HStack { Text("最低相似度"); Spacer(); Text("\(Int(minimum * 100))%") }
                    Slider(value: $minimum, in: 0.35...0.85, step: 0.05).disabled(scanning)
                    Text(minimum >= 0.85 ? "85% 模式会过滤大小比例低于 60% 的候选。" : "降低阈值会找到更多候选，也可能增加误报。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if scanning {
                    ProgressView()
                    Text("\(phase)：已检查 \(visitedCount) 项，发现 \(foundCount) 本电子书").font(.caption)
                    Text(currentPath).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button(isLoadingHistoryList ? "正在加载扫描历史…" : "扫描历史（\(history.count)）", systemImage: "clock.arrow.circlepath") { showingHistory = true }
                    .disabled(history.isEmpty || scanning || isLoadingHistoryList)
                Button(scanning ? "取消扫描" : "开始快速查重", systemImage: scanning ? "xmark" : "bolt.fill") {
                    scanning ? cancel() : scan()
                }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity).disabled(!scanning && roots.isEmpty)
            }.padding(18).navigationSplitViewColumnWidth(min: 290, ideal: 330)
        } detail: { detail.padding(22) }
        .onDisappear { task?.cancel() }
        .task {
            let loaded = await Task.detached(priority: .utility) { () -> Result<[EbookFilenameHistory], Error> in
                Result { try EbookFilenameHistoryStore.loadThrowing() }
            }.value
            switch loaded {
            case .success(let entries): history = entries
            case .failure(let error): cleanupMessage = "扫描历史读取失败：\(error.localizedDescription)"
            }
            isLoadingHistoryList = false
        }
        .sheet(isPresented: $showingHistory) { historyView.frame(minWidth: 720, minHeight: 480) }
        .confirmationDialog("将选中的本地文件移入废纸篓？", isPresented: $showingTrashConfirmation, titleVisibility: .visible) {
            Button("移入废纸篓（\(pendingTrashSelection.count) 项）", role: .destructive) { trashSelected() }
            Button("取消", role: .cancel) {}
        } message: { Text("NAS 文件会被跳过；每个重复候选组至少保留一份。") }
        .alert("清理结果", isPresented: Binding(get: { cleanupMessage != nil }, set: { if !$0 { cleanupMessage = nil } })) {
            Button("好") { cleanupMessage = nil }
        } message: { Text(cleanupMessage ?? "") }
    }

    private func rootRow(_ url: URL) -> some View {
        HStack(alignment: .top) {
            Image(systemName: url.path.hasPrefix("/Volumes/") ? "externaldrive.connected.to.line.below" : "folder.fill").foregroundStyle(.blue)
            VStack(alignment: .leading) { Text(url.lastPathComponent).lineLimit(1); Text(url.path).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
            Spacer(); Button { roots.removeAll { $0 == url } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).disabled(scanning)
        }.padding(8).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var detail: some View {
        if scanning && result == nil {
            ContentUnavailableView(phase.isEmpty ? "正在扫描文件名" : phase, systemImage: "magnifyingglass", description: Text("已检查 \(visitedCount) 项，发现 \(foundCount) 本电子书，可随时取消。"))
        } else if let result {
            VStack(alignment: .leading, spacing: 12) {
                HStack { metric("电子书", resultFileCountOverride ?? result.files.count); metric("候选组合", displayedGroups.count); metric("候选重复大小", duplicateSizeText); metric("耗时", String(format: "%.2f 秒", result.duration)); Spacer() }
                if let historicalResultDate {
                    Label("历史结果 · \(historicalResultDate.formatted())", systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let drmStats {
                    Label("DRM 快速判断：已检查 \(drmStats.checked) 本，检测到加密 \(drmStats.encrypted) 本\(drmStats.unknown > 0 ? "，无法判断 \(drmStats.unknown) 本" : "")", systemImage: drmStats.encrypted > 0 ? "lock.trianglebadge.exclamationmark" : "lock.open")
                        .font(.caption).foregroundStyle(drmStats.encrypted > 0 ? .orange : .secondary)
                }
                if !result.errors.isEmpty { Label("有 \(result.errors.count) 个目录无法读取", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                Picker("结果", selection: $resultTab) {
                    Text("重复候选（\(displayedGroups.count) 组）").tag(0)
                    Text("DRM 加密（\(encryptedFiles.count)）").tag(1)
                }.pickerStyle(.segmented)
                if resultTab == 0 {
                    if displayedGroups.isEmpty { ContentUnavailableView("未发现近似文件名", systemImage: "checkmark.circle", description: Text("可以降低相似度后重新扫描。")) }
                    else {
                        HStack {
                            Picker("指定格式", selection: $selectedFormat) { ForEach(["pdf", "epub", "mobi", "azw", "azw3"], id: \.self) { Text($0.uppercased()).tag($0) } }.frame(width: 180)
                            Button("选择该格式的重复文件") { selectDuplicates(format: selectedFormat) }
                            cleanupControls
                        }
                        VStack(spacing: 8) {
                            HSplitView {
                                EbookGroupListView(groups: Array(displayedGroups.prefix(visibleMatchCount)), selection: $selectedGroupID).frame(minWidth: 330)
                                if let group = selectedGroupID.flatMap({ groupsByID[$0] }) ?? displayedGroups.first { groupDetail(group) }
                            }
                            if visibleMatchCount < displayedGroups.count {
                                HStack { Text("已显示 \(visibleMatchCount) / \(displayedGroups.count) 组").font(.caption).foregroundStyle(.secondary); Button("再加载 300 组") { visibleMatchCount = min(visibleMatchCount + 300, displayedGroups.count) } }
                            }
                        }
                    }
                } else if encryptedFiles.isEmpty {
                    ContentUnavailableView("没有检测到加密文件", systemImage: "lock.open")
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Button("选择全部加密文件") { selectEncryptedFiles() }; cleanupControls }
                        List(encryptedFiles.prefix(visibleEncryptedCount), id: \.path) { url in fileSelectionRow(url) }
                        if visibleEncryptedCount < encryptedFiles.count {
                            HStack { Text("已显示 \(visibleEncryptedCount) / \(encryptedFiles.count) 本").font(.caption).foregroundStyle(.secondary); Button("再加载 300 本") { visibleEncryptedCount = min(visibleEncryptedCount + 300, encryptedFiles.count) } }
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("快速筛选相似电子书", systemImage: "books.vertical", description: Text("添加目录后开始扫描。支持 PDF、EPUB、MOBI、AZW 和 AZW3。"))
        }
    }

    private func metric(_ title: String, _ value: CustomStringConvertible) -> some View { VStack(alignment: .leading) { Text(value.description).font(.title2.bold()); Text(title).font(.caption).foregroundStyle(.secondary) }.padding(.trailing, 26) }
    private var duplicateSizeText: String {
        let values = displayedGroups.map { $0.duplicateBytes(fileSizes: fileSizes) }
        guard values.allSatisfy({ $0 != nil }) else { return "部分未知" }
        return ByteCountFormatter.string(fromByteCount: values.compactMap { $0 }.reduce(0, +), countStyle: .file)
    }
    private func groupDetail(_ group: EbookFilenameGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("人工确认 · \(group.files.count) 个文件").font(.title2.bold())
            Text("组内有 \(group.matches.count) 条直接相似关系，最高 \(Int(group.highestScore * 100))%。").font(.caption).foregroundStyle(.secondary)
            ScrollView { LazyVStack(spacing: 10) { ForEach(group.files, id: \.path) { fileCard($0) } } }
            Text("切换候选时不会重新读取、验证或打开文件。").font(.caption).foregroundStyle(.secondary)
        }.padding().frame(minWidth: 500)
    }
    private func fileCard(_ url: URL) -> some View { GroupBox { VStack(alignment: .leading, spacing: 7) { Text(url.lastPathComponent).font(.headline).textSelection(.enabled); Text("文件大小：\(formattedFileSize(url))").font(.caption).foregroundStyle(.secondary); if shouldHighlightDRM(url) { Label("已检测到加密", systemImage: "lock.trianglebadge.exclamationmark").font(.caption.bold()).foregroundStyle(.orange) }; Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled); HStack { selectionButton(url); Button("在访达中显示", systemImage: "folder") { FinderRevealer.reveal(url) } } }.frame(maxWidth: .infinity, alignment: .leading) } }

    @ViewBuilder private func selectionButton(_ url: URL) -> some View {
        let path = url.path
        Button(selectedForTrash.contains(path) ? "取消选择" : "选中待清理", systemImage: selectedForTrash.contains(path) ? "checkmark.circle.fill" : "circle") {
            if selectedForTrash.contains(path) { selectedForTrash.remove(path) } else { selectedForTrash.insert(path) }
        }
    }

    private func fileSelectionRow(_ url: URL) -> some View {
        HStack {
            selectionButton(url)
            VStack(alignment: .leading) {
                Text(url.lastPathComponent)
                Text("\(formattedFileSize(url)) · \(url.path)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { FinderRevealer.reveal(url) } label: {
                Label("在访达中显示", systemImage: "folder")
            }.buttonStyle(.borderless)
        }
    }

    private var cleanupControls: some View {
        HStack { Text("已选 \(selectedForTrash.count) 项").font(.caption).foregroundStyle(.secondary); Button("清除选择") { selectedForTrash = [] }.disabled(selectedForTrash.isEmpty); Button("移入废纸篓", role: .destructive) { prepareTrash() }.disabled(selectedForTrash.isEmpty) }
    }

    private var historyView: some View {
        NavigationStack {
            List(history) { entry in
                HStack {
                    VStack(alignment: .leading) {
                        Text(entry.date.formatted())
                        Text("\(entry.fileCount) 本 · \(entry.pairs.count) 组 · \(String(format: "%.1f 秒", entry.duration))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { showHistoryResult(entry) } label: {
                        if loadingHistoryResultID == entry.id { ProgressView().controlSize(.small) }
                        else { Text("查看结果") }
                    }.buttonStyle(.bordered).disabled(loadingHistoryResultID != nil)
                    Button(role: .destructive) { pendingHistoryDeletion = entry } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("删除这条历史记录")
                }
            }
            .navigationTitle("电子书快速查重历史")
            .toolbar { Button("完成") { showingHistory = false } }
            .confirmationDialog("删除这条扫描历史？", isPresented: Binding(
                get: { pendingHistoryDeletion != nil }, set: { if !$0 { pendingHistoryDeletion = nil } }
            ), titleVisibility: .visible) {
                Button("删除历史记录", role: .destructive) {
                    do {
                        if let entry = pendingHistoryDeletion { history = try EbookFilenameHistoryStore.delete(entry.id) }
                    } catch { cleanupMessage = "扫描历史删除失败：\(error.localizedDescription)" }
                    pendingHistoryDeletion = nil
                }
                Button("取消", role: .cancel) { pendingHistoryDeletion = nil }
            } message: { Text("仅删除本机保存的扫描记录，不会删除电子书文件。") }
        }
    }

    private func formattedFileSize(_ url: URL) -> String {
        formattedFileSizes[url.path] ?? "未知"
    }

    private func prepareFormattedFileSizes(_ sizes: [String: Int64]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: sizes.map { path, size in
            (path, ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        })
    }

    nonisolated private static func grouped(_ matches: [EbookFilenameMatch], sizes: [String: Int64]) -> [EbookFilenameGroup] {
        EbookFilenameSimilarity.groups(from: matches).sorted { lhs, rhs in
            let left = lhs.files.map { sizes[$0.path] ?? -1 }.max() ?? -1
            let right = rhs.files.map { sizes[$0.path] ?? -1 }.max() ?? -1
            if left != right { return left > right }
            if lhs.highestScore != rhs.highestScore { return lhs.highestScore > rhs.highestScore }
            return lhs.id < rhs.id
        }
    }

    private func shouldHighlightDRM(_ url: URL) -> Bool {
        ["mobi", "azw", "azw3"].contains(url.pathExtension.lowercased())
            && drmStatuses[url.path] == .suspected
    }

    private func showHistoryResult(_ entry: EbookFilenameHistory) {
        loadingHistoryResultID = entry.id
        Task {
            let prepared = await Task.detached(priority: .userInitiated) { () -> PreparedHistoryResult in
                let matches = entry.pairs.map { EbookFilenameMatch(first: URL(fileURLWithPath: $0.first), second: URL(fileURLWithPath: $0.second), score: $0.score) }
                let encrypted = (entry.encryptedFiles ?? []).map { URL(fileURLWithPath: $0.path) }
                let files = Array(Set(matches.flatMap { [$0.first, $0.second] } + encrypted)).sorted { $0.path < $1.path }
                let sizes = Dictionary(entry.pairs.flatMap { pair in
                    [(pair.first, pair.firstSize), (pair.second, pair.secondSize)].compactMap { path, size in size.map { (path, $0) } }
                } + (entry.encryptedFiles ?? []).compactMap { file in file.size.map { (file.path, $0) } }, uniquingKeysWith: { first, _ in first })
                var statuses = Dictionary(entry.pairs.flatMap { pair in
                    [(pair.first, pair.firstDRM), (pair.second, pair.secondDRM)].compactMap { path, status in status.map { (path, $0) } }
                }, uniquingKeysWith: { first, _ in first })
                for url in encrypted { statuses[url.path] = .suspected }
                let sorted = matches.sorted { lhs, rhs in
                    let left = max(sizes[lhs.first.path] ?? -1, sizes[lhs.second.path] ?? -1)
                    let right = max(sizes[rhs.first.path] ?? -1, sizes[rhs.second.path] ?? -1)
                    return left != right ? left > right : lhs.score != rhs.score ? lhs.score > rhs.score : lhs.id < rhs.id
                }
                let groups = Self.grouped(sorted, sizes: sizes)
                let stats = entry.drmCheckedCount.map { DRMStats(checked: $0, encrypted: entry.drmEncryptedCount ?? 0, unknown: entry.drmUnknownCount ?? 0) }
                return .init(result: .init(files: files, matches: matches, errors: [], duration: entry.duration, drmStatuses: statuses, fileSizes: sizes), fileSizes: sizes, drmStatuses: statuses, drmStats: stats, matches: sorted, groups: groups, groupsByID: Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) }), encryptedFiles: encrypted.sorted { (sizes[$0.path] ?? -1) > (sizes[$1.path] ?? -1) }, date: entry.date, fileCount: entry.fileCount)
            }.value
            result = prepared.result; resultFileCountOverride = prepared.fileCount; historicalResultDate = prepared.date
            fileSizes = prepared.fileSizes; formattedFileSizes = prepareFormattedFileSizes(prepared.fileSizes)
            drmStatuses = prepared.drmStatuses; drmStats = prepared.drmStats
            displayedMatches = prepared.matches; displayedGroups = prepared.groups; groupsByID = prepared.groupsByID; encryptedFiles = prepared.encryptedFiles
            visibleMatchCount = min(300, prepared.groups.count); visibleEncryptedCount = min(300, prepared.encryptedFiles.count)
            selectedGroupID = prepared.groups.first?.id; loadingHistoryResultID = nil; showingHistory = false
        }
    }

    private func selectDuplicates(format: String) {
        let paths = displayedGroups.flatMap(\.files)
            .filter { $0.pathExtension.lowercased() == format }.map(\.path)
        selectedForTrash.formUnion(paths)
        selectedForTrash = validatedSelection(selectedForTrash)
    }

    private func selectEncryptedFiles() {
        selectedForTrash.formUnion(encryptedFiles.map(\.path))
        selectedForTrash = validatedSelection(selectedForTrash)
    }

    private func validatedSelection(_ proposed: Set<String>) -> Set<String> {
        var safe = proposed.subtracting(removedPaths)
        for group in displayedGroups {
            let paths = group.files.map(\.path)
            if !paths.isEmpty && paths.allSatisfy(safe.contains) { safe.remove(paths.min()!) }
        }
        return safe
    }

    private func prepareTrash() {
        pendingTrashSelection = validatedSelection(selectedForTrash)
        guard !pendingTrashSelection.isEmpty else {
            cleanupMessage = "为确保每个重复候选组至少保留一份，没有可安全清理的文件。"
            return
        }
        showingTrashConfirmation = true
    }

    private func trashSelected() {
        let paths = pendingTrashSelection
        let urls = Dictionary(uniqueKeysWithValues: (result?.files ?? []).map { ($0.path, $0) })
        pendingTrashSelection = []
        Task {
            let outcome = await Task.detached(priority: .utility) { () -> (Set<String>, Int, [String]) in
                var removed: Set<String> = [], skipped = 0, failures: [String] = []
                for path in paths {
                    guard let url = urls[path] else { failures.append("找不到记录：\(path)"); continue }
                    do {
                        guard try url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal == true else { skipped += 1; continue }
                        var trashed: NSURL?
                        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
                        removed.insert(path)
                    } catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
                }
                return (removed, skipped, failures)
            }.value
            removedPaths.formUnion(outcome.0); selectedForTrash.subtract(outcome.0)
            displayedMatches.removeAll { outcome.0.contains($0.first.path) || outcome.0.contains($0.second.path) }
            displayedGroups = Self.grouped(displayedMatches, sizes: fileSizes)
            groupsByID = Dictionary(uniqueKeysWithValues: displayedGroups.map { ($0.id, $0) })
            encryptedFiles.removeAll { outcome.0.contains($0.path) }
            visibleMatchCount = min(visibleMatchCount, displayedGroups.count); visibleEncryptedCount = min(visibleEncryptedCount, encryptedFiles.count)
            if selectedGroupID.flatMap({ groupsByID[$0] }) == nil { selectedGroupID = displayedGroups.first?.id }
            cleanupMessage = "已将 \(outcome.0.count) 个本地文件移入废纸篓；跳过 \(outcome.1) 个 NAS 文件；失败 \(outcome.2.count) 个。" + (outcome.2.isEmpty ? "" : "\n" + outcome.2.prefix(5).joined(separator: "\n"))
        }
    }

    private func addFolder() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true; guard panel.runModal() == .OK else { return }; for url in panel.urls where !roots.contains(url) { roots.append(url) } }
    private func cancel() { task?.cancel(); task = nil; scanning = false; currentPath = "" }
    private func scan() {
        scanning = true; foundCount = 0; visitedCount = 0; phase = "正在枚举目录"; currentPath = "准备扫描…"; result = nil; resultFileCountOverride = nil; historicalResultDate = nil; fileSizes = [:]; formattedFileSizes = [:]; drmStatuses = [:]; drmStats = nil; displayedMatches = []; displayedGroups = []; groupsByID = [:]; selectedGroupID = nil; encryptedFiles = []; removedPaths = []; selectedForTrash = []; visibleMatchCount = 300; visibleEncryptedCount = 300
        let scanRoots = roots, scanRecursive = recursive, scanMinimum = minimum, scanDRM = quickDRMCheck
        task = Task {
            let output = await EbookFilenameScanner.scan(roots: scanRoots, recursive: scanRecursive, minimum: scanMinimum, quickDRMCheck: scanDRM) { books, visited, path, newPhase in
                Task { @MainActor in
                    foundCount = books; visitedCount = visited; currentPath = path
                    switch newPhase {
                    case "索引": phase = "正在建立文件名索引"
                    case "DRM": phase = "正在快速判断 DRM"
                    case "完成": phase = "正在整理结果"
                    default: phase = "正在枚举目录"
                    }
                }
            }
            guard !Task.isCancelled else { return }
            phase = "正在整理结果"; currentPath = "正在生成内存结果，不再访问电子书文件"
            let prepared = await Task.detached(priority: .userInitiated) { () -> PreparedScanResult in
                let formatted = Dictionary(uniqueKeysWithValues: output.fileSizes.map { path, size in
                    (path, ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                })
                let encrypted = output.files.filter { output.drmStatuses[$0.path] == .suspected }
                    .sorted { (output.fileSizes[$0.path] ?? -1) > (output.fileSizes[$1.path] ?? -1) }
                let sorted = output.matches.sorted { lhs, rhs in
                    let left = max(output.fileSizes[lhs.first.path] ?? -1, output.fileSizes[lhs.second.path] ?? -1)
                    let right = max(output.fileSizes[rhs.first.path] ?? -1, output.fileSizes[rhs.second.path] ?? -1)
                    if left != right { return left > right }
                    if lhs.score != rhs.score { return lhs.score > rhs.score }
                    return lhs.id < rhs.id
                }
                let stats = scanDRM ? DRMStats(checked: output.drmStatuses.values.filter { $0 != .unknown }.count,
                    encrypted: output.drmStatuses.values.filter { $0 == .suspected }.count,
                    unknown: output.drmStatuses.values.filter { $0 == .unknown }.count) : nil
                let groups = Self.grouped(sorted, sizes: output.fileSizes)
                return .init(formattedSizes: formatted, drmStats: stats, matches: sorted, groups: groups,
                             groupsByID: Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) }),
                             encryptedFiles: encrypted)
            }.value
            guard !Task.isCancelled else { return }
            fileSizes = output.fileSizes
            formattedFileSizes = prepared.formattedSizes
            drmStatuses = output.drmStatuses
            encryptedFiles = prepared.encryptedFiles
            drmStats = prepared.drmStats
            displayedMatches = prepared.matches
            displayedGroups = prepared.groups
            visibleMatchCount = min(300, displayedGroups.count); visibleEncryptedCount = min(300, encryptedFiles.count)
            groupsByID = prepared.groupsByID
            result = output; selectedGroupID = displayedGroups.first?.id; scanning = false; phase = "扫描完成"; currentPath = ""; task = nil
            let saved = await Task.detached(priority: .utility) { () -> Result<[EbookFilenameHistory], Error> in
                let entry = EbookFilenameHistory(roots: scanRoots, result: output)
                return Result { try EbookFilenameHistoryStore.save(entry) }
            }.value
            switch saved {
            case .success(let entries): history = entries
            case .failure(let error): cleanupMessage = "扫描已完成，但历史保存失败：\(error.localizedDescription)"
            }
        }
    }
}

private struct EbookGroupListView: View {
    let groups: [EbookFilenameGroup]
    @Binding var selection: String?

    var body: some View {
        List(groups, selection: $selection) { group in
            VStack(alignment: .leading, spacing: 4) {
                Text("\(group.files.count) 个文件 · 最高 \(Int(group.highestScore * 100))% 相似").font(.headline).foregroundStyle(.indigo)
                ForEach(group.files.prefix(3), id: \.path) { Text($0.lastPathComponent).lineLimit(1).foregroundStyle(.secondary) }
                if group.files.count > 3 { Text("另有 \(group.files.count - 3) 个文件…").font(.caption).foregroundStyle(.tertiary) }
            }
            .padding(.vertical, 4)
            .tag(group.id)
        }
    }
}
