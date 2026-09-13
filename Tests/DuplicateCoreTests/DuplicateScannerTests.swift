import DuplicateCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class DuplicateScannerTests: XCTestCase {
func testFindsContentDuplicatesAndIgnoresSameNameDifferentContent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("same bytes".utf8).write(to: root.appendingPathComponent("one.txt"))
    try Data("same bytes".utf8).write(to: root.appendingPathComponent("two.txt"))
    let sub = root.appendingPathComponent("sub")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    try Data("different".utf8).write(to: sub.appendingPathComponent("one.txt"))

    let result = await DuplicateScanner().scan(roots: [root], options: .init()) { _ in }
    XCTAssertEqual(result.scannedFiles, 3)
    XCTAssertEqual(result.groups.count, 1)
    XCTAssertEqual(result.groups[0].files.count, 2)
}

func testRespectsNonRecursiveOption() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let sub = root.appendingPathComponent("sub")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("x".utf8).write(to: root.appendingPathComponent("top.txt"))
    try Data("x".utf8).write(to: sub.appendingPathComponent("nested.txt"))
    let result = await DuplicateScanner().scan(roots: [root], options: .init(recursive: false)) { _ in }
    XCTAssertEqual(result.scannedFiles, 1)
    XCTAssertTrue(result.groups.isEmpty)
}

func testFiltersByMinimumAndMaximumSize() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(repeating: 1, count: 5).write(to: root.appendingPathComponent("small-a"))
    try Data(repeating: 1, count: 5).write(to: root.appendingPathComponent("small-b"))
    try Data(repeating: 2, count: 20).write(to: root.appendingPathComponent("large-a"))
    try Data(repeating: 2, count: 20).write(to: root.appendingPathComponent("large-b"))
    let result = await DuplicateScanner().scan(
        roots: [root], options: .init(minimumFileSize: 10, maximumFileSize: 30)) { _ in }
    XCTAssertEqual(result.scannedFiles, 2)
    XCTAssertEqual(result.groups.count, 1)
    XCTAssertEqual(result.groups[0].files.first?.size, 20)
}

func testFindsVisuallyIdenticalImagesAcrossFormats() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let width = 64, height = 64
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height { for x in 0..<width {
        let offset = (y * width + x) * 4
        pixels[offset] = UInt8(x * 4); pixels[offset + 1] = UInt8(y * 4)
        pixels[offset + 2] = UInt8((x + y) * 2); pixels[offset + 3] = 255
    }}
    let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let image = context.makeImage()!
    try write(image, to: root.appendingPathComponent("sample.png"), type: .png)
    try write(image, to: root.appendingPathComponent("sample.jpg"), type: .jpeg)
    let result = await DuplicateScanner().scan(roots: [root], options: .init(similarImages: true)) { _ in }
    XCTAssertEqual(result.similarImageGroups.count, 1)
    XCTAssertEqual(result.similarImageGroups[0].files.count, 2)
}

private func write(_ image: CGImage, to url: URL, type: UTType) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}
}
