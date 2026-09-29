import Foundation

/// Searches only the supplied record. It never reads files or the system clipboard.
enum ClipSearch {
    private static let foldingLocale = Locale(identifier: "en_US_POSIX")

    /// Whitespace separates required terms; each term may occur in a different field.
    static func matches(_ record: ClipRecord, query: String) -> Bool {
        let terms = normalized(query).split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return true }

        var fields = [record.title, record.text ?? "", record.sourceApp,
                      record.sourceBundleID ?? "", kindKeywords(record.kind)]
        for item in record.items {
            for type in ["public.file-url", "public.url"] {
                guard let data = item.representations[type],
                      let value = String(data: data, encoding: .utf8) else { continue }
                fields.append(value)
                if let decoded = value.removingPercentEncoding, decoded != value {
                    fields.append(decoded)
                }
            }
            if let data = item.representations["NSFilenamesPboardType"],
               let paths = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
                fields.append(contentsOf: paths)
            }
        }
        let content = normalized(fields.joined(separator: "\n"))
        return terms.allSatisfy { content.contains($0) }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: foldingLocale)
    }

    private static func kindKeywords(_ kind: ClipKind) -> String {
        switch kind {
        case .text: return "文本 纯文本 text"
        case .richText: return "富文本 rich text richtext"
        case .image: return "图片 图像 image"
        case .files: return "文件 files"
        case .other: return "其他 剪贴板内容 other"
        }
    }
}
