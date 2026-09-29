import AppKit
import ImageIO
import UniformTypeIdentifiers
import Darwin

enum AppearanceStorageError: LocalizedError {
    case inputTooLarge
    case invalidImage
    case invalidFile
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .inputTooLarge: return "背景图片不能超过 50 MB。"
        case .invalidImage: return "无法读取这张图片，请选择有效的 PNG、JPEG 或其他受支持的图片。"
        case .invalidFile: return "请选择本机上的普通图片文件。"
        case .encodingFailed: return "背景图片转换失败，原背景已保留。"
        }
    }
}

/// Keeps one local, bounded PNG. A failed import never changes the existing background.
final class AppearanceStorage: Sendable {
    private static let maximumInputBytes = 50 * 1024 * 1024
    private static let maximumDimension = 2200
    private let appearanceDirectory: URL
    private var backgroundURL: URL { appearanceDirectory.appendingPathComponent("background.png") }

    init(directory: URL) {
        appearanceDirectory = directory.appendingPathComponent("appearance", isDirectory: true)
    }

    func loadBackground() throws -> NSImage? {
        do {
            return image(from: try decodedImage(at: backgroundURL))
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return nil
        }
    }

    func importBackground(from url: URL) throws -> NSImage {
        let decoded = try decodedImage(at: url)
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else {
            throw AppearanceStorageError.encodingFailed
        }
        CGImageDestinationAddImage(destination, decoded, nil)
        guard CGImageDestinationFinalize(destination) else { throw AppearanceStorageError.encodingFailed }
        try FileManager.default.createDirectory(
            at: appearanceDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appearanceDirectory.path)
        try atomicWrite(encoded as Data)
        return image(from: decoded)
    }

    func removeBackground() throws {
        guard unlink(backgroundURL.path) == 0 else {
            if errno == ENOENT { return }
            throw posixError()
        }
        syncDirectory()
    }

    private func decodedImage(at url: URL) throws -> CGImage {
        let data = try boundedRead(url)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width.isFinite, height.isFinite, width > 0, height > 0 else {
            throw AppearanceStorageError.invalidImage
        }
        let requestedSize = min(Double(Self.maximumDimension), max(width, height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(requestedSize),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let result = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              result.width <= Self.maximumDimension, result.height <= Self.maximumDimension else {
            throw AppearanceStorageError.invalidImage
        }
        return result
    }

    private func image(from cgImage: CGImage) -> NSImage {
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func boundedRead(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw AppearanceStorageError.invalidFile }
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw posixError() }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else { throw AppearanceStorageError.invalidFile }
        guard metadata.st_size <= Self.maximumInputBytes else { throw AppearanceStorageError.inputTooLarge }
        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let length = read(descriptor, &buffer, buffer.count)
            if length == 0 { return data }
            if length < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            guard data.count <= Self.maximumInputBytes - length else { throw AppearanceStorageError.inputTooLarge }
            data.append(contentsOf: buffer.prefix(length))
        }
    }

    private func atomicWrite(_ data: Data) throws {
        let temporary = appearanceDirectory.appendingPathComponent(".background-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        defer {
            close(descriptor)
            try? FileManager.default.removeItem(at: temporary)
        }
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { throw AppearanceStorageError.encodingFailed }
            var offset = 0
            while offset < bytes.count {
                let length = write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if length < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard length > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
                offset += length
            }
        }
        guard fchmod(descriptor, 0o600) == 0, fsync(descriptor) == 0 else { throw posixError() }
        guard rename(temporary.path, backgroundURL.path) == 0 else { throw posixError() }
        syncDirectory()
    }

    private func syncDirectory() {
        let descriptor = open(appearanceDirectory.path, O_RDONLY | O_CLOEXEC)
        if descriptor >= 0 {
            _ = fsync(descriptor)
            close(descriptor)
        }
    }

    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
