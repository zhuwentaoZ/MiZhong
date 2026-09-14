import DuplicateCore
import SwiftUI

struct SessionHistoryView: View {
    @ObservedObject var model: ScanViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDeletion: ScanViewModel.SessionHistoryItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("历史任务").font(.title2.bold())
                    Text("恢复结果可离线查看；普通查重可新增文件夹并复用历史指纹。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.refreshHistory() } label: { Image(systemName: "arrow.clockwise") }
                    .help("刷新任务列表").disabled(model.isLoadingHistory)
            }
            if let issue = model.historyIssue {
                Label(issue, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if model.isLoadingHistory {
                ProgressView("正在读取任务记录…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.history.isEmpty {
                ContentUnavailableView("还没有历史任务", systemImage: "clock.arrow.circlepath",
                                       description: Text("开始扫描后，任务进度和结果会自动保存到本机。"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.history) { item in
                            sessionRow(item)
                        }
                    }
                }
            }
            HStack {
                Text("记录包含文件路径、属性、指纹和审核选择，不包含账号密码。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 740, height: 560)
        .confirmationDialog("删除这条历史任务？", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible) {
            Button("删除历史记录", role: .destructive) {
                if let item = pendingDeletion { model.deleteSession(item) }
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("仅删除本机保存的任务记录，不会删除扫描过的文件。")
        }
    }

    private func sessionRow(_ item: ScanViewModel.SessionHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(item.mode == .reference ? "A/B 资料库对比" : "普通文件查重", systemImage: item.mode == .reference ? "rectangle.split.2x1" : "doc.on.doc")
                    .font(.headline)
                Spacer()
                Text(statusText(item.status)).font(.caption.weight(.medium))
                    .foregroundStyle(item.status == .completed ? .green : .orange)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background((item.status == .completed ? Color.green : Color.orange).opacity(0.09), in: Capsule())
            }
            Text(item.roots.map(\.path).joined(separator: "\n"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    if item.hasResult {
                        Text("\(item.scannedFiles) 个文件 · \(item.duplicateGroups) 个重复组")
                    } else {
                        Text("检查点已保存 · 待处理位置 \(item.pendingCount) 项")
                    }
                }.font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) { pendingDeletion = item } label: {
                    Label("删除", systemImage: "trash")
                }
                Button(item.hasResult ? "查看结果" : "查看任务") { model.restoreSession(item.url) }
                if item.mode == .standard {
                    Button("增量添加文件夹…") { model.extendSession(item) }
                        .help("复制此历史范围和指纹，加入新文件夹后重新比对")
                }
                if item.status != .completed {
                    Button("继续任务") { model.restoreSession(item.url, resume: true) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(15)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.4)))
    }

    private func statusText(_ status: ScanSessionStatus) -> String {
        switch status {
        case .running: "中断前检查点"
        case .interrupted: "已中断保存"
        case .completed: "已完成"
        case .needsRetry: "有项目待重试"
        }
    }
}
