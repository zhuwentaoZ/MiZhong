import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: ScanViewModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("扫描设置").font(.title2.bold())
            Form {
                Section("文件类型与性能") {
                    TextField("扩展名（逗号分隔，留空为所有类型）", text: $model.extensions)
                    Stepper("本地同时读取：\(model.localWorkers)", value: $model.localWorkers, in: 1...8)
                    Stepper("NAS 同时读取：\(model.networkWorkers)", value: $model.networkWorkers, in: 1...4)
                    Toggle("保存本地指纹缓存，加速下次扫描", isOn: $model.useCache)
                    Button("清空指纹缓存") { model.clearCache() }
                }
                Section("排除目录") {
                    ForEach(model.exclusions.sorted(), id: \.self) { path in
                        HStack { Text(path).lineLimit(2); Spacer(); Button("移除") { model.exclusions.remove(path) } }
                    }
                    Button("添加排除目录…") { model.addExclusion() }
                }
                Section("保护目录（允许扫描，禁止清理）") {
                    ForEach(model.protectedPaths.sorted(), id: \.self) { path in
                        HStack { Text(path).lineLimit(2); Spacer(); Button("移除") { model.protectedPaths.remove(path) } }
                    }
                    Button("添加保护目录…") { model.addProtection() }
                }
                Section("批量选择时优先保留") {
                    Text(model.preferredDirectory?.path ?? "优先保留保护目录，其次保留路径较短的一份")
                    Button("选择优先保留目录…") { model.choosePreferred() }
                }
                Section("隐私") {
                    Text("文件处理在本机完成。NAS 使用系统已有挂载，始终只读。应用不保存账号或密码；本地保存设置、文件指纹、任务检查点、扫描结果、审核选择和清理日志。")
                        .foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            HStack { Spacer(); Button("完成") { model.saveSettings(); dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 650, height: 640)
    }
}
