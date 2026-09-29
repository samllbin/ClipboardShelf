import AppKit
import Combine
import ImageIO

struct ClipboardImagePreview {
    let image: NSImage
    /// Original pixel dimensions in the image's displayed (EXIF-corrected) orientation.
    let pixelWidth: Int
    let pixelHeight: Int
}

enum ClipboardImagePreviewState {
    case loading
    case unavailable
    case ready(ClipboardImagePreview)
}

/// One instance per visible preview. SwiftUI should call `load` from `.task(id:)`.
@MainActor
final class ClipboardImagePreviewModel: ObservableObject {
    @Published private(set) var state: ClipboardImagePreviewState = .loading
    private var requestID = UUID()
    private let loader: (ClipRecord, Int) async -> ClipboardImagePreviewBitmap?

    init() {
        loader = { record, size in
            await ClipboardImagePreviewCache.shared.preview(for: record, maxPixelSize: size)
        }
    }

    /// Injection keeps asynchronous replacement/cancellation tests deterministic.
    init(loader: @escaping (ClipRecord, Int) async -> ClipboardImagePreviewBitmap?) {
        self.loader = loader
    }

    func load(record: ClipRecord, maxPixelSize: Int) async {
        let request = UUID()
        requestID = request
        state = .loading
        let decoded = await loader(record, maxPixelSize)
        guard requestID == request, !Task.isCancelled else { return }
        if let decoded {
            state = .ready(ClipboardImagePreview(
                image: NSImage(cgImage: decoded.image, size: NSSize(width: decoded.image.width, height: decoded.image.height)),
                pixelWidth: decoded.pixelWidth,
                pixelHeight: decoded.pixelHeight
            ))
        } else {
            state = .unavailable
        }
    }
}

/// CGImage is immutable; AppKit's NSImage wrapper is only constructed on the main actor.
struct ClipboardImagePreviewBitmap: @unchecked Sendable {
    let image: CGImage
    let pixelWidth: Int
    let pixelHeight: Int
}

enum ClipboardImagePreviewDecoder {
    static let maximumThumbnailDimension = 1024
    static let maximumSourceDimension = 32_768
    static let maximumSourcePixels = 100_000_000
    static let supportedTypes = [
        "public.png", "public.tiff", "public.jpeg", "public.heic", "public.heif", "com.compuserve.gif"
    ]

    static func boundedPixelSize(_ requested: Int) -> Int {
        min(maximumThumbnailDimension, max(1, requested))
    }

    /// Receives only stored representation bytes. Never resolves file URLs, HTML, or remote resources.
    static func decode(record: ClipRecord, maxPixelSize: Int) -> ClipboardImagePreviewBitmap? {
        let limit = boundedPixelSize(maxPixelSize)
        for item in record.items {
            for type in supportedTypes {
                guard let data = item.representations[type],
                      !data.isEmpty, data.count <= HistoryPolicy.maximumEntryBytes else { continue }
                if let decoded = decode(data: data, limit: limit) { return decoded }
            }
        }
        return nil
    }

    private static func decode(data: Data, limit: Int) -> ClipboardImagePreviewBitmap? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let actualType = CGImageSourceGetType(source) as String?,
              supportedTypes.contains(actualType),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let rawHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              dimensionsAreSafe(width: rawWidth, height: rawHeight) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(limit, Int(max(rawWidth, rawHeight))),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              thumbnail.width > 0, thumbnail.height > 0,
              thumbnail.width <= limit, thumbnail.height <= limit else { return nil }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotatesAxes = (5...8).contains(orientation)
        return ClipboardImagePreviewBitmap(
            image: thumbnail,
            pixelWidth: Int(rotatesAxes ? rawHeight : rawWidth),
            pixelHeight: Int(rotatesAxes ? rawWidth : rawHeight)
        )
    }

    /// Reject hostile metadata before requesting pixel decoding, including integer-overflow cases.
    static func dimensionsAreSafe(width: Double, height: Double) -> Bool {
        width.isFinite && height.isFinite && width >= 1 && height >= 1 &&
            width.rounded(.down) == width && height.rounded(.down) == height &&
            width <= Double(maximumSourceDimension) && height <= Double(maximumSourceDimension) &&
            width * height <= Double(maximumSourcePixels)
    }
}

/// A serial utility queue prevents many visible rows from decoding large sources concurrently.
/// Cache keys use stable history IDs, avoiding hashing multi-megabyte blobs on the main actor.
final class ClipboardImagePreviewCache: @unchecked Sendable {
    static let shared = ClipboardImagePreviewCache()
    private let queue = DispatchQueue(label: "local.clipboardshelf.image-previews", qos: .utility)
    private let cache = NSCache<NSString, Entry>()

    private final class Entry {
        let bitmap: ClipboardImagePreviewBitmap?
        init(_ bitmap: ClipboardImagePreviewBitmap?) { self.bitmap = bitmap }
    }

    init() {
        cache.countLimit = 96
        cache.totalCostLimit = 24 * 1024 * 1024
    }

    func preview(for record: ClipRecord, maxPixelSize: Int) async -> ClipboardImagePreviewBitmap? {
        let size = ClipboardImagePreviewDecoder.boundedPixelSize(maxPixelSize)
        let key = "\(record.id.uuidString):\(size)"
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                autoreleasepool {
                    let cacheKey = key as NSString
                    if let entry = cache.object(forKey: cacheKey) {
                        continuation.resume(returning: entry.bitmap)
                        return
                    }
                    let bitmap = ClipboardImagePreviewDecoder.decode(record: record, maxPixelSize: size)
                    let cost = bitmap.map { $0.image.bytesPerRow * $0.image.height } ?? 1
                    cache.setObject(Entry(bitmap), forKey: cacheKey, cost: cost)
                    continuation.resume(returning: bitmap)
                }
            }
        }
    }
}
