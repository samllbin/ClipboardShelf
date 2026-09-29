import AppKit
import XCTest
@testable import ClipboardShelf

final class ClipboardSnapshotTests: XCTestCase {
    func testSnapshotPreservesAllFormatsAndDoesNotCaptureOrChangeClipboard() async throws {
        try await MainActor.run {
            let board = NSPasteboard(name: .init("ClipboardSnapshotTests.\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            let service = ClipboardService(pasteboard: board, sourceProvider: { ("Test Editor", "test.editor") })
            var captures = 0
            service.onCapture = { _ in captures += 1 }

            let first = NSPasteboardItem()
            XCTAssertTrue(first.setString("Current native clipboard", forType: .string))
            XCTAssertTrue(first.setString("<b>Current native clipboard</b>", forType: .html))
            let second = NSPasteboardItem()
            let binaryType = NSPasteboard.PasteboardType("test.clipboard-snapshot.binary")
            let binary = Data([0, 255, 17, 0, 128])
            XCTAssertTrue(second.setData(binary, forType: binaryType))
            board.clearContents()
            XCTAssertTrue(board.writeObjects([first, second]))

            let beforeCount = board.changeCount
            let beforeTypes = board.pasteboardItems?.map { $0.types.map(\.rawValue) }
            let beforeFormats = rawItems(board)
            let snapshot = try XCTUnwrap(service.pickerSnapshot())

            XCTAssertEqual(snapshot.text, "Current native clipboard")
            XCTAssertEqual(snapshot.sourceApp, "Test Editor")
            XCTAssertEqual(snapshot.sourceBundleID, "test.editor")
            XCTAssertEqual(snapshot.items.map(\.representations), beforeFormats)
            XCTAssertEqual(captures, 0)
            XCTAssertEqual(service.changeCount, beforeCount)
            XCTAssertEqual(board.changeCount, beforeCount)
            XCTAssertEqual(board.pasteboardItems?.map { $0.types.map(\.rawValue) }, beforeTypes)
            XCTAssertEqual(rawItems(board), beforeFormats)
            XCTAssertTrue(service.hasContent)
            XCTAssertFalse(service.isCurrentPrivate)
        }
    }

    func testSnapshotDoesNotConsumePendingCaptureByTheHistoryMonitor() async {
        await MainActor.run {
            let board = NSPasteboard(name: .init("ClipboardSnapshotTests.\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            board.clearContents()
            let service = ClipboardService(pasteboard: board, sourceProvider: { ("Test Editor", "test.editor") })
            var capturedText: [String?] = []
            service.onCapture = { capturedText.append($0.text) }
            // A real copy takes ownership; adding a representation to the same
            // ownership does not increment NSPasteboard.changeCount.
            let initialVersion = board.changeCount
            board.clearContents()
            XCTAssertTrue(board.setString("Copied just before opening picker", forType: .string))
            XCTAssertNotEqual(board.changeCount, initialVersion)

            XCTAssertNotNil(service.pickerSnapshot())
            XCTAssertTrue(capturedText.isEmpty)
            service.pollChanges()
            XCTAssertEqual(capturedText, ["Copied just before opening picker"])
            service.pollChanges()
            XCTAssertEqual(capturedText.count, 1)
        }
    }

    func testPrivateMarkerOnLaterItemRejectsEntireSnapshot() async {
        await MainActor.run {
            let board = NSPasteboard(name: .init("ClipboardSnapshotTests.\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            let service = ClipboardService(pasteboard: board, sourceProvider: { ("Test Editor", "test.editor") })
            let first = NSPasteboardItem()
            XCTAssertTrue(first.setString("First item", forType: .string))
            let second = NSPasteboardItem()
            XCTAssertTrue(second.setData(Data(), forType: .init("org.nspasteboard.ConcealedType")))
            board.clearContents()
            XCTAssertTrue(board.writeObjects([first, second]))
            let beforeCount = board.changeCount
            let beforeFormats = rawItems(board)

            XCTAssertTrue(service.isCurrentPrivate)
            XCTAssertNil(service.pickerSnapshot())
            XCTAssertEqual(board.changeCount, beforeCount)
            XCTAssertEqual(rawItems(board), beforeFormats)
        }
    }

    func testPrivateMarkersRejectSnapshotWithoutChangingAnyClipboardData() async {
        await MainActor.run {
            let board = NSPasteboard(name: .init("ClipboardSnapshotTests.\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            let service = ClipboardService(pasteboard: board, sourceProvider: { ("Test Editor", "test.editor") })
            var captures = 0
            service.onCapture = { _ in captures += 1 }

            for marker in [
                "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                "org.nspasteboard.AutoGeneratedType", "de.petermaurer.TransientPasteboardType",
                "com.agilebits.onepassword"
            ] {
                let item = NSPasteboardItem()
                XCTAssertTrue(item.setString("Private sample used only in isolated test clipboard", forType: .string))
                XCTAssertTrue(item.setData(Data(), forType: .init(marker)))
                board.clearContents()
                XCTAssertTrue(board.writeObjects([item]))
                let beforeCount = board.changeCount
                let beforeFormats = rawItems(board)

                XCTAssertTrue(service.hasContent)
                XCTAssertTrue(service.isCurrentPrivate, marker)
                XCTAssertNil(service.pickerSnapshot(), marker)
                XCTAssertEqual(captures, 0)
                XCTAssertEqual(board.changeCount, beforeCount)
                XCTAssertEqual(rawItems(board), beforeFormats)
            }
        }
    }

    func testPasswordManagerSourceRejectsSnapshotWithoutNeedingPrivateMarker() async {
        await MainActor.run {
            let board = NSPasteboard(name: .init("ClipboardSnapshotTests.\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            let service = ClipboardService(pasteboard: board, sourceProvider: { ("1Password", "com.1password.1password") })
            var captures = 0
            service.onCapture = { _ in captures += 1 }
            board.clearContents()
            XCTAssertTrue(board.setString("Isolated synthetic password-manager sample", forType: .string))
            let beforeCount = board.changeCount
            let beforeFormats = rawItems(board)

            XCTAssertTrue(service.isCurrentPrivate)
            XCTAssertNil(service.pickerSnapshot())
            XCTAssertEqual(captures, 0)
            XCTAssertEqual(board.changeCount, beforeCount)
            XCTAssertEqual(rawItems(board), beforeFormats)
        }
    }

    func testUnsupportedFilePromiseHasNoSnapshotButRemainsAvailableForNativePaste() async {
        await MainActor.run {
            let board = NSPasteboard(name: .init("ClipboardSnapshotTests.\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            let service = ClipboardService(pasteboard: board, sourceProvider: { ("Test Editor", "test.editor") })
            var captures = 0
            service.onCapture = { _ in captures += 1 }
            let type = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url")
            let data = Data("test-only-temporary-provider".utf8)
            board.clearContents()
            XCTAssertTrue(board.setData(data, forType: type))
            let beforeCount = board.changeCount
            let beforeTypes = board.types

            XCTAssertTrue(service.hasContent)
            XCTAssertFalse(service.isCurrentPrivate)
            XCTAssertNil(service.pickerSnapshot())
            XCTAssertEqual(captures, 0)
            XCTAssertEqual(board.changeCount, beforeCount)
            XCTAssertEqual(board.types, beforeTypes)
            XCTAssertEqual(board.data(forType: type), data)
        }
    }

    func testOversizedClipboardHasNoSnapshotButRemainsUntouchedForNativePaste() async {
        await MainActor.run {
            let board = NSPasteboard(name: .init("ClipboardSnapshotTests.\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            let service = ClipboardService(pasteboard: board, sourceProvider: { ("Test Editor", "test.editor") })
            var captures = 0
            service.onCapture = { _ in captures += 1 }
            let type = NSPasteboard.PasteboardType("test.clipboard-snapshot.oversized")
            let data = Data(repeating: 42, count: HistoryPolicy.maximumEntryBytes + 1)
            board.clearContents()
            XCTAssertTrue(board.setData(data, forType: type))
            let beforeCount = board.changeCount
            let beforeTypes = board.types

            XCTAssertTrue(service.hasContent)
            XCTAssertFalse(service.isCurrentPrivate)
            XCTAssertNil(service.pickerSnapshot())
            XCTAssertEqual(captures, 0)
            XCTAssertEqual(board.changeCount, beforeCount)
            XCTAssertEqual(board.types, beforeTypes)
            XCTAssertEqual(board.data(forType: type), data)
        }
    }

    func testEmptyClipboardHasNoContentOrSnapshot() async {
        await MainActor.run {
            let board = NSPasteboard(name: .init("ClipboardSnapshotTests.\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            board.clearContents()
            let service = ClipboardService(pasteboard: board, sourceProvider: { ("Test Editor", "test.editor") })
            var captures = 0
            service.onCapture = { _ in captures += 1 }
            let beforeCount = board.changeCount

            XCTAssertFalse(service.hasContent)
            XCTAssertFalse(service.isCurrentPrivate)
            XCTAssertNil(service.pickerSnapshot())
            XCTAssertEqual(captures, 0)
            XCTAssertEqual(board.changeCount, beforeCount)
        }
    }

    @MainActor
    private func rawItems(_ board: NSPasteboard) -> [[String: Data]] {
        (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type.rawValue, $0) }
            })
        }
    }
}
