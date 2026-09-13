import AppKit
import SwiftUI

@main
struct MiZhongApp: App {
    init() {
        if let url = Bundle.main.url(forResource: "MiZhong", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    var body: some Scene {
        WindowGroup("觅重") { ContentView() }
            .defaultSize(width: 1140, height: 780)
            .commands { SidebarCommands() }
    }
}
