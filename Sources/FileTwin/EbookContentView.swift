import AppKit
import DuplicateCore
import SwiftUI

struct EbookContentView: View {
    @StateObject private var model = EbookViewModel()
    @State private var tab = 0

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 14) {
                Label("电子书内容查重", systemImage: "books.vertical.fill").font(.title2.bold())
                Text("按实际正文查找改名、换格式、重排版或部分重合的电子书。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("查找位置").font(.headline)
                if model.roots.isEmpty {
                    Text("支持本地目录和已挂载的 NAS").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.roots, id: \.self) { url in
                            HStack {
                                Image(systemName: url.path.hasPrefix("/Volumes/") ? "externaldrive.connected.to.line.below" : "folder")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading) {
                                    Text(url.lastPathComponent).lineLimit(1)
                                    Text(url.path).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                Button { model.roots.removeAll { $0 == url } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                            }
                            .padding(9).background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }.frame(maxHeight: 180)
                Button("添加文件夹或 NAS…", systemImage: "plus") { model.addFolder() }.disabled(model.isScanning)
                Toggle("搜索子目录", isOn: $model.recursive).disabled(model.isScanning)
                Toggle("大库先按近似文件名筛选", isOn: $model.filenamePrefilter).disabled(model.isScanning)
                Text("超过 200 本时先筛书名，再比较正文；关闭可找出改名后的同书，但会明显变慢。").font(.caption2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 7) {
                    Text("匹配程度").font(.headline)
                    Picker("匹配程度", selection: $model.level) {
                        Text("严格").tag(EbookSimilarityLevel.strict)
                        Text("标准").tag(EbookSimilarityLevel.standard)
                        Text("宽松").tag(EbookSimilarityLevel.loose)
                    }.pickerStyle(.segmented).labelsHidden().disabled(model.isScanning)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("PDF · EPUB · MOBI · AZW3", systemImage: "doc.text")
                        Label("NAS 文件只读", systemImage: "lock.shield")
                        Label("不读取或保存密码，不绕过 DRM", systemImage: "key.slash")
                    }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer()
                Button(model.isScanning ? "取消分析" : "开始内容查重", systemImage: model.isScanning ? "xmark" : "text.magnifyingglass") {
                    model.isScanning ? model.cancel() : model.scan()
                }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            }
            .padding(18).navigationSplitViewColumnWidth(min: 280, ideal: 320)
        } detail: {
            ZStack {
                LinearGradient(colors: [.indigo.opacity(0.07), .clear], startPoint: .topLeading, endPoint: .center).ignoresSafeArea()
                if model.isScanning { progressView }
                else if let result = model.result { resultView(result) }
                else { welcomeView }
            }.padding(22)
        }
        .alert("觅重", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("好") { model.alertMessage = nil }
        } message: { Text(model.alertMessage ?? "") }
    }

    private var welcomeView: some View {
        VStack(spacing: 18) {
            ContentUnavailableView("发现内容相似的电子书", systemImage: "books.vertical",
                description: Text("比较正文而不是文件名和大小。扫描版 PDF、加密或 DRM 文件会单独标记。"))
            HStack(spacing: 20) {
                Label("跨格式", systemImage: "arrow.left.arrow.right")
                Label("匹配依据", systemImage: "quote.bubble")
                Label("只读分析", systemImage: "lock")
            }.font(.callout).foregroundStyle(.secondary)
        }
    }

    private var progressView: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("正在提取并比较正文").font(.title2.bold())
            Text("已处理 \(model.processed) 本电子书").foregroundStyle(.secondary)
            Text(model.currentPath).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: 560)
        }
    }

    private func resultView(_ result: EbookScanResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                metric("发现电子书", "\(result.documents.count)")
                metric("可比较", "\(result.documents.filter { $0.state == .ready }.count)")
                metric("相似组合", "\(result.matches.count)")
                metric("耗时", String(format: "%.1f 秒", result.duration))
            }
            Picker("内容", selection: $tab) { Text("相似结果").tag(0); Text("全部电子书").tag(1) }.pickerStyle(.segmented)
            if tab == 0 { matchesView(result.matches) } else { documentsView(result.documents) }
        }
    }

    private func matchesView(_ matches: [EbookMatch]) -> some View {
        Group {
            if matches.isEmpty {
                ContentUnavailableView("没有发现相似电子书", systemImage: "checkmark.circle", description: Text("可以改用“宽松”匹配后重新分析。"))
            } else {
                HSplitView {
                    List(matches, selection: $model.selectedMatch) { match in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text(match.classification).font(.headline); Spacer(); Text("\(Int(match.similarity * 100))%").foregroundStyle(.indigo).font(.headline) }
                            Text(match.first.title).lineLimit(1)
                            Text(match.second.title).lineLimit(1)
                            Text("覆盖：\(Int(match.firstCoverage * 100))% / \(Int(match.secondCoverage * 100))%")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 5).tag(match)
                    }.frame(minWidth: 300, idealWidth: 370)
                    matchDetail(model.selectedMatch ?? matches.first!)
                }
            }
        }
    }

    private func matchDetail(_ match: EbookMatch) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("匹配依据").font(.title2.bold())
            HStack { bookCard(match.first); bookCard(match.second) }
            Text("相似度用于排序，不代表概率。双向正文覆盖率为 \(Int(match.firstCoverage * 100))% 和 \(Int(match.secondCoverage * 100))%。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("重合片段").font(.headline)
            if match.evidence.isEmpty { Text("正文指纹存在重合，但没有生成适合展示的完整句子。").foregroundStyle(.secondary) }
            else { ScrollView { VStack(alignment: .leading, spacing: 10) { ForEach(match.evidence, id: \.self) { Text("“\($0)”").textSelection(.enabled).padding(10).background(.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 8)) } } } }
        }.padding(16).frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func documentsView(_ documents: [EbookDocument]) -> some View {
        HSplitView {
            List(documents, selection: $model.selectedDocument) { book in
                HStack {
                    Image(systemName: book.state == .ready ? "book.closed" : "exclamationmark.triangle")
                        .foregroundStyle(book.state == .ready ? .indigo : .orange)
                    VStack(alignment: .leading) { Text(book.title).lineLimit(1); Text("\(book.format.rawValue.uppercased()) · \(formattedFileSize(book.url)) · \(book.characterCount) 字 · \(stateText(book.state))").font(.caption).foregroundStyle(.secondary) }
                }.tag(book)
            }.frame(minWidth: 310, idealWidth: 380)
            if let book = model.selectedDocument ?? documents.first {
                VStack(alignment: .leading, spacing: 10) {
                    Text(book.title).font(.title2.bold()); Text("文件大小：\(formattedFileSize(book.url))").font(.caption).foregroundStyle(.secondary); Text(book.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(book.detail).font(.caption).foregroundStyle(book.state == .ready ? Color.secondary : Color.orange)
                    Divider()
                    ScrollView { Text(book.text.isEmpty ? "没有可预览的文字。" : book.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.trailing) }
                    HStack { Spacer(); Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([book.url]) } }
                }.padding(16)
            }
        }
    }

    private func bookCard(_ book: EbookDocument) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(book.title).font(.headline).lineLimit(2)
            Text(book.format.rawValue.uppercased()).font(.caption.bold()).foregroundStyle(.indigo)
            Text("文件大小：\(formattedFileSize(book.url))").font(.caption2).foregroundStyle(.secondary)
            Text(book.url.path).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 10))
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) { Text(value).font(.title2.bold()); Text(title).foregroundStyle(.secondary) }
            .padding().frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
    private func stateText(_ state: EbookExtractionState) -> String {
        switch state { case .ready: "可比较"; case .tooShort: "正文过少"; case .scannedPDF: "可能是扫描版"; case .encrypted: "已加密"; case .unsupported: "不支持"; case .failed: "读取失败" }
    }
    private func formattedFileSize(_ url: URL) -> String {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return "未知" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
