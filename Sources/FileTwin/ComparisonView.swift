import DuplicateCore
import SwiftUI
import QuickLook

struct ComparisonView: View {
    let group: SimilarImageGroup
    @State private var preview: URL?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("图片对比").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Text("候选图片均与本组第一张匹配；指纹接近度不是准确率。点击图片可查看原图。").foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280))], spacing: 18) {
                    ForEach(group.files) { file in
                        VStack(alignment: .leading, spacing: 8) {
                            ThumbnailView(url: file.url).frame(height: 210).clipShape(RoundedRectangle(cornerRadius: 12))
                                .onTapGesture { preview = file.url }
                            Text(file.url.lastPathComponent).font(.headline).textSelection(.enabled)
                            Text(file.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Text(file.modifiedAt?.formatted() ?? "修改时间未知").font(.caption)
                            Button("在访达中显示") { FinderRevealer.reveal(file.url) }
                        }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }.padding(24).frame(minWidth: 820, minHeight: 580).quickLookPreview($preview)
    }
}
