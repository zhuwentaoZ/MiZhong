import Foundation

enum FinderRevealer {
    /// Launch Finder out of process so a slow or disconnected NAS cannot block SwiftUI's main thread.
    static func reveal(_ url: URL) {
        let path = url.path
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-R", path]
            try? process.run()
        }
    }
}
