import AppKit
import DuplicateCore
import Foundation

@MainActor
final class EbookViewModel: ObservableObject {
    @Published var roots: [URL] = []
    @Published var recursive = true
    @Published var level: EbookSimilarityLevel = .standard
    @Published var filenamePrefilter = true
    @Published var isScanning = false
    @Published var processed = 0
    @Published var currentPath = ""
    @Published var phase = ""
    @Published var result: EbookScanResult?
    @Published var selectedDocumentID: String?
    @Published var selectedMatchID: String?
    @Published var alertMessage: String?
    private var task: Task<Void, Never>?
    private var cacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiZhong/EbookTextCache", isDirectory: true)
    }

    func addFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !roots.contains(url) { roots.append(url) }
    }

    func scan() {
        guard !roots.isEmpty else { alertMessage = "请先添加电子书所在目录或已挂载的 NAS。"; return }
        isScanning = true; processed = 0; phase = "正在枚举并提取正文"; result = nil; selectedDocumentID = nil; selectedMatchID = nil
        let scanRoots = roots, scanRecursive = recursive, scanLevel = level, scanPrefilter = filenamePrefilter
        task = Task {
            let output = await EbookScanner(cacheDirectory: cacheDirectory).scan(roots: scanRoots, recursive: scanRecursive, level: scanLevel, filenamePrefilter: scanPrefilter) { count, path in
                Task { @MainActor [weak self] in
                    self?.processed = count; self?.currentPath = path
                    self?.phase = path == "正在比较正文指纹" ? "正在比较正文指纹" : "正在提取正文"
                }
            }
            guard !Task.isCancelled else { isScanning = false; return }
            result = output; isScanning = false; currentPath = ""; phase = "扫描完成"
            selectedMatchID = output.matches.first?.id
        }
    }

    func cancel() { task?.cancel(); task = nil; isScanning = false; currentPath = ""; phase = "" }
}
