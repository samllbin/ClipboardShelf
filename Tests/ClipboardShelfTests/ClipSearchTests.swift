import XCTest
@testable import ClipboardShelf

final class ClipSearchTests: XCTestCase {
    private func record(
        text: String? = "项目计划 Project Café",
        sourceApp: String = "备忘录 Notes",
        sourceBundleID: String? = "com.apple.Notes",
        kind: ClipKind = .text,
        representations: [String: Data] = [:]
    ) -> ClipRecord {
        ClipRecord(sourceApp: sourceApp, sourceBundleID: sourceBundleID,
                   items: [ClipItem(representations: representations)], text: text, kind: kind)
    }

    func testEmptyAndUnicodeWhitespaceQueryMatchesAnyRecord() {
        let clip = record(text: nil, sourceApp: "", sourceBundleID: nil, kind: .other)
        for query in ["", "   ", " \t\n\r\u{3000}\u{00a0}"] {
            XCTAssertTrue(ClipSearch.matches(clip, query: query), query)
        }
    }

    func testChineseAndEnglishSubstringSearch() {
        let clip = record()
        XCTAssertTrue(ClipSearch.matches(clip, query: "项目"))
        XCTAssertTrue(ClipSearch.matches(clip, query: "计划"))
        XCTAssertTrue(ClipSearch.matches(clip, query: "PROJECT"))
        XCTAssertTrue(ClipSearch.matches(clip, query: "备忘录"))
        XCTAssertTrue(ClipSearch.matches(clip, query: "com.apple.notes"))
        XCTAssertFalse(ClipSearch.matches(clip, query: "旅行"))
    }

    func testCaseDiacriticsAndCharacterWidthAreNormalized() {
        let clip = record(text: "Café résumé ＡＢＣ 和咖啡")
        XCTAssertTrue(ClipSearch.matches(clip, query: "CAFE resume abc"))
        XCTAssertTrue(ClipSearch.matches(clip, query: "ＣＡＦＥ RESUME ＡＢＣ"))
        XCTAssertTrue(ClipSearch.matches(clip, query: "cafe\u{301}"))
        XCTAssertTrue(ClipSearch.matches(record(text: "Cafe\u{301}"), query: "CAFÉ"))
    }

    func testAllTermsAreRequiredAndMayCrossFields() {
        let clip = record()
        XCTAssertTrue(ClipSearch.matches(clip, query: "  项目\tNOTES\n文本 cafe  "))
        XCTAssertTrue(ClipSearch.matches(clip, query: "notes 项目 com.apple"))
        XCTAssertFalse(ClipSearch.matches(clip, query: "项目 missing"))
        XCTAssertFalse(ClipSearch.matches(clip, query: "项目 图片"))
    }

    func testSearchIncludesFullTextBeyondDisplayTitle() {
        let clip = record(text: String(repeating: "a", count: 150) + "结尾可搜索")
        XCTAssertFalse(clip.title.contains("结尾"))
        XCTAssertTrue(ClipSearch.matches(clip, query: "结尾可搜索"))
    }

    func testPercentEncodedFileNamesAndURLContentCanBeFound() {
        let clip = record(text: nil, sourceApp: "Finder", kind: .files, representations: [
            "public.file-url": Data("file:///Users/example/Documents/%E9%A1%B9%E7%9B%AE%20R%C3%A9sum%C3%A9.pdf".utf8)
        ])
        XCTAssertTrue(ClipSearch.matches(clip, query: "项目 resume.pdf finder 文件"))
        XCTAssertTrue(ClipSearch.matches(clip, query: "/Users/example/Documents"))
        XCTAssertTrue(ClipSearch.matches(clip, query: "%E9%A1%B9%E7%9B%AE"))
        XCTAssertFalse(ClipSearch.matches(clip, query: "项目 .png"))

        let link = record(text: nil, representations: [
            "public.url": Data("https://example.com/%E6%8A%A5%E5%91%8A?q=CAFE".utf8)
        ])
        XCTAssertTrue(ClipSearch.matches(link, query: "example.com 报告 cafe"))
    }

    func testLegacyFilePathsAndMultipleItemsAreIncluded() throws {
        let paths = try PropertyListSerialization.data(
            fromPropertyList: ["/tmp/设计稿.png", "/tmp/Second Report.pdf"], format: .binary, options: 0
        )
        var clip = record(text: nil, kind: .files, representations: ["NSFilenamesPboardType": paths])
        clip.items.append(ClipItem(representations: [
            "public.file-url": Data("file:///tmp/Third%20File.txt".utf8)
        ]))
        XCTAssertTrue(ClipSearch.matches(clip, query: "设计稿 second report third file"))
    }

    func testChineseKindNamesRemainSearchableWithCustomTitles() {
        for (kind, query) in [(ClipKind.text, "文本"), (.richText, "富文本"),
                              (.image, "图片"), (.files, "文件"), (.other, "其他")] {
            XCTAssertTrue(ClipSearch.matches(record(text: "自定义标题", kind: kind), query: query))
        }
    }

    func testMalformedURLDataAndBinaryContentDoNotBreakSearch() {
        let clip = record(representations: [
            "public.file-url": Data([0xff, 0xfe]),
            "public.url": Data("https://example.com/%invalid".utf8),
            "NSFilenamesPboardType": Data([0, 1, 2]),
            "public.png": Data("binarySecret".utf8)
        ])
        XCTAssertTrue(ClipSearch.matches(clip, query: "example.com"))
        XCTAssertTrue(ClipSearch.matches(clip, query: "项目"))
        XCTAssertFalse(ClipSearch.matches(clip, query: "binarySecret"))
    }
}
