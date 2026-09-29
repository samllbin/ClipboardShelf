import Foundation
import CryptoKit
import Darwin

enum ClipKind: String, Codable, CaseIterable, Sendable {
    case text, richText, image, files, other
}

struct ClipItem: Codable, Equatable, Sendable {
    var representations: [String: Data]
}

struct ClipRecord: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var lastUsedAt: Date
    var sourceApp: String
    var sourceBundleID: String?
    var items: [ClipItem]
    var text: String?
    var kind: ClipKind
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        lastUsedAt: Date = Date(),
        sourceApp: String = "未知应用",
        sourceBundleID: String? = nil,
        items: [ClipItem],
        text: String? = nil,
        kind: ClipKind,
        isPinned: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.sourceApp = sourceApp
        self.sourceBundleID = sourceBundleID
        self.items = items
        self.text = text
        self.kind = kind
        self.isPinned = isPinned
    }

    var title: String {
        if let text {
            let compact = text.prefix(1024).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !compact.isEmpty { return String(compact.prefix(120)) }
        }
        switch kind {
        case .text: return "空白文本"
        case .richText: return "富文本"
        case .image: return "图片"
        case .files: return items.count > 1 ? "\(items.count) 个文件" : "文件"
        case .other: return "剪贴板内容"
        }
    }

    /// Includes the searchable plain-text copy, so memory and disk bounds also cover it.
    var byteCount: Int {
        items.reduce(text?.utf8.count ?? 0) { total, item in
            total + item.representations.values.reduce(0) { $0 + $1.count }
        }
    }

    /// Framing every field prevents ambiguous concatenations, and item order remains meaningful.
    var fingerprint: String {
        var digest = SHA256()
        func appendLength(_ value: Int) {
            var bigEndian = UInt64(value).bigEndian
            withUnsafeBytes(of: &bigEndian) { digest.update(data: Data($0)) }
        }
        func append(_ data: Data) {
            appendLength(data.count)
            digest.update(data: data)
        }
        appendLength(items.count)
        for item in items {
            appendLength(item.representations.count)
            for type in item.representations.keys.sorted() {
                append(Data(type.utf8))
                append(item.representations[type]!)
            }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct HistoryArchive: Codable, Sendable {
    static let currentVersion = 1
    var version: Int
    var records: [ClipRecord]
    var exportedAt: Date

    init(version: Int = Self.currentVersion, records: [ClipRecord], exportedAt: Date = Date()) {
        self.version = version
        self.records = records
        self.exportedAt = exportedAt
    }
}

enum HistoryPolicy {
    static let maximumEntryBytes = 20 * 1024 * 1024
    static let maximumTotalBytes = 200 * 1024 * 1024
    static let maximumRecords = 500
    static let maximumArchiveBytes = 300 * 1024 * 1024
}

enum HistoryRepositoryError: LocalizedError {
    case unsupportedVersion(Int)
    case archiveTooLarge
    case tooManyRecords
    case entryTooLarge
    case totalTooLarge
    case invalidArchive(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "无法读取版本 \(version) 的剪贴板备份。"
        case .archiveTooLarge: return "备份文件超过 300 MB，无法读取。"
        case .tooManyRecords: return "备份中的记录超过 500 条。"
        case .entryTooLarge: return "单条记录超过 20 MB，未保存或导入。"
        case .totalTooLarge: return "剪贴板记录总量超过 200 MB。"
        case .invalidArchive(let reason): return "剪贴板备份无效：\(reason)"
        }
    }
}

/// Call from a serial I/O queue. No data is changed until validation and encoding succeed.
final class HistoryRepository: Sendable {
    let directory: URL
    var archiveURL: URL { directory.appendingPathComponent("history.json", isDirectory: false) }

    init(directory: URL) { self.directory = directory }

    func load() throws -> [ClipRecord] {
        do {
            return try readArchive(at: archiveURL)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return []
        }
    }

    func save(_ records: [ClipRecord]) throws {
        let data = try encodedArchive(records)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try atomicWrite(data, to: archiveURL)
    }

    func importArchive(from url: URL) throws -> [ClipRecord] {
        try readArchive(at: url)
    }

    func exportArchive(_ records: [ClipRecord], to url: URL) throws {
        try atomicWrite(encodedArchive(records), to: url)
    }

    private func encodedArchive(_ records: [ClipRecord]) throws -> Data {
        let archive = HistoryArchive(records: records)
        try validate(archive)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(archive)
        guard data.count <= HistoryPolicy.maximumArchiveBytes else {
            throw HistoryRepositoryError.archiveTooLarge
        }
        return data
    }

    private func readArchive(at url: URL) throws -> [ClipRecord] {
        // Inspect the open file itself and cap the read even if it grows after fstat.
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw posixError() }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw HistoryRepositoryError.invalidArchive("请选择普通文件。")
        }
        guard metadata.st_size <= HistoryPolicy.maximumArchiveBytes else {
            throw HistoryRepositoryError.archiveTooLarge
        }
        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let length = read(descriptor, &buffer, buffer.count)
            if length == 0 { break }
            if length < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            guard data.count <= HistoryPolicy.maximumArchiveBytes - length else {
                throw HistoryRepositoryError.archiveTooLarge
            }
            data.append(contentsOf: buffer.prefix(length))
        }
        let archive: HistoryArchive
        do {
            archive = try JSONDecoder().decode(HistoryArchive.self, from: data)
        } catch {
            throw HistoryRepositoryError.invalidArchive("文件格式损坏或内容不完整。")
        }
        try validate(archive)
        return archive.records
    }

    private func validate(_ archive: HistoryArchive) throws {
        guard archive.version == HistoryArchive.currentVersion else {
            throw HistoryRepositoryError.unsupportedVersion(archive.version)
        }
        guard archive.records.count <= HistoryPolicy.maximumRecords else {
            throw HistoryRepositoryError.tooManyRecords
        }
        guard archive.exportedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw HistoryRepositoryError.invalidArchive("导出时间无效。")
        }
        var totalBytes = 0
        var seenIDs = Set<UUID>()
        for record in archive.records {
            guard seenIDs.insert(record.id).inserted else {
                throw HistoryRepositoryError.invalidArchive("记录标识重复。")
            }
            guard !record.items.isEmpty,
                  record.items.allSatisfy({ !$0.representations.isEmpty && $0.representations.keys.allSatisfy({ !$0.isEmpty }) }),
                  record.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  record.lastUsedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw HistoryRepositoryError.invalidArchive("记录没有有效内容或时间。")
            }
            // Metadata is bounded too, rather than accepting an arbitrarily large source label.
            guard record.sourceApp.utf8.count <= 4096,
                  (record.sourceBundleID?.utf8.count ?? 0) <= 4096,
                  record.items.count <= 10_000,
                  record.items.allSatisfy({ item in
                      item.representations.count <= 1024 && item.representations.keys.allSatisfy { $0.utf8.count <= 4096 }
                  }) else {
                throw HistoryRepositoryError.invalidArchive("记录元数据过大。")
            }
            guard record.byteCount <= HistoryPolicy.maximumEntryBytes else {
                throw HistoryRepositoryError.entryTooLarge
            }
            totalBytes += record.byteCount
            guard totalBytes <= HistoryPolicy.maximumTotalBytes else {
                throw HistoryRepositoryError.totalTooLarge
            }
        }
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".clipboard-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        defer {
            close(descriptor)
            try? FileManager.default.removeItem(at: temporary)
        }
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
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
        guard rename(temporary.path, destination.path) == 0 else { throw posixError() }
        // Flush the directory entry as well; some filesystem types do not support it.
        let parent = open(destination.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        if parent >= 0 {
            _ = fsync(parent)
            close(parent)
        }
    }

    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

enum HistoryOperations {
    static func inserting(_ record: ClipRecord, into records: [ClipRecord]) -> [ClipRecord] {
        merging([record], into: records)
    }

    static func merging(_ incoming: [ClipRecord], into existing: [ClipRecord]) -> [ClipRecord] {
        // Hash each payload only once. Importing 500 entries must not repeatedly hash
        // the entire archive for every insertion.
        let current = normalized(existing)
        let lookup = Dictionary(uniqueKeysWithValues: current.map { ($0.fingerprint, $0.record) })
        let additions = normalized(incoming).map { entry -> FingerprintedRecord in
            var entry = entry
            if let previous = lookup[entry.fingerprint] {
                entry.record.id = previous.id
                entry.record.createdAt = previous.createdAt
                entry.record.isPinned = previous.isPinned || entry.record.isPinned
            }
            return entry
        }
        let incomingFingerprints = Set(additions.map(\.fingerprint))
        var combined = additions + current.filter { !incomingFingerprints.contains($0.fingerprint) }
        // Prefer existing IDs when independent imported content happens to reuse one.
        let existingIDs = Set(current.map { $0.record.id })
        for index in combined.indices where index < additions.count {
            if lookup[combined[index].fingerprint] == nil && existingIDs.contains(combined[index].record.id) {
                combined[index].record.id = UUID()
            }
        }
        return limited(combined.map(\.record))
    }

    static func applyingLimits(to records: [ClipRecord]) -> [ClipRecord] {
        limited(normalized(records).map(\.record))
    }

    private struct FingerprintedRecord {
        var record: ClipRecord
        var fingerprint: String
    }

    private static func normalized(_ records: [ClipRecord]) -> [FingerprintedRecord] {
        var unique: [FingerprintedRecord] = []
        var indices: [String: Int] = [:]
        var usedIDs = Set<UUID>()
        for var record in records where record.byteCount <= HistoryPolicy.maximumEntryBytes && !record.items.isEmpty {
            let fingerprint = record.fingerprint
            if let index = indices[fingerprint] {
                unique[index].record.isPinned = unique[index].record.isPinned || record.isPinned
                continue
            }
            if !usedIDs.insert(record.id).inserted {
                record.id = UUID()
                usedIDs.insert(record.id)
            }
            indices[fingerprint] = unique.count
            unique.append(FingerprintedRecord(record: record, fingerprint: fingerprint))
        }
        return unique
    }

    private static func limited(_ unique: [ClipRecord]) -> [ClipRecord] {
        var selected = Set<UUID>()
        var totalBytes = 0
        // Pins receive retention priority, but cannot bypass the hard storage bounds.
        for pinned in [true, false] {
            for record in unique where record.isPinned == pinned {
                guard selected.count < HistoryPolicy.maximumRecords,
                      totalBytes <= HistoryPolicy.maximumTotalBytes - record.byteCount else { continue }
                selected.insert(record.id)
                totalBytes += record.byteCount
            }
        }
        return unique.filter { selected.contains($0.id) }
    }
}
