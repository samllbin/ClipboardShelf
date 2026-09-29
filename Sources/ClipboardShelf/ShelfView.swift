import SwiftUI
import AppKit
import ImageIO

private let shelfSecondary = Color(nsColor: .secondaryLabelColor)

struct ShelfView: View {
    @ObservedObject var model: AppModel
    private var shelfAccent: Color { model.accent }
    @FocusState private var searchFocused: Bool
    @State private var clearingHistory = false
    @State private var clearingClipboard = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                Divider()
                history
                Divider()
                detail
            }
            Divider()
            statusBar
        }
        .background {
            GeometryReader { geometry in
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    if let image = model.backgroundImage {
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped().opacity(model.backgroundOpacity)
                    }
                }
            }
        }
        .preferredColorScheme(model.appearance.colorScheme)
        .tint(shelfAccent)
        .frame(minWidth: 930, minHeight: 580)
        .onChange(of: model.query) { _ in model.reconcileSelection() }
        .onChange(of: model.filter) { _ in model.reconcileSelection() }
        .onChange(of: model.searchFocusRequest) { _ in searchFocused = true }
        .sheet(isPresented: $model.showingComposer) { ComposerView(model: model) }
        .sheet(isPresented: $model.showingThemes) { ThemePickerView(model: model) }
        .alert(item: $model.alert) { alert in Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("好"))) }
        .confirmationDialog("清理全部未收藏的历史记录？", isPresented: $clearingHistory, titleVisibility: .visible) {
            Button("清理历史", role: .destructive) { model.clearUnpinned() }
        } message: { Text("收藏和当前系统剪贴板会保留。") }
        .confirmationDialog("清空当前系统剪贴板？", isPresented: $clearingClipboard, titleVisibility: .visible) {
            Button("清空系统剪贴板", role: .destructive) { model.clipboard.clear(); model.status = "系统剪贴板已清空" }
        } message: { Text("已保存的历史记录会保留。") }
        .background(keyboardActions)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(model.onAccent)
                    .frame(width: 42, height: 42)
                    .background(shelfAccent.gradient, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("拾光").font(.system(size: 22, weight: .semibold))
                    Text("你的系统剪贴板").font(.system(size: 10)).foregroundStyle(shelfSecondary)
                }
            }
            .padding(.top, 26).padding(.bottom, 30)

            Text("资料库").font(.system(size: 10, weight: .medium)).foregroundStyle(shelfSecondary).padding(.leading, 10).padding(.bottom, 8)
            filterButton(.all)
            filterButton(.pinned)
            Text("按类型浏览").font(.system(size: 10, weight: .medium)).foregroundStyle(shelfSecondary).padding(.leading, 10).padding(.top, 27).padding(.bottom, 8)
            ForEach([ShelfFilter.text, .image, .files, .richText, .other]) { filterButton($0) }
            Spacer(minLength: 20)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle().fill(model.isPaused || !model.isReady ? Color.orange : shelfAccent).frame(width: 6, height: 6)
                    Text(model.isPaused ? "已暂停记录" : model.isReady ? "正在收集剪贴内容" : "等待本地记录")
                        .font(.system(size: 10, weight: .medium))
                }
                Text("让刚才的灵感，\n随时回到手边。")
                    .font(.system(size: 11)).foregroundStyle(shelfSecondary).lineSpacing(4)
                Button { model.isPaused.toggle() } label: {
                    Label(model.isPaused ? "继续记录" : "暂停记录", systemImage: model.isPaused ? "play" : "pause")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered).controlSize(.small).disabled(!model.isReady)
            }
            .padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            .padding(.bottom, 16)

            Button { model.showingThemes = true } label: {
                HStack(spacing: 8) { Image(systemName: "paintpalette"); Text("外观与自定义皮肤"); Spacer() }
                    .font(.system(size: 11)).foregroundStyle(shelfSecondary)
            }
            .buttonStyle(.plain).padding(.horizontal, 9).padding(.bottom, 18)

            Menu {
                Button("立即读取剪贴板") { model.clipboard.captureNow() }.disabled(!model.isReady || model.isPaused)
                Button("读取文件内容…") { model.importFile() }.disabled(!model.isReady)
                Divider()
                Button("导入备份…") { model.importArchive() }.disabled(!model.isReady)
                Button("导出全部记录…") { model.exportArchive() }.disabled(!model.isReady)
                Button("打开数据目录") { model.openDataDirectory() }
                Divider()
                Button("清理未收藏的历史…") { clearingHistory = true }.disabled(!model.isReady)
                Button("清空系统剪贴板…") { clearingClipboard = true }
                Divider()
                Button("退出拾光") { NSApplication.shared.terminate(nil) }
            } label: {
                HStack { Image(systemName: "slider.horizontal.3"); Text("管理与备份"); Spacer() }
                    .font(.system(size: 11)).foregroundStyle(shelfSecondary)
            }
            .menuStyle(.borderlessButton).padding(.horizontal, 9).padding(.bottom, 18)
        }
        .padding(.horizontal, 16)
        .frame(width: 184)
        .background(shelfAccent.opacity(0.035))
    }

    private func filterButton(_ filter: ShelfFilter) -> some View {
        let selected = model.filter == filter
        return Button { model.filter = filter } label: {
            HStack(spacing: 10) {
                Image(systemName: filter.icon).font(.system(size: 13)).frame(width: 17)
                Text(filter.rawValue).font(.system(size: 12, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
                Text("\(model.records.filter { filter.includes($0) }.count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(selected ? shelfAccent : shelfSecondary)
            }
            .foregroundStyle(selected ? shelfAccent : Color.primary.opacity(0.75))
            .padding(.horizontal, 10).padding(.vertical, 10)
            .background(selected ? shelfAccent.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.vertical, 1)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.filter == .all ? "最近复制" : model.filter.rawValue).font(.system(size: 20, weight: .semibold))
                    Text("每一段内容，都有迹可循").font(.system(size: 10)).foregroundStyle(shelfSecondary)
                }
                Spacer()
                Button { model.showingComposer = true } label: { Image(systemName: "plus").font(.system(size: 13, weight: .medium)).frame(width: 27, height: 27) }
                    .buttonStyle(.bordered).controlSize(.small).help("新建文字片段（⌘N）").disabled(!model.isReady)
            }
            .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 19)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(shelfSecondary)
                TextField("搜索内容或来源", text: $model.query).textFieldStyle(.plain).font(.system(size: 12)).focused($searchFocused)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(shelfSecondary) }.buttonStyle(.plain)
                } else { Text("⌘F").font(.system(size: 10)).foregroundStyle(shelfSecondary) }
            }
            .padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.07), lineWidth: 1))
            .padding(.horizontal, 20).padding(.bottom, 16)
            HStack {
                Text(model.query.isEmpty ? "\(model.visibleRecords.count) 条记录" : "找到 \(model.visibleRecords.count) 条记录")
                Spacer()
                Text("最近使用优先")
            }
            .font(.system(size: 10)).foregroundStyle(shelfSecondary).padding(.horizontal, 21).padding(.bottom, 8)

            if model.visibleRecords.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: model.query.isEmpty ? "tray" : "magnifyingglass").font(.system(size: 30, weight: .light)).foregroundStyle(shelfAccent.opacity(0.6))
                    Text(model.query.isEmpty ? "这里还没有记录" : "没有找到相关内容").font(.system(size: 13, weight: .medium))
                    Text(model.query.isEmpty ? "试着在任意应用中复制一段内容，\n它就会出现在这里。" : "换个关键词试试，\n也可以搜索应用名称。")
                        .font(.system(size: 11)).foregroundStyle(shelfSecondary).multilineTextAlignment(.center).lineSpacing(4)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach(model.visibleRecords) { record in
                        ClipRow(record: record)
                            .tag(record.id)
                            .padding(.vertical, 4)
                            .listRowSeparator(.hidden)
                            .onTapGesture(count: 2) { model.restore(record, returnToApp: true) }
                            .contextMenu {
                                Button("复制") { model.restore(record) }
                                Button("复制为纯文本") { model.restore(record, plainText: true) }.disabled(record.text == nil)
                                Button("复制并返回原应用") { model.restore(record, returnToApp: true) }
                                Divider()
                                Button(record.isPinned ? "取消收藏" : "收藏") { model.togglePin(record) }
                                Button("另存为文件…") { model.saveContent(record) }
                                Button("删除记录", role: .destructive) { model.delete(record) }
                            }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            HStack(spacing: 5) {
                Image(systemName: "arrow.turn.down.left")
                Text("⌘↩ 复制并返回 · 双击同样可用")
            }.font(.system(size: 10)).foregroundStyle(shelfSecondary).frame(maxWidth: .infinity).padding(.vertical, 14)
        }
        .frame(width: 310)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    @ViewBuilder private var detail: some View {
        if let record = model.selected {
            ClipDetail(record: record, model: model)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "doc.on.clipboard").font(.system(size: 49, weight: .ultraLight)).foregroundStyle(shelfAccent.opacity(0.55))
                Text("复制过的，随时找回").font(.system(size: 23, weight: .medium))
                Text("文字、图片、链接、富文本和文件引用\n在应用间流转，也留在你的本地资料库中。")
                    .font(.system(size: 12)).foregroundStyle(shelfSecondary).multilineTextAlignment(.center).lineSpacing(6)
                HStack(spacing: 7) {
                    ForEach(["⌘", "⇧", "V"], id: \.self) { key in
                        Text(key).font(.system(size: 15, weight: .medium, design: .rounded))
                            .frame(width: 35, height: 33)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.1)))
                    }
                }.padding(.top, 8)
                Text("在任意应用中唤起拾光").font(.system(size: 10)).foregroundStyle(shelfSecondary)
                if model.isReady {
                    Button("读取当前剪贴板") { model.clipboard.captureNow() }.buttonStyle(.bordered).padding(.top, 12).disabled(model.isPaused)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            Image(systemName: model.hasSaveError ? "exclamationmark.triangle" : "internaldrive")
            Text(model.hasSaveError ? "保存失败" : model.pendingWrites > 0 ? "正在保存…" : "仅保存在此 Mac")
            Text("·").padding(.horizontal, 3)
            Text(model.status).lineLimit(1)
            Spacer(minLength: 8)
            Text(ByteCountFormatter.string(fromByteCount: Int64(model.totalBytes), countStyle: .file))
            Text("/ 200 MB").foregroundStyle(shelfSecondary.opacity(0.7))
            Text("·").padding(.horizontal, 3)
            Text(model.shortcutAvailable ? "⌘⇧V 唤起" : "快捷键被占用，请点击菜单栏图标")
        }
        .font(.system(size: 10)).foregroundStyle(model.hasSaveError ? Color.orange : shelfSecondary)
        .padding(.horizontal, 17).frame(height: 33)
    }

    private var keyboardActions: some View {
        Group {
            Button("") { model.searchFocusRequest = UUID() }.keyboardShortcut("f", modifiers: .command)
            Button("") { if model.isReady { model.showingComposer = true } }.keyboardShortcut("n", modifiers: .command)
            Button("") { if let record = model.selected { model.restore(record, returnToApp: true) } }.keyboardShortcut(.return, modifiers: .command)
            Button("") { if let record = model.selected { model.restore(record, plainText: true, returnToApp: true) } }.keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("") { NSApp.keyWindow?.orderOut(nil) }.keyboardShortcut(.escape, modifiers: [])
        }.hidden()
    }
}

private struct ClipRow: View {
    let record: ClipRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: record.isLink ? "link" : record.kind.icon).font(.system(size: 10, weight: .medium))
                Text(record.sourceApp).lineLimit(1)
                Spacer()
                if record.isPinned { Image(systemName: "pin.fill").font(.system(size: 9)) }
                Text(record.lastUsedAt, style: .time).font(.system(size: 9, design: .rounded))
            }.font(.system(size: 10)).foregroundStyle(shelfSecondary)
            Text(record.title).font(.system(size: 12, weight: .medium)).lineLimit(2).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
            Text(record.isLink ? "链接" : record.kind.label).font(.system(size: 9)).foregroundStyle(shelfSecondary)
        }
        .padding(.vertical, 5).contentShape(Rectangle())
    }
}

private struct ClipDetail: View {
    let record: ClipRecord
    @ObservedObject var model: AppModel
    private var shelfAccent: Color { model.accent }
    @State private var showFormats = false
    @State private var deleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(record.isLink ? "链接" : record.kind.label, systemImage: record.isLink ? "link" : record.kind.icon)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(shelfAccent)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(shelfAccent.opacity(0.08), in: Capsule())
                Spacer()
                Button { model.togglePin(record) } label: { Image(systemName: record.isPinned ? "pin.fill" : "pin") }
                    .help(record.isPinned ? "取消收藏" : "收藏记录")
                Button { model.saveContent(record) } label: { Image(systemName: "square.and.arrow.down") }.help("另存为文件")
                Menu {
                    Button("读取文件内容…") { model.importFile() }
                    Button("另存为文件…") { model.saveContent(record) }
                    Divider()
                    Button("删除记录…", role: .destructive) { deleteConfirmation = true }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 20)
            }.buttonStyle(.borderless).padding(.bottom, 25)

            Text(record.kind == .files ? "文件引用" : "内容预览").font(.system(size: 21, weight: .semibold)).padding(.bottom, 6)
            Text("来自 \(record.sourceApp) · \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 10)).foregroundStyle(shelfSecondary).lineLimit(1).padding(.bottom, 22)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if record.kind == .image {
                        if let image = PreviewCache.shared.image(for: record) {
                            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 360).clipShape(RoundedRectangle(cornerRadius: 10))
                        } else {
                            Label("此图片格式暂不能预览，仍可恢复原始内容。", systemImage: "photo").font(.system(size: 12)).foregroundStyle(shelfSecondary)
                        }
                    } else if record.kind == .files {
                        ForEach(Array(record.fileURLs.enumerated()), id: \.offset) { _, url in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "doc.fill").font(.system(size: 24)).foregroundStyle(shelfAccent.opacity(0.65))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(url.lastPathComponent).font(.system(size: 13, weight: .medium))
                                    Text(url.path).font(.system(size: 10)).foregroundStyle(shelfSecondary).textSelection(.enabled)
                                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.font(.system(size: 10)).buttonStyle(.link)
                                }
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(shelfAccent.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                        }
                        Text("保存的是文件位置。原文件移动、删除或磁盘断开后，该引用可能不可用。")
                            .font(.system(size: 11)).foregroundStyle(shelfSecondary).lineSpacing(4)
                    } else if let text = record.text, !text.isEmpty {
                        Text(String(text.prefix(80_000))).font(.system(size: 14)).lineSpacing(7).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        if text.count > 80_000 { Text("预览仅显示前 80,000 字符，复制与保存包含完整内容。").font(.caption).foregroundStyle(shelfSecondary) }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "doc.zipper").font(.system(size: 32, weight: .light)).foregroundStyle(shelfAccent)
                            Text("原始内容已保留").font(.system(size: 15, weight: .medium))
                            Text("此格式没有文字预览，可复制到支持它的应用中使用，或另存为备份。")
                                .font(.system(size: 12)).foregroundStyle(shelfSecondary).lineSpacing(5)
                        }
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(model.backgroundImage == nil ? 1 : 0.88), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06), lineWidth: 1))
            .padding(.bottom, 18)

            HStack(spacing: 12) {
                Label(ByteCountFormatter.string(fromByteCount: Int64(record.byteCount), countStyle: .file), systemImage: "doc")
                if let text = record.text { Text("\(text.count) 字符") }
                Text("\(record.items.count) 个项目")
                Spacer()
                Button(showFormats ? "收起格式" : "原始格式") { showFormats.toggle() }.buttonStyle(.plain)
            }.font(.system(size: 10)).foregroundStyle(shelfSecondary).padding(.bottom, 14)

            if showFormats {
                Text(record.formatNames.joined(separator: "\n")).font(.system(size: 9, design: .monospaced)).foregroundStyle(shelfSecondary)
                    .textSelection(.enabled).lineLimit(8).padding(.bottom, 12)
            }
            HStack(spacing: 9) {
                Button { model.restore(record) } label: { Label("复制内容", systemImage: "doc.on.doc").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                Button("纯文本") { model.restore(record, plainText: true) }.disabled(record.text == nil).buttonStyle(.bordered)
                Button { model.restore(record, paste: true) } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.bordered).help("粘贴到原应用（需要辅助功能权限）")
            }.controlSize(.large)
            Text("复制后按 ⌘V 粘贴 · ⌘↩ 复制并返回原应用")
                .font(.system(size: 10)).foregroundStyle(shelfSecondary).frame(maxWidth: .infinity).padding(.top, 12)
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("删除这条历史记录？", isPresented: $deleteConfirmation, titleVisibility: .visible) {
            Button("删除", role: .destructive) { model.delete(record) }
        }
    }
}

private struct ComposerView: View {
    @ObservedObject var model: AppModel
    private var shelfAccent: Color { model.accent }
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("新建文字片段").font(.system(size: 23, weight: .semibold))
            Text("把常用回复、地址或灵感收进剪贴板。保存后可以收藏，随时取用。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(size: 14)).padding(8).frame(minHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.15)))
            HStack {
                Text("\(text.count) 字符").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { model.showingComposer = false }.keyboardShortcut(.cancelAction)
                Button("保存片段") { model.addText(text) }.buttonStyle(.borderedProminent).tint(shelfAccent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 500)
    }
}

private final class PreviewCache {
    static let shared = PreviewCache()
    private let cache = NSCache<NSString, NSImage>()
    init() { cache.countLimit = 30; cache.totalCostLimit = 40 * 1024 * 1024 }
    func image(for record: ClipRecord) -> NSImage? {
        let key = record.id.uuidString as NSString
        if let image = cache.object(forKey: key) { return image }
        for item in record.items {
            for type in ["public.png", "public.tiff", "public.jpeg", "public.heic", "com.compuserve.gif"] {
                guard let data = item.representations[type],
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1200, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { continue }
                let image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
                cache.setObject(image, forKey: key, cost: thumbnail.bytesPerRow * thumbnail.height)
                return image
            }
        }
        return nil
    }
}
