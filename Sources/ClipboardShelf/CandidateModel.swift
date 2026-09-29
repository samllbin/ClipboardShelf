import AppKit
import Combine

@MainActor
final class CandidateModel: ObservableObject {
    @Published var records: [ClipRecord] = [] { didSet { reconcileSelection() } }
    @Published var query = "" { didSet { reconcileSelection() } }
    @Published var selectedID: UUID? { didSet { reconcilePreview() } }
    @Published var status = ""
    @Published private(set) var isImagePreviewExpanded = false {
        didSet {
            if oldValue != isImagePreviewExpanded { onPreviewChanged?() }
        }
    }
    var onCommit: ((ClipRecord) -> Void)?
    var onCancel: (() -> Void)?
    var onPreviewChanged: (() -> Void)?
    var openLibrary: (() -> Void)?
    var openThemes: (() -> Void)?
    private(set) var nativeClipboardID: UUID?

    var filteredRecords: [ClipRecord] {
        records.filter { ClipSearch.matches($0, query: query) }
    }

    var selectedRecord: ClipRecord? {
        filteredRecords.first { $0.id == selectedID }
    }

    func prepare(history: [ClipRecord], current: ClipRecord?, hasCurrent: Bool) {
        closeImagePreview()
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
        reconcilePreview()
    }

    func toggleImagePreview() {
        guard selectedRecord?.kind == .image else { return }
        isImagePreviewExpanded.toggle()
    }

    @discardableResult
    func closeImagePreview() -> Bool {
        guard isImagePreviewExpanded else { return false }
        isImagePreviewExpanded = false
        return true
    }

    /// Keep spaces available within search terms, and swallow repeats without toggling again.
    func handlePreviewSpace(isRepeat: Bool) -> Bool {
        guard query.isEmpty, selectedRecord?.kind == .image else { return false }
        if !isRepeat { toggleImagePreview() }
        return true
    }

    private func reconcilePreview() {
        if selectedRecord?.kind != .image { closeImagePreview() }
    }

    func choose(_ record: ClipRecord) { selectedID = record.id; commit() }
    func commit() {
        guard let record = filteredRecords.first(where: { $0.id == selectedID }) else { NSSound.beep(); return }
        onCommit?(record)
    }
    func cancel() {
        if !closeImagePreview() { onCancel?() }
    }
}

enum CandidateLayout {
    static let width: CGFloat = 340
    static let collapsedHeight: CGFloat = 330
    static let previewHeight: CGFloat = 180

    static func size(isImagePreviewExpanded: Bool) -> NSSize {
        NSSize(width: width, height: collapsedHeight + (isImagePreviewExpanded ? previewHeight : 0))
    }

    static func contentHeights(for height: CGFloat, isImagePreviewExpanded: Bool) -> (list: CGFloat, preview: CGFloat) {
        // Header, search field, footer, and outer vertical padding consume 110 points.
        let remaining = max(0, height - 110)
        guard isImagePreviewExpanded else { return (remaining, 0) }
        let preview = min(previewHeight, max(0, remaining - min(132, remaining / 2)))
        return (remaining - preview, preview)
    }
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

    /// Resize in place, keeping the top-left corner unless a display edge requires clamping.
    static func resizedFrame(from frame: NSRect, size: NSSize, visibleFrame: NSRect) -> NSRect {
        let margin: CGFloat = 8
        let width = min(size.width, max(1, visibleFrame.width - margin * 2))
        let height = min(size.height, max(1, visibleFrame.height - margin * 2))
        let x = min(max(frame.minX, visibleFrame.minX + margin), visibleFrame.maxX - width - margin)
        let y = min(max(frame.maxY - height, visibleFrame.minY + margin), visibleFrame.maxY - height - margin)
        return NSRect(x: x, y: y, width: width, height: height)
    }
}
