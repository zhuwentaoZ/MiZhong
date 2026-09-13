import CoreGraphics
import Foundation
import ImageIO

enum ImageSimilarity {
    struct Signature: Sendable, Codable {
        let hashes: [UInt64]
        let mean: Double
        let deviation: Double
    }
    private static let formats: Set<String> = ["jpg","jpeg","png","webp","heic","heif","tif","tiff","bmp","gif"]
    static func isSupported(_ url: URL) -> Bool { formats.contains(url.pathExtension.lowercased()) }
    static func differenceHash(_ url: URL) throws -> Signature {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        var hashes: [UInt64] = [], mean = 0.0, deviation = 0.0
        // Full image plus mild center crops; arbitrary crops still need human review.
        for scale in [1.0, 0.9, 0.8] {
            let w = Double(image.width) * scale, h = Double(image.height) * scale
            guard let crop = image.cropping(to: CGRect(x: (Double(image.width)-w)/2, y: (Double(image.height)-h)/2, width: w, height: h)) else { continue }
            var pixels = [UInt8](repeating: 0, count: 72)
            try pixels.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: 9, height: 8, bitsPerComponent: 8,
                    bytesPerRow: 9, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                    throw CocoaError(.featureUnsupported)
                }
                context.interpolationQuality = .high
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 9, height: 8))
            }
            if hashes.isEmpty {
                mean = pixels.reduce(0) { $0 + Double($1) } / 72
                deviation = sqrt(pixels.reduce(0) { $0 + pow(Double($1)-mean, 2) } / 72)
            }
            var hash: UInt64 = 0
            for y in 0..<8 { for x in 0..<8 { hash <<= 1; if pixels[y*9+x] > pixels[y*9+x+1] { hash |= 1 } } }
            hashes.append(hash)
        }
        return Signature(hashes: hashes, mean: mean, deviation: deviation)
    }
    static func distance(_ lhs: UInt64, _ rhs: UInt64) -> Int { (lhs ^ rhs).nonzeroBitCount }
    static func distance(_ lhs: Signature, _ rhs: Signature) -> Int {
        // Low-information solid images otherwise all have the same dHash.
        if min(lhs.deviation, rhs.deviation) < 3 && abs(lhs.mean-rhs.mean) > 8 { return 64 }
        return lhs.hashes.flatMap { a in rhs.hashes.map { distance(a, $0) } }.min() ?? 64
    }
    static func makeGroups(_ items: [(FileRecord, Signature)], threshold: Int = 8, control: ScanControl = ScanControl()) -> [SimilarImageGroup] {
        let threshold = max(1, min(12, threshold))
        var groups: [[Int]] = [], buckets: [UInt64: Set<Int>] = [:]
        // Index representatives only: bounded O(n) storage even for many identical images.
        for index in items.indices {
            if (try? control.checkpoint()) == nil { break }
            var candidates = Set<Int>(), keys = Set<UInt64>()
            for hash in items[index].1.hashes {
                for part in 0...threshold {
                    let shift = part * 64 / (threshold+1), end = (part+1) * 64 / (threshold+1)
                    let key = (UInt64(part)<<60) | ((hash >> UInt64(shift)) & ((1 << (end-shift))-1))
                    keys.insert(key); candidates.formUnion(buckets[key] ?? [])
                }
            }
            if let match = candidates.sorted().first(where: { distance(items[index].1, items[groups[$0][0]].1) <= threshold }) {
                groups[match].append(index)
            } else {
                let number = groups.count; groups.append([index])
                for key in keys { buckets[key, default: []].insert(number) }
            }
        }
        return groups.filter { $0.count > 1 }.map { indices in
            let first = indices[0]
            let worst = indices.dropFirst().map { distance(items[first].1, items[$0].1) }.max() ?? 0
            return SimilarImageGroup(id: items[first].0.id, files: indices.map { items[$0].0 },
                                     similarity: 1-Double(worst)/64)
        }.sorted { $0.similarity > $1.similarity }
    }
}
