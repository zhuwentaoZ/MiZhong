import DuplicateCore
import CoreGraphics
import CoreText
import Foundation
import XCTest

final class EbookSimilarityTests: XCTestCase {
    func testHighFilenameThresholdRequiresSixtyPercentSizeRatio() {
        let a = URL(fileURLWithPath: "/books/同一本书.epub")
        let b = URL(fileURLWithPath: "/books/同一本书 副本.epub")
        let sizes: [String: Int64] = [a.path: 100, b.path: 59]
        XCTAssertTrue(EbookFilenameSimilarity.compare([a, b], minimum: 0.85, fileSizes: sizes).isEmpty)
        XCTAssertEqual(EbookFilenameSimilarity.compare([a, b], minimum: 0.80, fileSizes: sizes).count, 1)
        XCTAssertEqual(EbookFilenameSimilarity.compare([a, b], minimum: 0.85,
                                                        fileSizes: [a.path: 100, b.path: 60]).count, 1)
    }
    func testFilenameMatchesMergeIntoConnectedCandidateGroups() {
        let a = URL(fileURLWithPath: "/books/A.epub")
        let b = URL(fileURLWithPath: "/books/B.pdf")
        let c = URL(fileURLWithPath: "/books/C.mobi")
        let x = URL(fileURLWithPath: "/books/X.epub")
        let y = URL(fileURLWithPath: "/books/Y.pdf")
        let groups = EbookFilenameSimilarity.groups(from: [
            .init(first: a, second: b, score: 0.9),
            .init(first: b, second: c, score: 0.8),
            .init(first: x, second: y, score: 0.7)
        ])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map { Set($0.files.map(\.path)) }, [Set([a.path, b.path, c.path]), Set([x.path, y.path])])
        XCTAssertEqual(groups[0].matches.map(\.score), [0.9, 0.8])
        XCTAssertEqual(groups[0].duplicateBytes(fileSizes: [a.path: 100, b.path: 80, c.path: 60]), 140)
        XCTAssertNil(groups[0].duplicateBytes(fileSizes: [a.path: 100, b.path: 80]))
    }
    func testDocumentAndMatchIdentityDoNotHashFullText() {
        let url = URL(fileURLWithPath: "/tmp/identity.epub")
        let first = EbookDocument(url: url, format: .epub, title: "旧标题", text: String(repeating: "甲", count: 100_000))
        let updated = EbookDocument(url: url, format: .epub, title: "新标题", text: String(repeating: "乙", count: 100_000))
        XCTAssertEqual(first, updated)
        XCTAssertEqual(Set([first, updated]).count, 1)
        let peer = EbookDocument(url: URL(fileURLWithPath: "/tmp/peer.epub"), format: .epub, title: "Peer", text: "正文")
        let a = EbookMatch(first: first, second: peer, similarity: 0.9, firstCoverage: 0.8, secondCoverage: 0.8, evidence: [])
        let b = EbookMatch(first: updated, second: peer, similarity: 0.5, firstCoverage: 0.4, secondCoverage: 0.4, evidence: ["变化"])
        XCTAssertEqual(a, b)
    }

    func testFindsRenamedCrossFormatBookByContent() {
        let repeated = String(repeating: "这是一本用于验证电子书正文相似查找的完整作品。人物沿着河流旅行，并记录每一座城市的故事。", count: 80)
        let first = EbookDocument(url: URL(fileURLWithPath: "/tmp/原书.pdf"), format: .pdf, title: "原书", text: repeated)
        let second = EbookDocument(url: URL(fileURLWithPath: "/tmp/改名.epub"), format: .epub, title: "改名", text: repeated)
        let matches = EbookSimilarityEngine.compare([first, second], level: .strict)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].classification, "高度一致")
        XCTAssertGreaterThan(matches[0].similarity, 0.95)
    }

    func testFindsExcerptWithAsymmetricCoverage() {
        let chapter = String(repeating: "本章讨论资料整理、检索和长期保存的方法，并提供可以复查的实际例子。", count: 60)
        let full = chapter + String(repeating: "另一章描述完全不同的旅行见闻与人物经历。", count: 100)
        let first = EbookDocument(url: URL(fileURLWithPath: "/tmp/全集.azw3"), format: .azw3, title: "全集", text: full)
        let second = EbookDocument(url: URL(fileURLWithPath: "/tmp/节选.mobi"), format: .mobi, title: "节选", text: chapter)
        let matches = EbookSimilarityEngine.compare([first, second], level: .loose)
        XCTAssertEqual(matches.count, 1)
        XCTAssertGreaterThan(matches[0].secondCoverage, matches[0].firstCoverage)
    }

    func testFindsMovedNonRepeatingExcerpt() {
        let paragraphs = (0..<500).map { "第\($0)段包含唯一编号\($0 * 7919)，用于验证章节移动后仍可根据连续正文指纹找到来源。" }
        let fullText = paragraphs.joined(separator: "。")
        let excerpt = paragraphs[173..<287].joined(separator: "。")
        let full = EbookDocument(url: URL(fileURLWithPath: "/tmp/full.pdf"), format: .pdf, title: "全集", text: fullText)
        let part = EbookDocument(url: URL(fileURLWithPath: "/tmp/part.epub"), format: .epub, title: "节选", text: excerpt)
        let matches = EbookSimilarityEngine.compare([full, part], level: .loose)
        XCTAssertEqual(matches.count, 1)
        XCTAssertGreaterThan(matches[0].secondCoverage, 0.7)
    }

    func testDoesNotMatchSameTopicWithDifferentText() {
        let firstText = String(repeating: "苹果树生长需要阳光水分和适当修剪，果园管理重视季节变化。", count: 80)
        let secondText = String(repeating: "现代数据库通过索引事务和查询优化来管理大量结构化信息。", count: 80)
        let first = EbookDocument(url: URL(fileURLWithPath: "/tmp/a.pdf"), format: .pdf, title: "A", text: firstText)
        let second = EbookDocument(url: URL(fileURLWithPath: "/tmp/b.pdf"), format: .pdf, title: "B", text: secondText)
        XCTAssertTrue(EbookSimilarityEngine.compare([first, second], level: .loose).isEmpty)
    }

    func testShortTextIsExcludedFromComparison() {
        let short = EbookDocument(url: URL(fileURLWithPath: "/tmp/a.epub"), format: .epub, title: "A", text: "短文", state: .tooShort)
        let long = EbookDocument(url: URL(fileURLWithPath: "/tmp/b.epub"), format: .epub, title: "B", text: String(repeating: "正文", count: 500))
        XCTAssertTrue(EbookSimilarityEngine.compare([short, long], level: .loose).isEmpty)
    }

    func testExtractsEPUBInSpineOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let meta = root.appendingPathComponent("META-INF"), ops = root.appendingPathComponent("OPS")
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ops, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: root.appendingPathExtension("epub")) }
        try Data(#"<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>"#.utf8).write(to: meta.appendingPathComponent("container.xml"))
        try Data(#"<package><manifest><item id="two" href="two.xhtml"/><item id="one" href="one.xhtml"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>"#.utf8).write(to: ops.appendingPathComponent("book.opf"))
        try Data(("<html><body>第一章" + String(repeating: "甲", count: 240) + "</body></html>").utf8).write(to: ops.appendingPathComponent("one.xhtml"))
        try Data(("<html><body>第二章" + String(repeating: "乙", count: 240) + "</body></html>").utf8).write(to: ops.appendingPathComponent("two.xhtml"))
        let epub = root.appendingPathExtension("epub")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = root; process.arguments = ["-q", "-r", epub.path, "."]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        let book = EbookExtractor.extract(epub)
        XCTAssertEqual(book.state, .ready)
        XCTAssertLessThan(book.text.range(of: "第一章")!.lowerBound, book.text.range(of: "第二章")!.lowerBound)
    }

    func testExtractsUncompressedPalmDOC() throws {
        let text = "<html><body>" + String(repeating: "这是 MOBI 正文内容。", count: 80) + "</body></html>"
        let body = [UInt8](text.utf8), record0Offset = 94, record1Offset = 110
        var bytes = [UInt8](repeating: 0, count: record1Offset); bytes.append(contentsOf: body)
        put16(&bytes, 76, 2); put32(&bytes, 78, UInt32(record0Offset)); put32(&bytes, 86, UInt32(record1Offset))
        put16(&bytes, record0Offset, 1); put32(&bytes, record0Offset + 4, UInt32(body.count)); put16(&bytes, record0Offset + 8, 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mobi")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(bytes).write(to: url)
        let book = EbookExtractor.extract(url)
        XCTAssertEqual(book.state, .ready)
        XCTAssertTrue(book.text.contains("MOBI 正文内容"))
    }

    func testExtractsTextPDF() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            return XCTFail("无法创建 PDF 测试上下文")
        }
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        for lineNumber in 0..<30 {
            let value = "Text PDF content extraction verification line \(lineNumber), with enough actual readable words."
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            context.textPosition = CGPoint(x: 40, y: 740 - CGFloat(lineNumber * 20)); CTLineDraw(line, context)
        }
        context.endPDFPage(); context.closePDF()
        let book = EbookExtractor.extract(url)
        XCTAssertEqual(book.state, .ready)
        XCTAssertTrue(book.text.contains("content extraction verification"))
    }

    func testQuickDRMDetectionOnlyChecksMobiFamilyEncryptionField() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let protectedPDF = root.appendingPathComponent("protected.pdf")
        try Data("%PDF-1.7\n/Encrypt 4 0 R\n%%EOF".utf8).write(to: protectedPDF)
        XCTAssertEqual(EbookDRMDetector.check(protectedPDF), .unknown)

        var mobi = [UInt8](repeating: 0, count: 112)
        put32(&mobi, 78, 96); put16(&mobi, 108, 1)
        let protectedAZW = root.appendingPathComponent("protected.azw")
        try Data(mobi).write(to: protectedAZW)
        XCTAssertEqual(EbookDRMDetector.check(protectedAZW), .suspected)
        put16(&mobi, 108, 0)
        let plainMOBI = root.appendingPathComponent("plain.mobi")
        try Data(mobi).write(to: plainMOBI)
        XCTAssertEqual(EbookDRMDetector.check(plainMOBI), .notDetected)
    }

    private func put16(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt16) {
        bytes[offset] = UInt8(value >> 8); bytes[offset + 1] = UInt8(value & 255)
    }
    private func put32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
        bytes[offset] = UInt8(value >> 24); bytes[offset + 1] = UInt8((value >> 16) & 255)
        bytes[offset + 2] = UInt8((value >> 8) & 255); bytes[offset + 3] = UInt8(value & 255)
    }
}
