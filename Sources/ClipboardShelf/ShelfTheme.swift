import AppKit
import SwiftUI

enum ShelfTheme: String, CaseIterable, Identifiable, Codable {
    case sage, ocean, rose, amber, violet, graphite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sage: return "竹青"
        case .ocean: return "海盐蓝"
        case .rose: return "玫瑰"
        case .amber: return "琥珀"
        case .violet: return "鸢尾"
        case .graphite: return "石墨"
        }
    }

    var subtitle: String {
        switch self {
        case .sage: return "清新而从容"
        case .ocean: return "一抹晴空"
        case .rose: return "温柔的日常"
        case .amber: return "留住暖光"
        case .violet: return "灵感悄然来临"
        case .graphite: return "专注于内容"
        }
    }

    /// Darker accents against light backgrounds; brighter accents against dark ones.
    var accent: Color {
        let light = lightHex
        let dark = darkHex
        return Color(nsColor: NSColor(name: NSColor.Name("ShelfTheme.\(rawValue).accent")) { appearance in
            Self.color(hex: Self.isDark(appearance) ? dark : light)
        })
    }

    /// Fixed samples make every theme recognizable before it is selected.
    var swatch: Color { Color(nsColor: Self.color(hex: lightHex)) }

    /// Use on a custom accent-filled surface instead of hardcoding white text.
    var onAccent: Color {
        Color(nsColor: NSColor(name: NSColor.Name("ShelfTheme.onAccent")) { appearance in
            Self.isDark(appearance) ? Self.color(hex: 0x14201D) : .white
        })
    }

    private var lightHex: UInt32 {
        switch self {
        case .sage: return 0x26765F
        case .ocean: return 0x1E67A8
        case .rose: return 0xAC365B
        case .amber: return 0x956007
        case .violet: return 0x7350AD
        case .graphite: return 0x525E6D
        }
    }

    private var darkHex: UInt32 {
        switch self {
        case .sage: return 0x87D5B2
        case .ocean: return 0x8FC9FF
        case .rose: return 0xFFA0BC
        case .amber: return 0xF2C470
        case .violet: return 0xC4ADFF
        case .graphite: return 0xB9C8D9
        }
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private static func color(hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

enum ShelfAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

struct ThemePickerView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    customSkinSection
                    presetsSection
                    appearanceSection
                    livePreview
                }
                .padding(26)
            }
            Divider()
            footer.padding(.horizontal, 26).padding(.vertical, 16)
        }
        .frame(width: 620, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(model.accent)
        .preferredColorScheme(model.appearance.colorScheme)
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "paintpalette.fill")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(model.accent)
                .frame(width: 49, height: 49)
                .background(model.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 5) {
                Text("外观与自定义皮肤").font(.system(size: 21, weight: .semibold))
                Text("用自己的图片和颜色，装点每天的工作。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var customSkinSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("我的皮肤", systemImage: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("图片仅保存在此 Mac").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                backgroundThumbnail
                VStack(alignment: .leading, spacing: 9) {
                    Text(model.backgroundImage == nil ? "上传一张喜欢的图片" : "你的专属背景")
                        .font(.system(size: 12, weight: .medium))
                    Text("让照片、插画或纹理，成为剪贴板的背景。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button { model.chooseBackgroundImage() } label: {
                            Label(model.backgroundImage == nil ? "选择图片…" : "更换图片…", systemImage: "photo.badge.plus")
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        if model.backgroundImage != nil {
                            Button("移除") { model.removeBackgroundImage() }
                                .buttonStyle(.borderless).controlSize(.small)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                Text("背景浓度").font(.system(size: 11))
                Slider(value: $model.backgroundOpacity, in: 0.05...0.5, step: 0.01)
                    .disabled(model.backgroundImage == nil)
                    .accessibilityLabel("背景浓度")
                Text("\(Int((model.backgroundOpacity * 100).rounded()))%")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
            Divider()
            HStack(spacing: 18) {
                Toggle("自定义主题色", isOn: $model.usesCustomAccent)
                    .toggleStyle(.switch).font(.system(size: 11)).controlSize(.small)
                Spacer()
                ColorPicker("颜色", selection: $model.customAccentColor, supportsOpacity: false)
                    .font(.system(size: 11)).fixedSize()
                    .disabled(!model.usesCustomAccent)
            }
        }
        .padding(16)
        .background(model.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(model.accent.opacity(0.17), lineWidth: 1))
    }

    private var backgroundThumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
            if let image = model.backgroundImage {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: 132, height: 86).clipped()
            } else {
                VStack(spacing: 7) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 22, weight: .light))
                    Text("添加背景图片").font(.system(size: 9))
                }
                .foregroundStyle(model.accent.opacity(0.8))
            }
        }
        .frame(width: 132, height: 86)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .accessibilityLabel(model.backgroundImage == nil ? "尚未选择背景图片" : "当前背景图片预览")
    }

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("内置配色").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("可搭配你的背景图片").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(ShelfTheme.allCases) { theme in themeCard(theme) }
            }
        }
    }

    private var appearanceSection: some View {
        HStack(spacing: 20) {
            Label("显示模式", systemImage: "circle.lefthalf.filled")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Picker("显示模式", selection: $model.appearance) {
                ForEach(ShelfAppearance.allCases) { appearance in
                    Text(appearance.title).tag(appearance)
                }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 285)
        }
    }

    private var footer: some View {
        HStack {
            Image(systemName: "checkmark.circle").foregroundStyle(model.accent)
            Text("更改即时生效，偏好自动保存")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button("完成") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
    }

    private func themeCard(_ theme: ShelfTheme) -> some View {
        let selected = model.theme == theme && !model.usesCustomAccent
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                model.theme = theme
                model.usesCustomAccent = false
            }
        } label: {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 31, height: 31)
                        .background(theme.swatch.gradient, in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 5) {
                        Capsule().fill(theme.swatch.opacity(0.65)).frame(width: 49, height: 4)
                        Capsule().fill(theme.swatch.opacity(0.22)).frame(width: 33, height: 4)
                    }
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(theme.accent)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(theme.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                Text(theme.subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? theme.accent.opacity(0.09) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 13)
            )
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(
                selected ? theme.accent : Color.primary.opacity(0.09),
                lineWidth: selected ? 1.6 : 1
            ))
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.title)，\(theme.subtitle)")
        .accessibilityValue(selected ? "已选中" : "未选中")
    }

    private var livePreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("实时预览").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text(model.usesCustomAccent ? "自定义" : model.theme.title)
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(model.accent)
            }
            HStack(spacing: 0) {
                VStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.fill")
                    Image(systemName: "pin")
                }
                .font(.system(size: 12))
                .foregroundStyle(model.accent)
                .frame(width: 48, height: 69)
                .background(model.accent.opacity(0.1))
                Divider().frame(height: 69)
                VStack(alignment: .leading, spacing: 5) {
                    Text("刚刚复制的灵感").font(.system(size: 12, weight: .medium))
                    Text("随时找回，继续创作。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 15)
                Spacer()
                Label("复制", systemImage: "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(model.onAccent)
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .background(model.accent, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.trailing, 15)
            }
            .background {
                ZStack {
                    Color(nsColor: .controlBackgroundColor)
                    if let image = model.backgroundImage {
                        GeometryReader { geometry in
                            Image(nsImage: image).resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped().opacity(model.backgroundOpacity)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.07), lineWidth: 1))
            .accessibilityElement(children: .combine)
        }
    }

}
