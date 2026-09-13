import DuplicateCore
import SwiftUI
import QuickLook

struct DuplicateFilesView: View {
    @StateObject private var model = ScanViewModel()
    @State private var showingTrashConfirmation = false
    @State private var resultMode = 0
    @State private var showSettings = false
    @State private var comparison: SimilarImageGroup?
    @State private var preview: URL?

    var body: some View {
        NavigationSplitView {
            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9).fill(.blue.gradient).frame(width: 38, height: 38)
                        Image(systemName: "square.on.square.dashed").font(.title3.bold()).foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("觅重").font(.title2.bold())
                        Text("本地、安全、高效").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker("扫描方式", selection: $model.scanMode) {
                    Text("普通查重").tag(ScanMode.standard)
                    Text("A/B 对比").tag(ScanMode.reference)
                }.pickerStyle(.segmented).disabled(model.isScanning || model.isCleaning)
                if model.scanMode == .reference {
                    sourceSection("A · 已整理资料库", roots: model.referenceRoots, isReference: true)
                    Label("A 始终保留，仅比较 A 与 B 之间的重复内容。", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
                sourceSection(model.scanMode == .reference ? "B · 待整理目录" : "扫描位置", roots: model.roots, isReference: false)
                Divider()
                Toggle("搜索子目录", isOn: $model.recursive).disabled(model.isScanning || model.isCleaning)
                Toggle("包含隐藏文件", isOn: $model.includeHidden).disabled(model.isScanning || model.isCleaning)
                Toggle("识别重复文件夹", isOn: $model.detectDuplicateFolders)
                    .disabled(model.isScanning || model.isCleaning)
                    .help("比较文件夹内符合筛选条件的相对路径与文件内容，可能需要读取更多文件。")
                Toggle("查找相似图片", isOn: $model.similarImages)
                    .disabled(model.isScanning || model.isCleaning)
                    .help("默认关闭。开启后分析常见图片格式。")
                if model.similarImages {
                    Picker("匹配程度", selection: $model.threshold) {
                        Text("严格").tag(4); Text("标准").tag(8); Text("宽松").tag(12)
                    }.pickerStyle(.segmented)
                        .disabled(model.isScanning || model.isCleaning)
                }
                GroupBox("文件大小过滤") {
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                        GridRow {
                            Text("最小")
                            TextField("0", value: $model.minimumSizeMB, format: .number)
                                .frame(width: 72)
                            Text("MiB")
                        }
                        GridRow {
                            Text("最大")
                            TextField("不限", value: $model.maximumSizeMB, format: .number)
                                .frame(width: 72)
                            Text("MiB · 0 不限").foregroundStyle(.secondary)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                }
                .disabled(model.isScanning || model.isCleaning)
                Button("更多设置…", systemImage: "slider.horizontal.3") { showSettings = true }
                    .disabled(model.isScanning || model.isCleaning)
                Button("历史任务…", systemImage: "clock.arrow.circlepath") {
                    model.showHistory = true; model.refreshHistory()
                }.disabled(model.isScanning || model.isCleaning)
                Text("任务自动保存到本机，可恢复结果并继续扫描。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.isRestoredSession && model.result == nil {
                    Button("继续原任务", systemImage: "arrow.clockwise") { model.resumeActiveSession() }
                        .disabled(!model.canResumeSavedTask)
                }
                if model.isScanning {
                    Button(model.isPaused ? "继续扫描" : "暂停扫描", systemImage: model.isPaused ? "play.fill" : "pause.fill") { model.pauseResume() }
                        .disabled(model.isCancelling)
                }
                Button(model.isScanning ? "取消扫描" : "开始新扫描") {
                    model.isScanning ? model.cancel() : model.scan()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(model.isCancelling || model.isCleaning || model.isLoadingHistory)
            }
            .padding(18)
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        } detail: {
            ZStack {
                LinearGradient(colors: [Color.accentColor.opacity(0.055), .clear], startPoint: .topLeading, endPoint: .center)
                    .ignoresSafeArea()
                Group {
                if model.isScanning { scanningView }
                else if let result = model.result { resultsView(result) }
                else { welcomeView }
                }
            }
            .padding(22)
            .toolbar {
                Menu {
                    Button("导出 CSV") { model.exportCSV() }
                    Button("导出 JSON（全部结果与任务状态）") { model.exportCSV(json: true) }
                } label: { Label("导出报告", systemImage: "square.and.arrow.up") }
                    .disabled(model.result == nil || model.isScanning || model.isCleaning)
                Button("移至废纸篓", systemImage: "trash") { showingTrashConfirmation = true }
                    .disabled(model.selectedForTrash.isEmpty || !model.canCleanResults)
            }
        }
        .alert("觅重", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("好") { model.alertMessage = nil }
        } message: { Text(model.alertMessage ?? "") }
        .sheet(isPresented: $showSettings) { SettingsView(model: model) }
        .sheet(isPresented: $model.showHistory) { SessionHistoryView(model: model) }
        .sheet(item: $comparison) { ComparisonView(group: $0) }
        .quickLookPreview($preview)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.cancel() }
        .onChange(of: model.result?.sessionID) { _, _ in resultMode = 0 }
        .sheet(isPresented: $model.showErrors) {
            VStack(alignment: .leading) {
                Text("读取错误与跳过记录").font(.title2)
                ScrollView { Text(model.result?.errors.joined(separator: "\n") ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button("关闭") { model.showErrors = false }
                    Spacer()
                    if model.activeSessionURL != nil && model.result?.isIncomplete == true {
                        Button("继续原任务并重试") { model.showErrors = false; model.resumeActiveSession() }
                            .disabled(!model.canResumeSavedTask)
                    }
                }
            }.padding(24).frame(width: 720, height: 480)
        }
        .sheet(isPresented: $showingTrashConfirmation) {
            VStack(alignment: .leading, spacing: 16) {
                Text("确认移至废纸篓").font(.title2.bold())
                Text("共 \(model.selectedForTrash.count) 个本地文件。执行前会重新校验内容并保留一份原件。")
                ScrollView { Text(model.selectedForTrash.map(\.path).sorted().joined(separator: "\n")).font(.caption).textSelection(.enabled) }
                HStack {
                    Button("取消") { showingTrashConfirmation = false }
                    Spacer()
                    Button("确认移至废纸篓", role: .destructive) {
                        showingTrashConfirmation = false; model.trashSelected()
                    }
                }
            }.padding(24).frame(width: 680, height: 440)
        }
    }

    private var welcomeView: some View {
        VStack(spacing: 20) {
            ContentUnavailableView("让资料各归其位", systemImage: "doc.on.doc",
                description: Text("添加本地文件夹或已挂载的 NAS。\n使用 A/B 对比整理新资料，历史任务可随时恢复。"))
            HStack(spacing: 22) {
                Label("NAS 只读", systemImage: "lock.shield")
                Label("任务自动保存", systemImage: "clock.arrow.circlepath")
                Label("本机处理", systemImage: "desktopcomputer")
            }.font(.callout).foregroundStyle(.secondary)
        }
    }

    private func sourceSection(_ title: String, roots: [URL], isReference: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if roots.isEmpty {
                Text(isReference ? "添加作为对比基准的资料库" : "添加本地目录或已挂载的 NAS")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(roots, id: \.self) { url in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: isReference ? "lock.folder" : url.path.hasPrefix("/Volumes/") ? "externaldrive.connected.to.line.below" : "folder")
                        .foregroundStyle(isReference ? .green : .blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(url.lastPathComponent).font(.callout).lineLimit(1)
                        Text(url.path).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        if model.shallowPaths.contains(url.path) {
                            Text("仅顶层").font(.caption2).foregroundStyle(.orange)
                        }
                    }.help(url.path)
                    Spacer(minLength: 0)
                    Button {
                        if isReference { model.referenceRoots.removeAll { $0 == url } }
                        else { model.roots.removeAll { $0 == url } }
                    } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("移除此扫描位置")
                }
                .padding(9).background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                .contextMenu {
                    Button(model.shallowPaths.contains(url.path) ? "启用此目录子目录搜索" : "仅扫描此目录顶层") {
                        if model.shallowPaths.contains(url.path) { model.shallowPaths.remove(url.path) }
                        else { model.shallowPaths.insert(url.path) }
                    }
                }
            }
            Button(isReference ? "添加 A 资料库…" : "添加文件夹或 NAS…", systemImage: "plus") {
                isReference ? model.addReferenceFolder() : model.addFolder()
            }
        }.disabled(model.isScanning || model.isCleaning)
    }

    private var scanningView: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            Text(model.isCancelling ? "正在取消，等待当前读取返回…" : model.isPaused ? "扫描已暂停" : phaseText(model.progress.phase)).font(.title2)
            Text("本阶段 \(model.progress.discovered) 个文件 · 已处理 \(model.progress.processed) 个")
            Text(model.progress.currentPath).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                .frame(maxWidth: 520)
            Label("任务进度定期保存在本机", systemImage: "clock.arrow.circlepath")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultsView(_ result: ScanResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                metric("扫描文件", "\(result.scannedFiles)")
                metric("重复组", "\(result.groups.count)")
                if model.resultIncludesSimilarImages { metric("相似图片组", "\(result.similarImageGroups.count)") }
                metric("重复副本体积", ByteCountFormatter.string(fromByteCount: Int64(result.reclaimableBytes), countStyle: .file))
                metric("耗时", String(format: "%.1f 秒", result.duration))
            }
            HStack {
                Label(result.wasCancelled ? "已取消 · 部分结果" : result.isIncomplete ? "扫描未完整 · 有待重试项目" : "扫描完成 · 缓存命中 \(result.cacheHits) 次",
                      systemImage: result.wasCancelled || result.isIncomplete ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(result.wasCancelled || result.isIncomplete ? .orange : .secondary)
                Spacer()
                if !result.errors.isEmpty { Button("查看 \(result.errors.count) 条错误") { model.showErrors = true } }
            }
            if model.isRestoredSession || result.isIncomplete || result.wasCancelled || !result.sessionSaved {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.isRestoredSession ? "已恢复历史结果 · 当前仅供查看" : result.sessionSaved ? "任务已保存，可继续原任务" : "本次任务进度未完整保存")
                            .font(.callout.weight(.semibold))
                        Text(model.hasSavedTask ? "继续时会核验文件变化，并重新处理未完成项目。NAS 如已断开，请先在 Finder 中重新挂载。" : "没有可用的任务记录。可先导出当前结果，再开始新扫描。")
                            .font(.caption).foregroundStyle(.secondary)
                        if !result.sessionSaved, !model.isRestoredSession,
                           let issue = result.errors.first(where: { $0.hasPrefix("任务保存失败") }) {
                            Text(issue).font(.caption).foregroundStyle(.orange)
                        }
                        if !result.pendingPaths.isEmpty {
                            Text("待处理位置：\(result.pendingPaths.count) 项").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if model.activeSessionURL != nil {
                        Button(!result.sessionSaved && !model.isRestoredSession ? "从已存检查点继续" : model.isRestoredSession && !result.isIncomplete && !result.wasCancelled ? "核验并恢复审核" : "继续原任务") {
                            model.resumeActiveSession()
                        }.disabled(!model.canResumeSavedTask)
                    }
                }.padding(12).background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                TextField("按文件名或路径筛选结果", text: $model.searchText).textFieldStyle(.roundedBorder)
                Button("建议保留一份") { model.autoSelect() }.disabled(!model.canCleanResults || resultMode != 0)
                Button("清空选择") { model.selectedForTrash = []; model.saveReview() }
            }
            if model.resultIncludesSimilarImages || model.resultIncludesDuplicateFolders || result.mode == .reference {
                Picker("结果类型", selection: $resultMode) {
                    Text("完全重复 \(result.groups.count)").tag(0)
                    if model.resultIncludesSimilarImages { Text("相似图片 \(result.similarImageGroups.count)").tag(1) }
                    if model.resultIncludesDuplicateFolders { Text("重复文件夹 \(result.duplicateFolderGroups.count)").tag(2) }
                    if result.mode == .reference { Text("B 中独有 \(result.uniqueFiles.count)").tag(3) }
                }.pickerStyle(.segmented)
            }
            if result.mode == .reference && resultMode == 0 {
                Text("只展示 A 与 B 之间的完全重复内容。A 资料库始终保留。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if resultMode == 1 && model.resultIncludesSimilarImages {
                similarImagesView(result)
            } else if resultMode == 2 && model.resultIncludesDuplicateFolders {
                duplicateFoldersView(result)
            } else if resultMode == 3 && result.mode == .reference {
                uniqueFilesView(result)
            } else if result.groups.isEmpty {
                ContentUnavailableView("没有发现完全重复文件", systemImage: "doc.text.magnifyingglass", description: Text(result.isIncomplete || result.wasCancelled ? "这是部分结果，请继续原任务以完成确认。" : "本次扫描范围内未找到内容完全相同的文件。"))
            } else {
                List(result.groups.filter { group in model.searchText.isEmpty || group.files.contains { $0.id.localizedCaseInsensitiveContains(model.searchText) } }) { group in
                    DisclosureGroup {
                        ForEach(group.files) { file in
                            HStack {
                                Toggle("", isOn: selectionBinding(file.url)).labelsHidden().disabled(!model.canSelect(file))
                                Image(systemName: model.isReference(file.url) ? "lock.doc" : file.isNetworkVolume ? "lock.shield" : "doc")
                                VStack(alignment: .leading) {
                                    HStack {
                                        Text(file.url.lastPathComponent)
                                        if result.mode == .reference { libraryBadge(file.url) }
                                    }
                                    Text(file.url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary)
                                    Text(file.modifiedAt?.formatted() ?? "").font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)).foregroundStyle(.secondary)
                                Button { preview = file.url } label: { Image(systemName: "eye") }.buttonStyle(.plain)
                                Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Image(systemName: "folder") }.buttonStyle(.plain)
                            }
                        }
                    } label: {
                        Text("\(group.files.count) 个副本 · 重复体积 \(ByteCountFormatter.string(fromByteCount: Int64(group.reclaimableBytes), countStyle: .file))")
                    }
                }.scrollContentBackground(.hidden)
            }
        }
    }

    private func libraryBadge(_ url: URL) -> some View {
        Text(model.isReference(url) ? "A · 保留" : "B · 待整理")
            .font(.caption2.weight(.medium))
            .foregroundStyle(model.isReference(url) ? .green : .blue)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((model.isReference(url) ? Color.green : Color.blue).opacity(0.1), in: Capsule())
    }

    private func duplicateFoldersView(_ result: ScanResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("按本次筛选范围内的相对路径与文件内容比较。被排除的文件不参与；此处仅供查看，不提供整夹清理。")
                .font(.caption).foregroundStyle(.secondary)
            if result.duplicateFolderGroups.isEmpty {
                ContentUnavailableView("没有发现重复文件夹", systemImage: "folder.badge.questionmark", description: Text("文件夹需包含相同的相对文件路径与内容。"))
            } else {
                List(result.duplicateFolderGroups.filter { group in
                    model.searchText.isEmpty || group.folders.contains { $0.path.localizedCaseInsensitiveContains(model.searchText) }
                }) { group in
                    DisclosureGroup {
                        ForEach(group.folders, id: \.self) { folder in
                            HStack {
                                Image(systemName: "folder").foregroundStyle(.blue)
                                Text(folder.path).textSelection(.enabled)
                                if result.mode == .reference { libraryBadge(folder) }
                                Spacer()
                                Button { NSWorkspace.shared.activateFileViewerSelecting([folder]) } label: { Image(systemName: "folder.badge.gearshape") }
                                    .buttonStyle(.plain).help("在 Finder 中显示")
                            }.padding(.vertical, 4)
                        }
                    } label: {
                        Text("\(group.folders.count) 个文件夹 · 每夹 \(group.fileCount) 个文件 · \(ByteCountFormatter.string(fromByteCount: Int64(group.totalBytes), countStyle: .file))")
                    }
                }.scrollContentBackground(.hidden)
            }
        }
    }

    private func uniqueFilesView(_ result: ScanResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("列出 B 中未在 A 资料库找到相同内容的文件；B 内部仍可能存在重复。判断范围受本次大小、类型和目录筛选影响。")
                .font(.caption).foregroundStyle(.secondary)
            if result.isIncomplete || result.wasCancelled {
                ContentUnavailableView("独有文件尚待确认", systemImage: "clock", description: Text("扫描尚未完整，请继续原任务后查看结论。"))
            } else if result.uniqueFiles.isEmpty {
                ContentUnavailableView("B 中没有独有文件", systemImage: "checkmark.circle", description: Text("本次范围内的 B 文件均已在 A 中找到相同内容，或没有符合筛选条件的文件。"))
            } else {
                List(result.uniqueFiles.filter { model.searchText.isEmpty || $0.id.localizedCaseInsensitiveContains(model.searchText) }) { file in
                    HStack {
                        Image(systemName: "doc.badge.plus").foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.url.lastPathComponent)
                            Text(file.url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)).foregroundStyle(.secondary)
                        Button { preview = file.url } label: { Image(systemName: "eye") }.buttonStyle(.plain)
                        Button { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } label: { Image(systemName: "folder") }.buttonStyle(.plain)
                    }
                }.scrollContentBackground(.hidden)
            }
        }
    }

    private func similarImagesView(_ result: ScanResult) -> some View {
        Group {
            if result.similarImageGroups.isEmpty {
                ContentUnavailableView("没有发现相似图片", systemImage: "photo.stack", description: Text("可以尝试扫描包含更多图片的目录。"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(result.similarImageGroups.filter { group in model.searchText.isEmpty || group.files.contains { $0.id.localizedCaseInsensitiveContains(model.searchText) } }) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Label("\(group.files.count) 张相似图片", systemImage: "photo.stack")
                                        .font(.headline)
                                    Spacer()
                                    Button("并排对比") { comparison = group }
                                    Text("指纹接近度 \(Int(group.similarity * 100))%")
                                        .font(.caption.bold()).foregroundStyle(.blue)
                                        .padding(.horizontal, 9).padding(.vertical, 5).background(.blue.opacity(0.1), in: Capsule())
                                }
                                ScrollView(.horizontal) {
                                    LazyHStack(spacing: 10) {
                                        ForEach(group.files) { file in
                                            VStack(alignment: .leading, spacing: 5) {
                                                ThumbnailView(url: file.url).frame(width: 150, height: 105)
                                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                                Text(file.url.lastPathComponent).lineLimit(1).font(.caption).frame(width: 150, alignment: .leading)
                                                Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                                                    .font(.caption2).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }.scrollIndicators(.hidden)
                            }
                            .padding(14).background(.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.5)))
                        }
                    }
                }
            }
        }
    }

    private func selectionBinding(_ url: URL) -> Binding<Bool> {
        Binding(get: { model.selectedForTrash.contains(url) }, set: { value in
            if value {
                guard model.canCleanResults,
                      let file = model.result?.groups.flatMap(\.files).first(where: { $0.url == url }), model.canSelect(file) else { return }
                guard let group = model.result?.groups.first(where: { $0.files.contains(where: { $0.url == url }) }),
                      group.files.filter({ model.selectedForTrash.contains($0.url) }).count < group.files.count - 1 else {
                    model.alertMessage = "每组至少保留一份。"; return
                }
                model.selectedForTrash.insert(url)
            } else { model.selectedForTrash.remove(url) }
            model.saveReview()
        })
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) { Text(value).font(.title2.bold()); Text(title).foregroundStyle(.secondary) }
            .padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.35)))
    }

    private func phaseText(_ phase: ScanProgress.Phase) -> String {
        switch phase {
        case .validatingSession: "正在核验任务与文件变化"
        case .discovering: "正在查找文件"
        case .fingerprinting: "正在快速筛选"
        case .hashing: "正在确认重复内容"
        case .analyzingImages: "正在分析相似图片"
        case .comparingFolders: "正在比较文件夹结构与内容"
        case .finished: "扫描完成"
        }
    }
}
