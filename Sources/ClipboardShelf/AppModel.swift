import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ShelfFilter: String, CaseIterable, Identifiable {
    case all = "全部记录", pinned = "我的收藏", text = "文字与链接", image = "图片", files = "文件", richText = "富文本", other = "其他格式"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .all: return "square.stack.3d.up"
        case .pinned: return "pin"
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .files: return "folder"
        case .richText: return "doc.richtext"
        case .other: return "square.grid.2x2"
        }
    }
    func includes(_ record: ClipRecord) -> Bool {
        switch self {
        case .all: return true
        case .pinned: return record.isPinned
        case .text: return record.kind == .text
        case .image: return record.kind == .image
        case .files: return record.kind == .files
        case .richText: return record.kind == .richText
        case .other: return record.kind == .other
        }
    }
}

struct ShelfAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published var records: [ClipRecord] = []
    @Published var query = ""
    @Published var filter = ShelfFilter.all
    @Published var selection: UUID?
    @Published var isPaused = false {
        didSet { clipboard.isPaused = isPaused }
    }
    @Published var isReady = false
    @Published var pendingWrites = 0
    @Published var hasSaveError = false
    @Published var status = "正在读取本地记录…"
    @Published var alert: ShelfAlert?
    @Published var showingComposer = false
    @Published var showingThemes = false
    @Published var backgroundImage: NSImage?
    @Published var backgroundOpacity: Double = 0.22 {
        didSet { if !isDemo { UserDefaults.standard.set(backgroundOpacity, forKey: "shelfBackgroundOpacity") } }
    }
    @Published var usesCustomAccent = false {
        didSet { if !isDemo { UserDefaults.standard.set(usesCustomAccent, forKey: "shelfUsesCustomAccent") } }
    }
    @Published var customAccentHex = "28735E" {
        didSet { if !isDemo { UserDefaults.standard.set(customAccentHex, forKey: "shelfCustomAccent") } }
    }
    @Published var theme = ShelfTheme.sage {
        didSet { if !isDemo { UserDefaults.standard.set(theme.rawValue, forKey: "shelfTheme") } }
    }
    @Published var appearance = ShelfAppearance.system {
        didSet {
            if !isDemo { UserDefaults.standard.set(appearance.rawValue, forKey: "shelfAppearance") }
            NSApp.appearance = appearance.nsAppearance
        }
    }
    @Published var searchFocusRequest = UUID()
    @Published var shortcutAvailable = true
    let directory: URL
    let isDemo: Bool
    let clipboard: ClipboardService
    let repository: HistoryRepository
    let appearanceStorage: AppearanceStorage
    private let ioQueue = DispatchQueue(label: "local.clipboardshelf.storage", qos: .utility)
    var returnToPreviousApp: ((Bool) -> Void)?
    var onReady: (() -> Void)?

    init(isDemo: Bool = false) {
        self.isDemo = isDemo
        if isDemo {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardShelf-Demo-\(UUID().uuidString)", isDirectory: true)
            clipboard = ClipboardService(pasteboard: NSPasteboard(name: .init("ClipboardShelf-Demo-\(UUID().uuidString)")))
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ClipboardShelf", isDirectory: true)
            clipboard = ClipboardService()
        }
        repository = HistoryRepository(directory: directory)
        appearanceStorage = AppearanceStorage(directory: directory)
        if !isDemo {
            theme = ShelfTheme(rawValue: UserDefaults.standard.string(forKey: "shelfTheme") ?? "") ?? .sage
            appearance = ShelfAppearance(rawValue: UserDefaults.standard.string(forKey: "shelfAppearance") ?? "") ?? .system
            usesCustomAccent = UserDefaults.standard.bool(forKey: "shelfUsesCustomAccent")
            customAccentHex = UserDefaults.standard.string(forKey: "shelfCustomAccent") ?? "28735E"
            if UserDefaults.standard.object(forKey: "shelfBackgroundOpacity") != nil {
                backgroundOpacity = min(0.5, max(0.05, UserDefaults.standard.double(forKey: "shelfBackgroundOpacity")))
            }
        }
        NSApp.appearance = appearance.nsAppearance
        clipboard.onCapture = { [weak self] in self?.accept($0) }
        clipboard.onNotice = { [weak self] in self?.status = $0 }
    }

    var visibleRecords: [ClipRecord] {
        return records.filter { record in
            filter.includes(record) && ClipSearch.matches(record, query: query)
        }
    }
    var selected: ClipRecord? { visibleRecords.first(where: { $0.id == selection }) }
    var totalBytes: Int { records.reduce(0) { $0 + $1.byteCount } }
    var accent: Color { usesCustomAccent ? customAccentColor : theme.accent }
    var onAccent: Color {
        guard usesCustomAccent else { return theme.onAccent }
        let ns = NSColor(customAccentColor).usingColorSpace(.deviceRGB) ?? .systemGreen
        return (0.2126 * ns.redComponent + 0.7152 * ns.greenComponent + 0.0722 * ns.blueComponent) > 0.62 ? .black : .white
    }
    var customAccentColor: Color {
        get {
            let value = UInt64(customAccentHex, radix: 16) ?? 0x28735E
            return Color(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
        }
        set {
            guard let color = NSColor(newValue).usingColorSpace(.deviceRGB) else { return }
            customAccentHex = String(format: "%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
            usesCustomAccent = true
        }
    }

    func start() {
        let repository = repository
        let appearanceStorage = appearanceStorage
        ioQueue.async {
            let result = Result { try repository.load() }
            let background = try? appearanceStorage.loadBackground()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.backgroundImage = background ?? nil
                switch result {
                case .success(let records):
                    self.records = records
                    self.selection = records.first?.id
                    self.isReady = true
                    self.status = "本地记录已就绪"
                    if self.isDemo { self.seedDemo() }
                    self.clipboard.start()
                    self.onReady?()
                case .failure(let error):
                    self.status = "本地记录读取失败，已停止采集"
                    self.fail("无法读取历史记录", "原文件已保留。请先打开数据目录备份或修复 history.json，再重新启动应用。\n\n\(error.localizedDescription)")
                }
            }
        }
    }

    func flush() throws {
        guard isReady else { return }
        let snapshot = records
        let repository = repository
        try ioQueue.sync { try repository.save(snapshot) }
    }

    func accept(_ record: ClipRecord) {
        guard isReady else { return }
        guard record.byteCount <= HistoryPolicy.maximumEntryBytes else {
            fail("内容过大", "单条内容和搜索文本合计不能超过 20 MB。")
            return
        }
        records = HistoryOperations.inserting(record, into: records)
        if let captured = records.first(where: { $0.fingerprint == record.fingerprint }) {
            if selection == nil { selection = captured.id }
            status = "已收录 · \(record.kind.label)"
        } else {
            status = "收藏已占满存储空间，请先删除部分收藏"
        }
        reconcileSelection()
        persist()
    }

    func persist() {
        guard isReady else { return }
        let snapshot = records
        let repository = repository
        pendingWrites += 1
        ioQueue.async {
            let result = Result { try repository.save(snapshot) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingWrites -= 1
                if case .failure(let error) = result {
                    self.hasSaveError = true
                    self.status = "保存失败，当前修改仅在内存中"
                    self.fail("本地保存失败", error.localizedDescription)
                } else {
                    self.hasSaveError = false
                }
            }
        }
    }

    func reconcileSelection() {
        if !visibleRecords.contains(where: { $0.id == selection }) { selection = visibleRecords.first?.id }
    }

    func togglePin(_ record: ClipRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index].isPinned.toggle()
        status = records[index].isPinned ? "已收藏，自动清理时优先保留" : "已取消收藏"
        persist()
        reconcileSelection()
    }

    func delete(_ record: ClipRecord) {
        records.removeAll { $0.id == record.id }
        reconcileSelection()
        status = "记录已删除"
        persist()
    }

    func clearUnpinned() {
        records.removeAll { !$0.isPinned }
        reconcileSelection()
        status = "已清理历史，收藏已保留"
        persist()
    }

    func restore(_ record: ClipRecord, plainText: Bool = false, returnToApp: Bool = false, paste: Bool = false) {
        do {
            try clipboard.restore(record, plainText: plainText)
            var updated = record
            updated.lastUsedAt = Date()
            records = HistoryOperations.inserting(updated, into: records)
            persist()
            status = plainText ? "已复制纯文本 · 按 ⌘V 粘贴" : "已复制 · 按 ⌘V 粘贴"
            if returnToApp || paste { returnToPreviousApp?(paste) }
        } catch { fail("无法恢复到剪贴板", error.localizedDescription) }
    }

    func addText(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let data = Data(text.utf8)
        guard data.count <= HistoryPolicy.maximumEntryBytes else {
            fail("内容过大", "单条内容不能超过 20 MB。")
            return
        }
        let record = ClipRecord(sourceApp: "手动添加", items: [ClipItem(representations: [NSPasteboard.PasteboardType.string.rawValue: data])], text: text, kind: .text)
        guard record.byteCount <= HistoryPolicy.maximumEntryBytes else {
            fail("内容过大", "文字及搜索副本合计不能超过 20 MB，请缩短内容。")
            return
        }
        accept(record)
        filter = .all
        query = ""
        selection = records.first?.id
        showingComposer = false
    }

    func exportArchive() {
        let panel = NSSavePanel()
        panel.title = "导出剪贴板备份"
        panel.message = "备份包含全部记录和收藏，以明文保存在你选择的位置。"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "拾光剪贴板-\(Date().formatted(.iso8601.year().month().day())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let snapshot = records
        let repository = repository
        ioQueue.async {
            let result = Result { try repository.exportArchive(snapshot, to: url) }
            DispatchQueue.main.async { [weak self] in
                switch result {
                case .success: self?.status = "已导出 \(snapshot.count) 条记录"
                case .failure(let error): self?.fail("导出失败", error.localizedDescription)
                }
            }
        }
    }

    func importArchive() {
        let panel = NSOpenPanel()
        panel.title = "导入剪贴板备份"
        panel.message = "导入后合并到当前历史，重复内容会自动去重。"
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let repository = repository
        ioQueue.async {
            let result = Result { try repository.importArchive(from: url) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let incoming):
                    let merged = HistoryOperations.merging(incoming, into: self.records)
                    let retainedIDs = Set(merged.map(\.id))
                    let removed = self.records.filter { !retainedIDs.contains($0.id) }
                    if !removed.isEmpty {
                        let confirmation = NSAlert()
                        confirmation.messageText = "导入后将超过历史容量"
                        confirmation.informativeText = "合并将移除 \(removed.count) 条已有记录，其中 \(removed.filter(\.isPinned).count) 条为收藏。你可以先取消并导出备份。"
                        confirmation.addButton(withTitle: "取消导入")
                        confirmation.addButton(withTitle: "继续合并")
                        guard confirmation.runModal() == .alertSecondButtonReturn else { return }
                    }
                    self.records = merged
                    self.reconcileSelection()
                    self.persist()
                    self.status = "备份合并完成 · 当前保留 \(merged.count) 条记录"
                case .failure(let error): self.fail("导入失败", error.localizedDescription)
                }
            }
        }
    }

    func importFile() {
        let panel = NSOpenPanel()
        panel.title = "读取文件内容"
        panel.message = "支持文字、富文本、HTML、图片、PDF；其他文件将保存文件引用。"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            let loadContent = type?.conforms(to: .image) == true || type?.conforms(to: .text) == true || type == .pdf || type == .rtf
            if !loadContent {
                accept(ClipRecord(sourceApp: "文件导入", items: [ClipItem(representations: [NSPasteboard.PasteboardType.fileURL.rawValue: Data(url.absoluteString.utf8)])], text: url.path, kind: .files))
            } else {
                let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                guard size <= HistoryPolicy.maximumEntryBytes else { throw ShelfError.message("单个文件内容不能超过 20 MB。") }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= HistoryPolicy.maximumEntryBytes else { throw ShelfError.message("单个文件内容不能超过 20 MB。") }
                var representations: [String: Data] = [:]
                var text: String?
                let kind: ClipKind
                if type == .rtf || type == .html {
                    if type == .rtf {
                        text = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string
                    } else if let html = String(data: data, encoding: .utf8) {
                        text = ClipboardService.plainHTML(html)
                    }
                    representations[type == .rtf ? NSPasteboard.PasteboardType.rtf.rawValue : NSPasteboard.PasteboardType.html.rawValue] = data
                    kind = .richText
                } else if type?.conforms(to: .text) == true {
                    text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
                    guard text != nil else { throw ShelfError.message("无法识别文字编码，请先将文件保存为 UTF-8。") }
                    kind = .text
                } else {
                    representations[type?.identifier ?? "public.data"] = data
                    kind = type?.conforms(to: .image) == true ? .image : .other
                }
                if let text { representations[NSPasteboard.PasteboardType.string.rawValue] = Data(text.utf8) }
                let record = ClipRecord(sourceApp: "文件导入 · \(url.lastPathComponent)", items: [ClipItem(representations: representations)], text: text, kind: kind)
                guard record.byteCount <= HistoryPolicy.maximumEntryBytes else { throw ShelfError.message("文件与文字表示合计超过 20 MB，未导入。") }
                accept(record)
            }
            filter = .all
            query = ""
            selection = records.first?.id
        } catch { fail("文件读取失败", error.localizedDescription) }
    }

    func saveContent(_ record: ClipRecord) {
        let panel = NSSavePanel()
        panel.title = "将内容另存为文件"
        let payload: Data
        let ext: String
        let contentType: UTType
        if record.kind == .image, let imageData = record.firstRepresentation(["public.png", "public.tiff", "public.jpeg", "com.compuserve.gif", "public.heic"]) {
            payload = imageData.data
            contentType = UTType(imageData.type) ?? .data
            ext = contentType.preferredFilenameExtension ?? "bin"
        } else if record.kind == .richText, let rich = record.firstRepresentation(["public.rtf", "public.html"]) {
            payload = rich.data
            contentType = rich.type == "public.rtf" ? .rtf : .html
            ext = contentType.preferredFilenameExtension ?? "rtf"
        } else if record.kind != .files, let text = record.text {
            payload = Data(text.utf8)
            contentType = .plainText
            ext = "txt"
        } else if let pdf = record.firstRepresentation(["com.adobe.pdf"]) {
            payload = pdf.data
            contentType = .pdf
            ext = "pdf"
        } else {
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "剪贴记录.json"
            panel.message = record.kind == .files ? "保存文件引用，不复制文件本体。可通过「导入备份」恢复。" : "将原始格式保存为一条可重新导入的剪贴板备份。"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do { try repository.exportArchive([record], to: url); status = "记录已保存" }
            catch { fail("保存失败", error.localizedDescription) }
            return
        }
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = "剪贴内容.\(ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try payload.write(to: url, options: .atomic); status = "内容已保存到 \(url.lastPathComponent)" }
        catch { fail("保存失败", error.localizedDescription) }
    }

    func openDataDirectory() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            NSWorkspace.shared.open(directory)
        } catch { fail("无法打开数据目录", error.localizedDescription) }
    }

    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.title = "选择自定义皮肤图片"
        panel.message = "图片将复制到本机，作为剪贴板背景。支持 PNG、JPEG、HEIC 等图片，最大 50 MB。"
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let storage = appearanceStorage
        status = "正在读取皮肤图片…"
        ioQueue.async {
            let result = Result { try storage.importBackground(from: url) }
            DispatchQueue.main.async { [weak self] in
                switch result {
                case .success(let image): self?.backgroundImage = image; self?.status = "自定义图片皮肤已保存"
                case .failure(let error): self?.fail("无法使用这张图片", error.localizedDescription)
                }
            }
        }
    }

    func removeBackgroundImage() {
        let storage = appearanceStorage
        ioQueue.async {
            let result = Result { try storage.removeBackground() }
            DispatchQueue.main.async { [weak self] in
                switch result {
                case .success: self?.backgroundImage = nil; self?.status = "已恢复纯色背景"
                case .failure(let error): self?.fail("无法移除图片皮肤", error.localizedDescription)
                }
            }
        }
    }

    func fail(_ title: String, _ message: String) { alert = ShelfAlert(title: title, message: message) }

    private func seedDemo() {
        let samples = [
            ("把每一次灵感，留在手边。\n\n拾光剪贴板会为你收好复制过的文字、链接、图片与文件。下次需要时，按下 ⌘⇧V，找到它，再继续。", "备忘录", true),
            ("https://developer.apple.com/documentation/appkit/nspasteboard", "Safari", true),
            ("周五设计同步\n1. 确认新版本交互\n2. 更新组件库\n3. 整理用户反馈", "飞书", false),
            ("let inspiration = clipboard.history\n    .filter { $0.isPinned }", "Xcode", false),
            ("咖啡、阳光，还有刚刚好的灵感。", "备忘录", false)
        ]
        for (index, sample) in samples.enumerated().reversed() {
            var record = ClipRecord(sourceApp: sample.1, items: [ClipItem(representations: [NSPasteboard.PasteboardType.string.rawValue: Data(sample.0.utf8)])], text: sample.0, kind: .text)
            record.isPinned = sample.2
            record.createdAt = Date().addingTimeInterval(Double(-index * 600))
            record.lastUsedAt = record.createdAt
            records.append(record)
        }
        records.sort { $0.lastUsedAt > $1.lastUsedAt }
        for index in 6...24 {
            let text = "历史片段 \(index) · 翻页也能找回之前的灵感"
            var record = ClipRecord(sourceApp: "演示记录", items: [ClipItem(representations: [NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)])], text: text, kind: .text)
            record.createdAt = Date().addingTimeInterval(Double(-index * 600))
            record.lastUsedAt = record.createdAt
            records.append(record)
        }
        selection = records.first?.id
        status = "演示模式 · 使用独立剪贴板与临时目录"
    }
}

enum ShelfError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

extension ClipKind {
    var label: String {
        switch self {
        case .text: return "文字"
        case .richText: return "富文本"
        case .image: return "图片"
        case .files: return "文件引用"
        case .other: return "其他格式"
        }
    }
    var icon: String {
        switch self {
        case .text: return "text.alignleft"
        case .richText: return "doc.richtext"
        case .image: return "photo"
        case .files: return "doc.on.doc"
        case .other: return "square.grid.2x2"
        }
    }
}

extension ClipRecord {
    var fileURLs: [URL] {
        items.flatMap { item -> [URL] in
            if let data = item.representations[NSPasteboard.PasteboardType.fileURL.rawValue],
               let raw = String(data: data, encoding: .utf8), let url = URL(string: raw), url.isFileURL { return [url] }
            if let data = item.representations["NSFilenamesPboardType"],
               let paths = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
                return paths.map { URL(fileURLWithPath: $0) }
            }
            return []
        }
    }
    var isLink: Bool {
        guard kind == .text, let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.contains("\n"),
              let url = URL(string: raw), let scheme = url.scheme else { return false }
        return ["http", "https"].contains(scheme.lowercased()) && url.host != nil
    }
    func firstRepresentation(_ types: [String]) -> (type: String, data: Data)? {
        for type in types {
            for item in items { if let data = item.representations[type] { return (type, data) } }
        }
        return nil
    }
    var formatNames: [String] { Array(Set(items.flatMap { $0.representations.keys })).sorted() }
}
