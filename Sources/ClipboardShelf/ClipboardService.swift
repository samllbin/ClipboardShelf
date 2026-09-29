import AppKit
import UniformTypeIdentifiers

enum ClipboardError: LocalizedError {
    case noText
    case emptyRecord
    case unsupportedRepresentation
    case writeFailed
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .noText: return "这条记录没有可复制的纯文本。"
        case .emptyRecord: return "这条记录没有可恢复的剪贴板内容。"
        case .unsupportedRepresentation: return "无法准备这条记录的剪贴板格式。"
        case .writeFailed: return "写入系统剪贴板失败，请重试。"
        case .tooLarge: return "单条剪贴板内容超过 20 MB，未保存。"
        }
    }
}

/// Reads the system pasteboard only after a new copy/cut or an explicit capture.
/// All file representations remain references; this service never moves source files.
@MainActor
final class ClipboardService {
    typealias SourceProvider = () -> (name: String, bundleID: String?)

    var onCapture: ((ClipRecord) -> Void)?
    var onNotice: ((String) -> Void)?
    var isPaused = false {
        didSet {
            // Also advance on resume: a copy made while paused must stay unrecorded.
            lastChangeCount = pasteboard.changeCount
        }
    }

    private let pasteboard: NSPasteboard
    private let sourceProvider: SourceProvider
    private var lastChangeCount: Int
    private var timer: Timer?

    init(
        pasteboard: NSPasteboard = .general,
        sourceProvider: @escaping SourceProvider = {
            let app = NSWorkspace.shared.frontmostApplication
            return (app?.localizedName ?? "未知应用", app?.bundleIdentifier)
        }
    ) {
        self.pasteboard = pasteboard
        self.sourceProvider = sourceProvider
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollChanges() }
        }
        timer.tolerance = 0.12
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }

    /// Explicitly saves the current clipboard, including content predating launch.
    func captureNow() {
        lastChangeCount = pasteboard.changeCount
        captureCurrentContents()
    }

    /// Internal entry point also permits deterministic tests without a run-loop delay.
    func pollChanges() {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        guard !isPaused else { return }
        captureCurrentContents()
    }

    func restore(_ record: ClipRecord, plainText: Bool = false) throws {
        guard record.byteCount <= HistoryPolicy.maximumEntryBytes else { throw ClipboardError.tooLarge }
        let output: [NSPasteboardItem]
        if plainText {
            guard let text = record.text else { throw ClipboardError.noText }
            let item = NSPasteboardItem()
            guard item.setString(text, forType: .string) else { throw ClipboardError.unsupportedRepresentation }
            output = [item]
        } else {
            guard !record.items.isEmpty else { throw ClipboardError.emptyRecord }
            output = try record.items.map { saved in
                guard !saved.representations.isEmpty else { throw ClipboardError.emptyRecord }
                let item = NSPasteboardItem()
                for (rawType, data) in saved.representations.sorted(by: { $0.key < $1.key }) {
                    guard item.setData(data, forType: NSPasteboard.PasteboardType(rawType)) else {
                        throw ClipboardError.unsupportedRepresentation
                    }
                }
                return item
            }
        }

        // Build every representation before changing the user's current clipboard.
        pasteboard.clearContents()
        let succeeded = pasteboard.writeObjects(output)
        lastChangeCount = pasteboard.changeCount
        guard succeeded else { throw ClipboardError.writeFailed }
    }

    func clear() {
        pasteboard.clearContents()
        lastChangeCount = pasteboard.changeCount
    }

    var changeCount: Int { pasteboard.changeCount }
    var hasContent: Bool { !(pasteboard.types?.isEmpty ?? true) }
    var isCurrentPrivate: Bool {
        Self.isSensitive(types: (pasteboard.pasteboardItems ?? []).flatMap(\.types), bundleID: sourceProvider().bundleID)
    }
    /// A transient preview, never inserted into persistent history.
    func pickerSnapshot() -> ClipRecord? { captureCurrentContents(recordInHistory: false) }

    @discardableResult
    private func captureCurrentContents(recordInHistory: Bool = true) -> ClipRecord? {
        let originalChangeCount = pasteboard.changeCount
        guard let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty else {
            onNotice?("系统剪贴板当前为空。")
            return nil
        }
        let source = sourceProvider()
        let allTypes = pasteboardItems.flatMap(\.types)
        guard !Self.isSensitive(types: allTypes, bundleID: source.bundleID) else {
            onNotice?("已跳过密码管理器或标记为私密的剪贴板内容。")
            return nil
        }

        var items: [ClipItem] = []
        var byteCount = 0
        var omittedFormats = false
        for original in pasteboardItems {
            var representations: [String: Data] = [:]
            for type in original.types {
                guard !Self.isPromisedFileType(type.rawValue) else {
                    omittedFormats = true
                    continue
                }
                guard let data = original.data(forType: type) else {
                    omittedFormats = true
                    continue
                }
                guard data.count <= HistoryPolicy.maximumEntryBytes - byteCount else {
                    onNotice?(ClipboardError.tooLarge.localizedDescription)
                    return nil
                }
                byteCount += data.count
                representations[type.rawValue] = data
            }
            if !representations.isEmpty { items.append(ClipItem(representations: representations)) }
        }

        // An owner can replace the clipboard while a lazy representation is read.
        guard pasteboard.changeCount == originalChangeCount else {
            onNotice?("剪贴板内容正在变化，将在下一次检查时重试。")
            return nil
        }
        guard !items.isEmpty else {
            onNotice?("该剪贴板内容只包含临时或无法保存的格式。")
            return nil
        }
        let text = Self.extractedText(from: items)
        let record = ClipRecord(
            sourceApp: source.name,
            sourceBundleID: source.bundleID,
            items: items,
            text: text,
            kind: Self.kind(for: items)
        )
        guard record.byteCount <= HistoryPolicy.maximumEntryBytes else {
            onNotice?(ClipboardError.tooLarge.localizedDescription)
            return nil
        }
        if recordInHistory { onCapture?(record) }
        if omittedFormats && recordInHistory { onNotice?("已保存可读取的内容；临时文件承诺或不可读取的专有格式已跳过。") }
        return record
    }

    private static func isSensitive(types: [NSPasteboard.PasteboardType], bundleID: String?) -> Bool {
        let markers: Set<String> = [
            "org.nspasteboard.concealedtype", "org.nspasteboard.transienttype",
            "org.nspasteboard.autogeneratedtype", "de.petermaurer.transientpasteboardtype",
            "com.agilebits.onepassword"
        ]
        if types.contains(where: { markers.contains($0.rawValue.lowercased()) }) { return true }
        guard let bundle = bundleID?.lowercased() else { return false }
        let passwordManagers = [
            "com.1password.", "com.agilebits.", "com.bitwarden.", "com.dashlane.",
            "com.lastpass.", "com.keepassxc.", "org.keepassxc.", "com.enpass.",
            "in.sinew.", "com.nordpass.", "proton.pass", "me.proton.pass", "com.apple.passwords"
        ]
        return passwordManagers.contains(where: { bundle.hasPrefix($0) })
    }

    private static func isPromisedFileType(_ rawType: String) -> Bool {
        let lower = rawType.lowercased()
        return lower.contains("promised-file") || lower.contains("filepromise")
            || lower.contains("filespromise") || lower.contains("files promise")
    }

    private static func kind(for items: [ClipItem]) -> ClipKind {
        let types = Set(items.flatMap { $0.representations.keys })
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue)
            || types.contains("NSFilenamesPboardType") { return .files }
        if types.contains(where: { UTType($0)?.conforms(to: .image) == true }) { return .image }
        if types.contains(NSPasteboard.PasteboardType.rtf.rawValue)
            || types.contains(NSPasteboard.PasteboardType.rtfd.rawValue)
            || types.contains(NSPasteboard.PasteboardType.html.rawValue) { return .richText }
        if types.contains(where: { UTType($0)?.conforms(to: .text) == true })
            || types.contains("NSStringPboardType") { return .text }
        return .other
    }

    private static func extractedText(from items: [ClipItem]) -> String? {
        let strings = items.compactMap { item -> String? in
            let data = item.representations
            if let utf8 = data[NSPasteboard.PasteboardType.string.rawValue] ?? data["NSStringPboardType"],
               let text = String(data: utf8, encoding: .utf8) { return text }
            if let utf16 = data["public.utf16-external-plain-text"],
               let text = String(data: utf16, encoding: .utf16) { return text }
            if let utf16 = data["public.utf16-plain-text"],
               let text = String(data: utf16, encoding: .utf16LittleEndian) { return text }
            if let rtf = data[NSPasteboard.PasteboardType.rtf.rawValue],
               let attributed = try? NSAttributedString(
                data: rtf,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
               ) { return attributed.string }
            if let html = data[NSPasteboard.PasteboardType.html.rawValue],
               let source = String(data: html, encoding: .utf8) { return plainHTML(source) }
            if let url = data[NSPasteboard.PasteboardType.fileURL.rawValue]
                ?? data[NSPasteboard.PasteboardType.URL.rawValue],
               let text = String(data: url, encoding: .utf8) { return text }
            if let paths = data["NSFilenamesPboardType"],
               let files = try? PropertyListSerialization.propertyList(from: paths, format: nil) as? [String] {
                return files.joined(separator: "\n")
            }
            return nil
        }
        return strings.isEmpty ? nil : strings.joined(separator: "\n")
    }

    /// No WebKit/HTML importer: deriving a preview must never fetch remote resources.
    static func plainHTML(_ source: String) -> String {
        var text = source.replacingOccurrences(
            of: "(?is)<(script|style)\\b[^>]*>.*?</\\1\\s*>", with: "", options: .regularExpression
        )
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>|</(?:p|div|li|h[1-6])\\s*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&amp;": "&"]
        for key in ["&nbsp;", "&lt;", "&gt;", "&quot;", "&apos;", "&amp;"] {
            text = text.replacingOccurrences(of: key, with: entities[key]!)
        }
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let valueRange = Range(match.range(at: 1), in: text),
                      let wholeRange = Range(match.range, in: text) else { continue }
                let value = String(text[valueRange])
                let scalar = value.hasPrefix("x") ? UInt32(value.dropFirst(), radix: 16) : UInt32(value)
                if let scalar, let character = UnicodeScalar(scalar) {
                    text.replaceSubrange(wholeRange, with: String(character))
                }
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
