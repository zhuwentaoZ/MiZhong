import SwiftUI

struct ContentView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case duplicates = "文件查重"
        case ebooks = "电子书快速查重"
        var id: Self { self }
        var icon: String { self == .duplicates ? "square.on.square" : "books.vertical" }
    }

    @State private var section: Section = .duplicates

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(Section.allCases) { item in
                    Button {
                        section = item
                    } label: {
                        Label(item.rawValue, systemImage: item.icon)
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(section == item ? Color.accentColor.opacity(0.14) : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(section == item ? Color.accentColor : .secondary)
                }
                Spacer()
                Label("所有分析均在本机完成", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(.bar)
            Divider()
            Group {
                switch section {
                case .duplicates: DuplicateFilesView()
                case .ebooks: EbookFilenameView()
                }
            }
        }
    }
}
