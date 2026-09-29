import AppKit
import SwiftUI

/// A small, keyboard-first candidate window presented beside the insertion point.
/// Its controller owns key handling so search and selection share the same keys.
struct CandidateView: View {
    @ObservedObject var candidate: CandidateModel
    @ObservedObject var appModel: AppModel

    private var visibleRecords: [ClipRecord] { candidate.filteredRecords }
    private var keyboardHint: String {
        if candidate.selectedRecord?.kind == .image && candidate.query.isEmpty {
            return candidate.isImagePreviewExpanded ? "↑↓ 换图  空格收起  ↩ 粘贴" : "↑↓ 选择  空格预览  ↩ 粘贴"
        }
        return "↑↓ 选择  ↩ 粘贴  esc 取消"
    }
    var body: some View {
        GeometryReader { geometry in
            let heights = CandidateLayout.contentHeights(for: geometry.size.height, isImagePreviewExpanded: candidate.isImagePreviewExpanded)
            VStack(spacing: 0) {
                header
                searchField
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                candidates
                    .frame(height: heights.list)
                if candidate.isImagePreviewExpanded, let record = candidate.selectedRecord {
                    CandidateImageDetail(record: record) { _ = candidate.closeImagePreview() }
                        .id(record.id)
                        .frame(height: heights.preview)
                }
                footer
            }
            .padding(.vertical, 4)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    if let image = appModel.backgroundImage {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                            .opacity(appModel.backgroundOpacity)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        }
        .tint(appModel.accent)
        .preferredColorScheme(appModel.appearance.colorScheme)
        .accessibilityIdentifier("clipboard-candidates")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(appModel.accent)
                .accessibilityHidden(true)
            Text("剪贴历史").fontWeight(.semibold)
            Spacer()
            Text("\((candidate.filteredRecords.firstIndex { $0.id == candidate.selectedID }.map { $0 + 1 }) ?? 0) / \(candidate.filteredRecords.count)")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 13)
        .frame(height: 30)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("搜索内容或来源", text: $candidate.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .accessibilityLabel("搜索剪贴历史")
                .accessibilityIdentifier("candidate-search-field")
            if !candidate.query.isEmpty {
                Button { candidate.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.9), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private var candidates: some View {
        Group {
            if visibleRecords.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: candidate.query.isEmpty ? "clipboard" : "magnifyingglass")
                        .font(.system(size: 23, weight: .light))
                        .foregroundStyle(appModel.accent)
                        .accessibilityHidden(true)
                    Text(candidate.query.isEmpty ? "还没有剪贴记录" : "没有找到相关内容")
                        .font(.system(size: 12, weight: .medium))
                    Text(candidate.query.isEmpty ? "复制内容后，长按 ⌘V 选择历史。" : "试试内容关键词或应用名称。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(visibleRecords) { record in
                                candidateRow(record)
                                    .id(record.id)
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                    .onChange(of: candidate.selectedID) { id in
                        if let id { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: candidate.query) { _ in
                        if let id = candidate.selectedID { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onAppear {
                        if let id = candidate.selectedID { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
    }

    private func candidateRow(_ record: ClipRecord) -> some View {
        let selected = candidate.selectedID == record.id
        let foreground: Color = selected ? appModel.onAccent : .primary
        return HStack(spacing: 5) {
            Button { candidate.choose(record) } label: {
                HStack(spacing: 9) {
                    if record.kind == .image {
                        CandidateImageThumbnail(record: record)
                    } else {
                        Image(systemName: record.isLink ? "link" : record.kind.icon)
                            .font(.system(size: 13))
                            .frame(width: 18)
                            .foregroundStyle(selected ? foreground : appModel.accent)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.title)
                            .font(.system(size: 12, weight: selected ? .medium : .regular))
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Text(record.sourceApp).lineLimit(1)
                            Text("·")
                            Text(record.lastUsedAt, style: .time)
                            if record.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 8))
                            }
                        }
                        .font(.system(size: 9))
                        .foregroundStyle(selected ? foreground.opacity(0.85) : Color.secondary)
                    }
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "return")
                            .font(.system(size: 11))
                            .foregroundStyle(foreground.opacity(0.85))
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityLabel("\(record.title)，\(record.kind.label)，来自 \(record.sourceApp)\(record.isPinned ? "，已收藏" : "")")
            .accessibilityHint("粘贴到原应用")
            .accessibilityAddTraits(selected ? .isSelected : [])
            if record.kind == .image {
                Button {
                    let wasExpandedSelection = selected && candidate.isImagePreviewExpanded
                    candidate.selectedID = record.id
                    if wasExpandedSelection { _ = candidate.closeImagePreview() }
                    else if !candidate.isImagePreviewExpanded { candidate.toggleImagePreview() }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .frame(width: 24, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .foregroundStyle(selected ? foreground : appModel.accent)
                .accessibilityLabel(selected && candidate.isImagePreviewExpanded ? "收起图片预览" : "预览图片")
                .accessibilityHint("只预览，不粘贴")
                .accessibilityIdentifier("preview-\(record.id.uuidString)")
                .help("预览图片，不粘贴；选中后也可按空格")
            }
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 9)
        .frame(height: 42)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? appModel.accent : Color(nsColor: .windowBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 7))
        .padding(.vertical, 1)
        .accessibilityIdentifier("candidate-\(record.id.uuidString)")
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(candidate.status.isEmpty ? keyboardHint : candidate.status)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(candidate.status.isEmpty ? "↑↓ 选择 · Fn+↑↓ 翻页 · 空搜索时按空格预览图片 · ↩ 粘贴 · esc 收起预览或取消" : candidate.status)
            Spacer(minLength: 2)
            Menu {
                Button("管理历史记录…") { candidate.openLibrary?() }
                Button("皮肤与背景图片…") { candidate.openThemes?() }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 18)
            .accessibilityLabel("剪贴板设置")
            .help("管理历史记录、皮肤与背景图片")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }
}

private struct CandidateImageThumbnail: View {
    let record: ClipRecord
    @StateObject private var preview = ClipboardImagePreviewModel()

    var body: some View {
        ZStack {
            ImageTransparencyGrid()
            switch preview.state {
            case .loading:
                ProgressView().controlSize(.mini)
            case .unavailable:
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 16))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            case .ready(let content):
                Image(nsImage: content.image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
        .accessibilityHidden(true)
        .task(id: record.id) { await preview.load(record: record, maxPixelSize: 128) }
    }
}

private struct CandidateImageDetail: View {
    let record: ClipRecord
    let onClose: () -> Void
    @StateObject private var preview = ClipboardImagePreviewModel()

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Text("图片预览").fontWeight(.medium)
                if case .ready(let content) = preview.state {
                    Text("\(content.pixelWidth) × \(content.pixelHeight)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityLabel("收起图片预览")
                .help("收起图片预览（Esc）")
            }
            .font(.system(size: 10))
            ZStack {
                ImageTransparencyGrid()
                switch preview.state {
                case .loading:
                    ProgressView("正在加载图片…").controlSize(.small)
                case .unavailable:
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                        Text("无法预览这张图片").font(.system(size: 11))
                        Text("仍可按回车粘贴原始内容").font(.system(size: 10))
                    }
                    .foregroundStyle(.secondary)
                case .ready(let content):
                    Image(nsImage: content.image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .accessibilityLabel("所选剪贴记录的图片预览，\(content.pixelWidth) 乘 \(content.pixelHeight) 像素")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.1), lineWidth: 1))
        }
        .padding(.horizontal, 12)
        .padding(.top, 5)
        .padding(.bottom, 3)
        .accessibilityIdentifier("candidate-image-preview")
        .task(id: record.id) { await preview.load(record: record, maxPixelSize: 640) }
    }
}

/// Neutral checks keep transparent white or dark images visible in either theme.
private struct ImageTransparencyGrid: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 8
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.96)))
            for row in 0..<Int(ceil(size.height / step)) {
                for column in 0..<Int(ceil(size.width / step)) where (row + column).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(column) * step, y: CGFloat(row) * step, width: step, height: step)), with: .color(Color(white: 0.86)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
