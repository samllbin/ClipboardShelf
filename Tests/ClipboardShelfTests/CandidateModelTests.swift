import AppKit
import XCTest
@testable import ClipboardShelf

private func candidateRecord(_ text: String, source: String = "Test Editor") -> ClipRecord {
    ClipRecord(
        sourceApp: source,
        items: [ClipItem(representations: ["public.utf8-plain-text": Data(text.utf8)])],
        text: text,
        kind: .text
    )
}

final class CandidateModelTests: XCTestCase {
    func testUnavailableSnapshotStillOffersNativeClipboardBeforeHistory() async throws {
        try await MainActor.run {
            let history = [candidateRecord("first saved item"), candidateRecord("older item")]
            let model = CandidateModel()
            model.prepare(history: history, current: nil, hasCurrent: true)

            let nativeID = try XCTUnwrap(model.nativeClipboardID)
            let native = try XCTUnwrap(model.records.first)
            XCTAssertEqual(native.id, nativeID)
            XCTAssertEqual(model.selectedID, nativeID)
            XCTAssertEqual(native.sourceApp, "当前剪贴板")
            XCTAssertTrue(native.items.isEmpty, "The native option must not invent or read a payload.")
            XCTAssertEqual(Array(model.records.dropFirst()), history)
            XCTAssertFalse(history.contains { $0.id == nativeID })
        }
    }

    func testCurrentSnapshotIsFirstAndDeduplicatesPayloadWithoutReorderingHistory() async throws {
        try await MainActor.run {
            let first = candidateRecord("recent item")
            let current = candidateRecord("current payload", source: "Source App")
            let middle = candidateRecord("middle item")
            let duplicate = candidateRecord("current payload", source: "Another App")
            let last = candidateRecord("oldest item")
            let history = [first, current, middle, duplicate, last]
            let model = CandidateModel()

            model.prepare(history: history, current: current, hasCurrent: true)

            let native = try XCTUnwrap(model.records.first)
            XCTAssertEqual(native.id, model.nativeClipboardID)
            XCTAssertNotEqual(native.id, current.id)
            XCTAssertEqual(native.items, current.items)
            XCTAssertEqual(native.text, current.text)
            XCTAssertEqual(native.sourceApp, "当前剪贴板")
            XCTAssertEqual(Array(model.records.dropFirst()), [first, middle, last])
            XCTAssertEqual(model.selectedID, native.id)
            XCTAssertEqual(history[1], current, "Preparing candidates must not modify saved history.")
            XCTAssertEqual(history[3], duplicate)
        }
    }

    func testNewPresentationResetsTransientStateAndRemovesNativeOptionWhenClipboardIsEmpty() async {
        await MainActor.run {
            let record = candidateRecord("saved history")
            let model = CandidateModel()
            model.prepare(history: [], current: nil, hasCurrent: true)
            model.query = "old search"
            model.status = "old status"

            model.prepare(history: [record], current: nil, hasCurrent: false)

            XCTAssertEqual(model.query, "")
            XCTAssertEqual(model.status, "")
            XCTAssertNil(model.nativeClipboardID)
            XCTAssertEqual(model.records, [record])
            XCTAssertEqual(model.selectedID, record.id)
        }
    }

    func testArrowAndPageMovementCanReachAllFiveHundredRecordsAndClampAtEnds() async {
        await MainActor.run {
            let history = (0..<500).map { candidateRecord("history \($0)") }
            let model = CandidateModel()
            model.prepare(history: history, current: nil, hasCurrent: false)
            XCTAssertEqual(model.filteredRecords.count, 500)
            XCTAssertEqual(model.selectedID, history[0].id)

            model.moveSelection(-1)
            XCTAssertEqual(model.selectedID, history[0].id)
            model.moveSelection(1)
            XCTAssertEqual(model.selectedID, history[1].id)
            model.moveSelection(5)
            XCTAssertEqual(model.selectedID, history[6].id)
            model.moveSelection(-5)
            XCTAssertEqual(model.selectedID, history[1].id)

            model.selectedID = history[98].id
            model.moveSelection(5)
            XCTAssertEqual(model.selectedID, history[103].id, "Keyboard browsing must continue beyond the old 100-record limit.")
            model.moveSelection(1_000)
            XCTAssertEqual(model.selectedID, history[499].id)
            model.moveSelection(1)
            XCTAssertEqual(model.selectedID, history[499].id)
            model.moveSelection(-5)
            XCTAssertEqual(model.selectedID, history[494].id)
            model.moveSelection(-1_000)
            XCTAssertEqual(model.selectedID, history[0].id)
        }
    }

    func testQueryMatchesTermsAcrossFieldsAndReconcilesSelection() async {
        await MainActor.run {
            let unrelated = candidateRecord("meeting agenda", source: "Notes")
            let firstMatch = candidateRecord("project launch checklist", source: "Safari")
            let secondMatch = candidateRecord("project launch notes", source: "Safari")
            let model = CandidateModel()
            model.prepare(history: [unrelated, firstMatch, secondMatch], current: nil, hasCurrent: false)

            model.query = "SAFARI launch"

            XCTAssertEqual(model.filteredRecords, [firstMatch, secondMatch])
            XCTAssertEqual(model.selectedID, firstMatch.id)
            model.moveSelection(1)
            XCTAssertEqual(model.selectedID, secondMatch.id)
            model.query = "Safari launch checklist"
            XCTAssertEqual(model.filteredRecords, [firstMatch])
            XCTAssertEqual(model.selectedID, firstMatch.id)

            model.query = "no matching content"
            XCTAssertTrue(model.filteredRecords.isEmpty)
            XCTAssertNil(model.selectedID)
            model.moveSelection(5)
            XCTAssertNil(model.selectedID)
            model.query = ""
            XCTAssertEqual(model.selectedID, unrelated.id)
        }
    }

    func testSearchFindsOldestRecordBeyondFirstHundredCandidates() async {
        await MainActor.run {
            let history = (0..<500).map { candidateRecord("saved-value-\($0)", source: "Archive App") }
            let model = CandidateModel()
            model.prepare(history: history, current: nil, hasCurrent: false)

            model.query = "Archive saved-value-499"

            XCTAssertEqual(model.filteredRecords, [history[499]])
            XCTAssertEqual(model.selectedID, history[499].id)
        }
    }

    func testChooseCommitsOnlyChosenCandidateOnce() async {
        await MainActor.run {
            let history = [candidateRecord("first"), candidateRecord("chosen")]
            let model = CandidateModel()
            var committed: [ClipRecord] = []
            model.onCommit = { committed.append($0) }
            model.prepare(history: history, current: nil, hasCurrent: false)

            model.choose(history[1])

            XCTAssertEqual(model.selectedID, history[1].id)
            XCTAssertEqual(committed, [history[1]])
            XCTAssertEqual(model.records, history)
        }
    }

    func testCommitUsesKeyboardSelectionAndCancelDoesNotCommit() async {
        await MainActor.run {
            let history = [candidateRecord("first"), candidateRecord("second")]
            let model = CandidateModel()
            var committed: [ClipRecord] = []
            var cancellations = 0
            model.onCommit = { committed.append($0) }
            model.onCancel = { cancellations += 1 }
            model.prepare(history: history, current: nil, hasCurrent: false)

            model.moveSelection(1)
            model.commit()
            model.cancel()

            XCTAssertEqual(committed, [history[1]])
            XCTAssertEqual(cancellations, 1)
        }
    }

    func testEmptyHistoryWithoutClipboardHasNoSelection() async {
        await MainActor.run {
            let model = CandidateModel()
            model.prepare(history: [], current: nil, hasCurrent: false)
            model.moveSelection(1)
            model.moveSelection(-5)

            XCTAssertTrue(model.filteredRecords.isEmpty)
            XCTAssertNil(model.nativeClipboardID)
            XCTAssertNil(model.selectedID)
        }
    }
}

final class CandidatePlacementTests: XCTestCase {
    private let panelSize = NSSize(width: 340, height: 330)
    private let mainVisibleFrame = NSRect(x: 0, y: 24, width: 1440, height: 1032)

    func testAXCoordinatesUsePrimaryScreenTopAndPreserveCaretDimensions() {
        XCTAssertEqual(
            CandidatePlacement.appKitRect(fromAX: CGRect(x: 120, y: 100, width: 2, height: 20), primaryScreenTop: 1080),
            NSRect(x: 120, y: 960, width: 2, height: 20)
        )
        XCTAssertEqual(
            CandidatePlacement.appKitRect(fromAX: CGRect(x: -600, y: -300, width: 2, height: 16), primaryScreenTop: 1080),
            NSRect(x: -600, y: 1364, width: 2, height: 16)
        )
    }

    func testPanelAppearsBelowCaretWhenThereIsRoom() {
        let frame = CandidatePlacement.frame(
            anchor: NSRect(x: 200, y: 600, width: 2, height: 20),
            size: panelSize,
            visibleFrame: mainVisibleFrame
        )
        XCTAssertEqual(frame, NSRect(x: 200, y: 262, width: 340, height: 330))
    }

    func testPanelFlipsAboveCaretNearBottomOfDisplay() {
        let frame = CandidatePlacement.frame(
            anchor: NSRect(x: 200, y: 40, width: 2, height: 20),
            size: panelSize,
            visibleFrame: mainVisibleFrame
        )
        XCTAssertEqual(frame, NSRect(x: 200, y: 68, width: 340, height: 330))
    }

    func testOffscreenAnchorsClampToVisibleDisplayMargins() {
        let topRight = CandidatePlacement.frame(
            anchor: NSRect(x: 9_999, y: 5_000, width: 2, height: 20),
            size: panelSize,
            visibleFrame: mainVisibleFrame
        )
        let bottomLeft = CandidatePlacement.frame(
            anchor: NSRect(x: -2_000, y: -1_000, width: 2, height: 20),
            size: panelSize,
            visibleFrame: mainVisibleFrame
        )
        XCTAssertEqual(topRight, NSRect(x: 1092, y: 718, width: 340, height: 330))
        XCTAssertEqual(bottomLeft, NSRect(x: 8, y: 32, width: 340, height: 330))
    }

    func testPanelPlacementWorksOnNegativeCoordinateDisplay() {
        let visible = NSRect(x: -1920, y: -1080, width: 1920, height: 1080)
        let frame = CandidatePlacement.frame(
            anchor: NSRect(x: -500, y: -100, width: 1, height: 18),
            size: panelSize,
            visibleFrame: visible
        )
        XCTAssertEqual(frame, NSRect(x: -500, y: -438, width: 340, height: 330))
        XCTAssertTrue(visible.contains(frame))

        let rightEdge = CandidatePlacement.frame(
            anchor: NSRect(x: 100, y: -100, width: 1, height: 18),
            size: panelSize,
            visibleFrame: visible
        )
        XCTAssertEqual(rightEdge.minX, -348)
        XCTAssertTrue(visible.contains(rightEdge))
    }

    func testPanelShrinksToFitSmallVisibleFrame() {
        let visible = NSRect(x: 100, y: 50, width: 200, height: 150)
        let frame = CandidatePlacement.frame(
            anchor: NSRect(x: 250, y: 180, width: 1, height: 18),
            size: panelSize,
            visibleFrame: visible
        )
        XCTAssertEqual(frame, NSRect(x: 108, y: 58, width: 184, height: 134))
        XCTAssertTrue(visible.contains(frame))
    }
}
