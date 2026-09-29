import AppKit
import Combine

@MainActor
final class CandidateModel: ObservableObject {
    @Published var records: [ClipRecord] = []
    @Published var query = "" { didSet { reconcileSelection() } }
    @Published var selectedID: UUID?
    @Published var status = ""
    var onCommit: ((ClipRecord) -> Void)?
    var onCancel: (() -> Void)?
    var openLibrary: (() -> Void)?
    var openThemes: (() -> Void)?
    private(set) var nativeClipboardID: UUID?

    var filteredRecords: [ClipRecord] {
        records.filter { ClipSearch.matches($0, query: query) }
    }

    func prepare(history: [ClipRecord], current: ClipRecord?, hasCurrent: Bool) {
        query = ""
        status = ""
        records = history
        nativeClipboardID = nil
        if hasCurrent {
            var entry = current ?? ClipRecord(sourceApp: "当前剪贴板", items: [], text: "当前剪贴板（保持原有格式）", kind: .other)
            if current != nil {
                records.removeAll { $0.items == entry.items }
            }
            entry.id = UUID()
            entry.sourceApp = "当前剪贴板"
            nativeClipboardID = entry.id
            records.insert(entry, at: 0)
        }
        selectedID = filteredRecords.first?.id
    }

    func moveSelection(_ delta: Int) {
        let matches = filteredRecords
        guard !matches.isEmpty else { selectedID = nil; return }
        let index = matches.firstIndex { $0.id == selectedID } ?? 0
        selectedID = matches[min(matches.count - 1, max(0, index + delta))].id
    }

    func reconcileSelection() {
        let matches = filteredRecords
        if !matches.contains(where: { $0.id == selectedID }) { selectedID = matches.first?.id }
    }

    func choose(_ record: ClipRecord) { selectedID = record.id; commit() }
    func commit() {
        guard let record = filteredRecords.first(where: { $0.id == selectedID }) else { NSSound.beep(); return }
        onCommit?(record)
    }
    func cancel() { onCancel?() }
}

enum CandidatePlacement {
    /// AX screen coordinates originate at the primary display's top-left.
    static func appKitRect(fromAX rect: CGRect, primaryScreenTop: CGFloat) -> NSRect {
        NSRect(x: rect.minX, y: primaryScreenTop - rect.maxY, width: rect.width, height: rect.height)
    }

    static func frame(anchor: NSRect, size: NSSize, visibleFrame: NSRect) -> NSRect {
        let margin: CGFloat = 8
        let width = min(size.width, max(1, visibleFrame.width - margin * 2))
        let height = min(size.height, max(1, visibleFrame.height - margin * 2))
        let x = min(max(anchor.minX, visibleFrame.minX + margin), visibleFrame.maxX - width - margin)
        let below = anchor.minY - height - margin
        let wantedY = below >= visibleFrame.minY + margin ? below : anchor.maxY + margin
        let y = min(max(wantedY, visibleFrame.minY + margin), visibleFrame.maxY - height - margin)
        return NSRect(x: x, y: y, width: width, height: height)
    }
}
