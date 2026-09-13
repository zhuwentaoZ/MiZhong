import AppKit
import ImageIO
import SwiftUI

private actor ThumbnailLoader {
    static let shared = ThumbnailLoader()
    private let cache = NSCache<NSURL, NSImage>()
    init() { cache.totalCostLimit = 24 * 1024 * 1024; cache.countLimit = 120 }
    func load(_ url: URL) -> NSImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 480,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: .zero)
        cache.setObject(image, forKey: url as NSURL, cost: cg.bytesPerRow * cg.height)
        return image
    }
}
struct ThumbnailView: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { ZStack { Color.secondary.opacity(0.08); Image(systemName: "photo").foregroundStyle(.secondary) } }
        }
        .task(id: url) { image = await ThumbnailLoader.shared.load(url) }
        .clipped()
    }
}
