import XCTest
@testable import ClipboardShelf

final class HistoryCoreTests: XCTestCase {
    private var directory: URL!
    private var repository: HistoryRepository!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardShelfTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        repository = HistoryRepository(directory: directory.appendingPathComponent("history"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func record(_ value: String, pinned: Bool = false) -> ClipRecord {
        ClipRecord(sourceApp: "测试应用", sourceBundleID: "example.tests", items: [
            ClipItem(representations: ["public.utf8-plain-text": Data(value.utf8)])
        ], text: value, kind: .text, isPinned: pinned)
    }

    func testRoundTripPreservesAllBinaryRepresentationsAndMetadata() throws {
        let binary = Data((0...255).map(UInt8.init))
        let original = ClipRecord(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.12345),
            lastUsedAt: Date(timeIntervalSince1970: 1_700_000_003.98765),
            sourceApp: "图像与文件", sourceBundleID: "example.binary",
            items: [
                ClipItem(representations: ["public.png": binary, "public.tiff": Data(binary.reversed()), "com.example.custom": binary]),
                ClipItem(representations: ["public.file-url": Data("file:///tmp/a%20b.png".utf8), "public.rtf": binary])
            ], text: "附件与格式", kind: .files, isPinned: true
        )
        try repository.save([original])
        XCTAssertEqual(try repository.load(), [original])
        let fileMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: repository.archiveURL.path)[.posixPermissions] as? NSNumber)
        let directoryMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: repository.directory.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(fileMode.intValue & 0o777, 0o600)
        XCTAssertEqual(directoryMode.intValue & 0o777, 0o700)
        let exportURL = directory.appendingPathComponent("backup.json")
        try repository.exportArchive([original], to: exportURL)
        XCTAssertEqual(try repository.importArchive(from: exportURL), [original])
    }

    func testRepeatedCopyPreservesIdentityCreationTimeAndPinsAndMovesToFront() {
        var old = record("same", pinned: true)
        old.createdAt = Date(timeIntervalSince1970: 1)
        old.lastUsedAt = Date(timeIntervalSince1970: 2)
        let other = record("other")
        var latest = record("same")
        latest.sourceApp = "新来源"
        latest.lastUsedAt = Date(timeIntervalSince1970: 3)
        let result = HistoryOperations.inserting(latest, into: [other, old])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].id, old.id)
        XCTAssertEqual(result[0].createdAt, old.createdAt)
        XCTAssertEqual(result[0].lastUsedAt, latest.lastUsedAt)
        XCTAssertEqual(result[0].sourceApp, "新来源")
        XCTAssertTrue(result[0].isPinned)
        XCTAssertEqual(result[1].id, other.id)
    }

    func testFingerprintUsesSortedTypesAndUnambiguousLengthFraming() {
        var first = record("a")
        first.items = [ClipItem(representations: ["a": Data("bc".utf8), "other": Data([0, 255])])]
        var reordered = first
        reordered.items = [ClipItem(representations: ["other": Data([0, 255]), "a": Data("bc".utf8)])]
        XCTAssertEqual(first.fingerprint, reordered.fingerprint)
        var differentlyFramed = first
        differentlyFramed.items = [ClipItem(representations: ["ab": Data("c".utf8), "other": Data([0, 255])])]
        XCTAssertNotEqual(first.fingerprint, differentlyFramed.fingerprint)
        var differentItems = first
        differentItems.items = [ClipItem(representations: ["a": Data("bc".utf8)]), ClipItem(representations: ["other": Data([0, 255])])]
        XCTAssertNotEqual(first.fingerprint, differentItems.fingerprint)
    }

    func testCountLimitPreservesOlderPinAndNewestUnpinnedRecords() {
        let unpinned = (0..<510).map { record("record-\($0)") }
        let oldestPin = record("keep-me", pinned: true)
        let result = HistoryOperations.applyingLimits(to: unpinned + [oldestPin])
        XCTAssertEqual(result.count, 500)
        XCTAssertEqual(Array(result.prefix(499)).map(\.id), Array(unpinned.prefix(499)).map(\.id))
        XCTAssertEqual(result.last?.id, oldestPin.id)
    }

    func testPinsCannotExceedHardCountLimit() {
        let records = (0..<501).map { record("pin-\($0)", pinned: true) }
        let result = HistoryOperations.applyingLimits(to: records)
        XCTAssertEqual(result.count, 500)
        XCTAssertEqual(result.map(\.id), Array(records.prefix(500)).map(\.id))
    }

    func testTotalByteLimitRetainsPinAndWholeRepresentations() {
        let payload = Data(repeating: 42, count: HistoryPolicy.maximumEntryBytes - 8)
        let records = (0..<11).map { index -> ClipRecord in
            var item = record("\(index)", pinned: index == 10)
            item.items = [ClipItem(representations: ["public.png": payload, "id": Data([UInt8(index)])])]
            return item
        }
        let result = HistoryOperations.applyingLimits(to: records)
        XCTAssertEqual(result.count, 10)
        XCTAssertTrue(result.contains { $0.id == records[10].id })
        XCTAssertFalse(result.contains { $0.id == records[9].id })
        XCTAssertLessThanOrEqual(result.reduce(0) { $0 + $1.byteCount }, HistoryPolicy.maximumTotalBytes)
        XCTAssertTrue(result.allSatisfy { $0.items[0].representations["public.png"] == payload })
    }

    func testMergingKeepsExistingIdentityAndPinsAndIncomingOrder() {
        let existing = record("a", pinned: true)
        let importedA = record("a")
        let importedB = record("b")
        let result = HistoryOperations.merging([importedB, importedA], into: [existing])
        XCTAssertEqual(result.map(\.text), ["b", "a"])
        XCTAssertEqual(result[1].id, existing.id)
        XCTAssertTrue(result[1].isPinned)
    }

    func testMalformedAndUnsupportedImportLeaveSavedHistoryIntact() throws {
        let original = record("safe")
        try repository.save([original])
        let importURL = directory.appendingPathComponent("invalid.json")
        try Data("{broken".utf8).write(to: importURL)
        XCTAssertThrowsError(try repository.importArchive(from: importURL))
        let unsupported = HistoryArchive(version: 99, records: [record("future")])
        try JSONEncoder().encode(unsupported).write(to: importURL)
        XCTAssertThrowsError(try repository.importArchive(from: importURL)) { error in
            guard case HistoryRepositoryError.unsupportedVersion(99) = error else {
                return XCTFail("Expected unsupported version, got \(error)")
            }
        }
        XCTAssertEqual(try repository.load(), [original])
    }

    func testOversizedRecordSaveAndImportDoNotReplaceExistingData() throws {
        let original = record("safe")
        try repository.save([original])
        var oversized = record("oversized")
        oversized.items = [ClipItem(representations: ["public.png": Data(repeating: 1, count: HistoryPolicy.maximumEntryBytes + 1)])]
        XCTAssertThrowsError(try repository.save([oversized]))
        let importURL = directory.appendingPathComponent("oversized.json")
        try JSONEncoder().encode(HistoryArchive(records: [oversized])).write(to: importURL)
        XCTAssertThrowsError(try repository.importArchive(from: importURL))
        XCTAssertEqual(try repository.load(), [original])
    }

    func testEmptyAndDuplicateIDArchivesAreRejected() throws {
        let importURL = directory.appendingPathComponent("invalid-records.json")
        var empty = record("empty")
        empty.items = []
        try JSONEncoder().encode(HistoryArchive(records: [empty])).write(to: importURL)
        XCTAssertThrowsError(try repository.importArchive(from: importURL))
        let original = record("a")
        var duplicateID = record("b")
        duplicateID.id = original.id
        try JSONEncoder().encode(HistoryArchive(records: [original, duplicateID])).write(to: importURL)
        XCTAssertThrowsError(try repository.importArchive(from: importURL))
    }

    func testOversizedInputIsRejectedBeforeDecoding() throws {
        let importURL = directory.appendingPathComponent("huge.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: importURL.path, contents: Data()))
        let file = try FileHandle(forWritingTo: importURL)
        try file.truncate(atOffset: UInt64(HistoryPolicy.maximumArchiveBytes + 1))
        try file.close()
        XCTAssertThrowsError(try repository.importArchive(from: importURL)) { error in
            guard case HistoryRepositoryError.archiveTooLarge = error else {
                return XCTFail("Expected archive size rejection, got \(error)")
            }
        }
    }

    func testMergeRepairsCrossArchiveIDCollisionWithoutChangingExistingID() {
        let existing = record("original")
        var incoming = record("different")
        incoming.id = existing.id
        let result = HistoryOperations.merging([incoming], into: [existing])
        XCTAssertEqual(result.count, 2)
        XCTAssertNotEqual(result[0].id, result[1].id)
        XCTAssertEqual(result[1].id, existing.id)
    }

    func testMissingHistoryIsEmptyAndCorruptionIsReported() throws {
        XCTAssertEqual(try repository.load(), [])
        try repository.save([record("a")])
        try Data("bad".utf8).write(to: repository.archiveURL)
        XCTAssertThrowsError(try repository.load())
        XCTAssertEqual(try Data(contentsOf: repository.archiveURL), Data("bad".utf8))
    }
}
