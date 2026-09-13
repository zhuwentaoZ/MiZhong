import AppKit
import DuplicateCore
import QuickLookUI
import SwiftUI

struct EbookFilenameView: View {
    @State private var roots: [URL] = []
    @State private var recursive = true
    @State private var minimum = 0.55
    @State private var scanning = false
    @State private var foundCount = 0
    @State private var visitedCount = 0
    @State private var phase = ""
    @State private var currentPath = ""
    @State private var result: EbookFilenameScanResult?
    @State private var resultFileCountOverride: Int?
    @State private var historicalResultDate: Date?
    @State private var selected: EbookFilenameMatch?
    @State private var task: Task<Void, Never>?
    @State private var history = EbookFilenameHistoryStore.load()
    @State private var showingHistory = false
    @State private var pendingHistoryDeletion: EbookFilenameHistory?

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
                VStack(alignment: .leading, spacing: 5) {
                    HStack { Text("最低相似度"); Spacer(); Text("\(Int(minimum * 100))%") }
                    Slider(value: $minimum, in: 0.35...0.85, step: 0.05).disabled(scanning)
                    Text("降低阈值会找到更多候选，也可能增加误报。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if scanning {
                    ProgressView()
                    Text("\(phase)：已检查 \(visitedCount) 项，发现 \(foundCount) 本电子书").font(.caption)
                    Text(currentPath).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("扫描历史（\(history.count)）", systemImage: "clock.arrow.circlepath") { showingHistory = true }.disabled(history.isEmpty || scanning)
                Button(scanning ? "取消扫描" : "开始快速查重", systemImage: scanning ? "xmark" : "bolt.fill") {
                    scanning ? cancel() : scan()
                }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity).disabled(!scanning && roots.isEmpty)
            }.padding(18).navigationSplitViewColumnWidth(min: 290, ideal: 330)
        } detail: { detail.padding(22) }
        .onDisappear { task?.cancel() }
        .sheet(isPresented: $showingHistory) { historyView.frame(minWidth: 720, minHeight: 480) }
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
                HStack { metric("电子书", resultFileCountOverride ?? result.files.count); metric("候选组合", result.matches.count); metric("耗时", String(format: "%.2f 秒", result.duration)); Spacer() }
                if let historicalResultDate {
                    Label("历史结果 · \(historicalResultDate.formatted())", systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !result.errors.isEmpty { Label("有 \(result.errors.count) 个目录无法读取", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if result.matches.isEmpty { ContentUnavailableView("未发现近似文件名", systemImage: "checkmark.circle", description: Text("可以降低相似度后重新扫描。")) }
                else { HSplitView { List(result.matches, selection: $selected) { match in matchRow(match).tag(match) }.frame(minWidth: 330); matchDetail(selected ?? result.matches[0]) } }
            }
        } else {
            ContentUnavailableView("快速筛选相似电子书", systemImage: "books.vertical", description: Text("添加目录后开始扫描。支持 PDF、EPUB、MOBI 和 AZW3。"))
        }
    }

    private func metric(_ title: String, _ value: CustomStringConvertible) -> some View { VStack(alignment: .leading) { Text(value.description).font(.title2.bold()); Text(title).font(.caption).foregroundStyle(.secondary) }.padding(.trailing, 26) }
    private func matchRow(_ match: EbookFilenameMatch) -> some View { VStack(alignment: .leading, spacing: 4) { Text("\(Int(match.score * 100))% 相似").font(.headline).foregroundStyle(.indigo); Text(match.first.lastPathComponent).lineLimit(1); Text(match.second.lastPathComponent).lineLimit(1).foregroundStyle(.secondary) }.padding(.vertical, 4) }
    private func matchDetail(_ match: EbookFilenameMatch) -> some View { VStack(alignment: .leading, spacing: 12) { HStack { Text("人工确认").font(.title2.bold()); Spacer(); Button("同时打开", systemImage: "rectangle.split.2x1") { [match.first, match.second].forEach { NSWorkspace.shared.open($0) } } }; HStack { quickPreview(match.first); quickPreview(match.second) }.frame(minHeight: 280); fileCard(match.first); fileCard(match.second); Text("预览由 macOS Quick Look 提供；格式不受支持时可点击“同时打开”。").font(.caption).foregroundStyle(.secondary); Spacer() }.padding().frame(minWidth: 500) }
    private func fileCard(_ url: URL) -> some View { GroupBox { VStack(alignment: .leading, spacing: 7) { Text(url.lastPathComponent).font(.headline).textSelection(.enabled); Text("文件大小：\(formattedFileSize(url))").font(.caption).foregroundStyle(.secondary); Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled); Button("在访达中显示", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }.frame(maxWidth: .infinity, alignment: .leading) } }
    private func quickPreview(_ url: URL) -> some View { QuickLookFileView(url: url).clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary)) }
    private var historyView: some View {
        NavigationStack {
            List(history) { entry in
                HStack(alignment: .top) {
                    DisclosureGroup {
                        ForEach(entry.pairs) { pair in
                            VStack(alignment: .leading) {
                                Text("\(Int(pair.score * 100))% · \(URL(fileURLWithPath: pair.first).lastPathComponent)")
                                Text(URL(fileURLWithPath: pair.second).lastPathComponent).foregroundStyle(.secondary)
                            }
                        }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(entry.date.formatted())
                            Text("\(entry.fileCount) 本 · \(entry.pairs.count) 组 · \(String(format: "%.1f 秒", entry.duration))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("查看结果") { showHistoryResult(entry) }
                        .buttonStyle(.bordered)
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
                    if let entry = pendingHistoryDeletion { EbookFilenameHistoryStore.delete(entry.id) }
                    history = EbookFilenameHistoryStore.load(); pendingHistoryDeletion = nil
                }
                Button("取消", role: .cancel) { pendingHistoryDeletion = nil }
            } message: { Text("仅删除本机保存的扫描记录，不会删除电子书文件。") }
        }
    }

    private func formattedFileSize(_ url: URL) -> String {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return "未知" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private func showHistoryResult(_ entry: EbookFilenameHistory) {
        let matches = entry.pairs.map {
            EbookFilenameMatch(first: URL(fileURLWithPath: $0.first), second: URL(fileURLWithPath: $0.second), score: $0.score)
        }
        let files = Array(Set(matches.flatMap { [$0.first, $0.second] })).sorted { $0.path < $1.path }
        result = EbookFilenameScanResult(files: files, matches: matches, errors: [], duration: entry.duration)
        resultFileCountOverride = entry.fileCount
        historicalResultDate = entry.date
        selected = matches.first
        showingHistory = false
    }

    private func addFolder() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true; guard panel.runModal() == .OK else { return }; for url in panel.urls where !roots.contains(url) { roots.append(url) } }
    private func cancel() { task?.cancel(); task = nil; scanning = false; currentPath = "" }
    private func scan() {
        scanning = true; foundCount = 0; visitedCount = 0; phase = "正在枚举目录"; currentPath = "准备扫描…"; result = nil; resultFileCountOverride = nil; historicalResultDate = nil; selected = nil
        let scanRoots = roots, scanRecursive = recursive, scanMinimum = minimum
        task = Task {
            let output = await EbookFilenameScanner.scan(roots: scanRoots, recursive: scanRecursive, minimum: scanMinimum) { books, visited, path, newPhase in
                Task { @MainActor in foundCount = books; visitedCount = visited; currentPath = path; phase = newPhase == "索引" ? "正在建立文件名索引" : "正在枚举目录" }
            }
            guard !Task.isCancelled else { return }
            result = output; selected = output.matches.first; scanning = false; phase = "扫描完成"; currentPath = ""; task = nil
            let entry = EbookFilenameHistory(roots: scanRoots, result: output); EbookFilenameHistoryStore.save(entry); history = EbookFilenameHistoryStore.load()
        }
    }
}

private struct QuickLookFileView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView { QLPreviewView(frame: .zero, style: .normal)! }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
}
