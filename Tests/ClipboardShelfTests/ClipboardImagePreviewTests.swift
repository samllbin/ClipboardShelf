import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ClipboardShelf

final class ClipboardImagePreviewTests: XCTestCase {
    private func bitmap(width: Int = 80, height: Int = 40, red: CGFloat = 1, blue: CGFloat = 0) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func encoded(_ images: [CGImage], type: UTType = .png, orientation: Int = 1) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, images.count, nil))
        for image in images {
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func record(_ data: Data, type: String = "public.png") -> ClipRecord {
        ClipRecord(items: [ClipItem(representations: [type: data])], kind: .image)
    }

    private func color(_ image: CGImage) throws -> (red: UInt8, blue: UInt8) {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (bytes[0], bytes[2])
    }

    func testDownsamplesPreservingOriginalDimensionsAndAspectRatio() throws {
        let source = record(try encoded([bitmap(width: 1600, height: 800)]))
        let result = try XCTUnwrap(ClipboardImagePreviewDecoder.decode(record: source, maxPixelSize: 128))
        XCTAssertEqual(result.pixelWidth, 1600)
        XCTAssertEqual(result.pixelHeight, 800)
        XCTAssertEqual(result.image.width, 128)
        XCTAssertEqual(result.image.height, 64)
    }

    func testPNGJPEGAndTIFFRepresentationsDecode() throws {
        for type in [UTType.png, .jpeg, .tiff] {
            let source = record(try encoded([bitmap()], type: type), type: type.identifier)
            let result = try XCTUnwrap(ClipboardImagePreviewDecoder.decode(record: source, maxPixelSize: 32), type.identifier)
            XCTAssertEqual(result.pixelWidth, 80)
            XCTAssertEqual(result.pixelHeight, 40)
            XCTAssertEqual(result.image.width, 32)
            XCTAssertEqual(result.image.height, 16)
        }
    }

    func testHEICRepresentationDecodesWhenEncoderIsAvailable() throws {
        let encoders = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        try XCTSkipUnless(encoders.contains(UTType.heic.identifier), "This OS does not have an HEIC encoder.")
        let source = record(try encoded([bitmap()], type: .heic), type: UTType.heic.identifier)
        let result = try XCTUnwrap(ClipboardImagePreviewDecoder.decode(record: source, maxPixelSize: 32))
        XCTAssertEqual(result.pixelWidth, 80)
        XCTAssertEqual(result.pixelHeight, 40)
        XCTAssertLessThanOrEqual(result.image.width, 32)
        XCTAssertLessThanOrEqual(result.image.height, 32)
    }

    func testAnimatedGIFUsesOnlyFirstFrame() throws {
        let red = try bitmap()
        let blue = try bitmap(red: 0, blue: 1)
        let source = record(try encoded([red, blue], type: .gif), type: UTType.gif.identifier)
        let result = try XCTUnwrap(ClipboardImagePreviewDecoder.decode(record: source, maxPixelSize: 32))
        let sample = try color(result.image)
        XCTAssertGreaterThan(sample.red, 200)
        XCTAssertLessThan(sample.blue, 30)
    }

    func testEXIFRotationCorrectsThumbnailAndReportedDimensions() throws {
        let source = record(try encoded([bitmap()], type: .jpeg, orientation: 6), type: UTType.jpeg.identifier)
        let result = try XCTUnwrap(ClipboardImagePreviewDecoder.decode(record: source, maxPixelSize: 20))
        XCTAssertEqual(result.pixelWidth, 40)
        XCTAssertEqual(result.pixelHeight, 80)
        XCTAssertEqual(result.image.width, 10)
        XCTAssertEqual(result.image.height, 20)
    }

    func testDamagedPreferredRepresentationFallsBackToAnotherFormatAndItem() throws {
        let valid = try encoded([bitmap()], type: .tiff)
        let corrupted = Data("broken image".utf8)
        let anotherFormat = ClipRecord(items: [ClipItem(representations: [
            "public.png": corrupted, "public.tiff": valid
        ])], kind: .image)
        XCTAssertNotNil(ClipboardImagePreviewDecoder.decode(record: anotherFormat, maxPixelSize: 32))
        let anotherItem = ClipRecord(items: [
            ClipItem(representations: ["public.png": corrupted]),
            ClipItem(representations: ["public.tiff": valid])
        ], kind: .image)
        XCTAssertNotNil(ClipboardImagePreviewDecoder.decode(record: anotherItem, maxPixelSize: 32))
        XCTAssertNil(ClipboardImagePreviewDecoder.decode(record: record(corrupted), maxPixelSize: 32))
    }

    func testDoesNotLoadFileURLsOrEmbeddedRemoteReferences() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-preview-test-\(UUID().uuidString).png")
        try encoded([bitmap()]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = ClipRecord(items: [ClipItem(representations: [
            "public.file-url": Data(url.absoluteString.utf8),
            "public.url": Data("https://example.invalid/picture.png".utf8),
            "public.html": Data("<img src='\(url.absoluteString)'>".utf8)
        ])], kind: .files)
        XCTAssertNil(ClipboardImagePreviewDecoder.decode(record: source, maxPixelSize: 32))
        XCTAssertNil(ClipboardImagePreviewDecoder.decode(record: record(Data(url.absoluteString.utf8)), maxPixelSize: 32))
    }

    func testThumbnailLimitCannotBeBypassedAndSmallImagesAreNotUpscaled() throws {
        let large = record(try encoded([bitmap(width: 1400, height: 700)]))
        let result = try XCTUnwrap(ClipboardImagePreviewDecoder.decode(record: large, maxPixelSize: Int.max))
        XCTAssertEqual(result.image.width, ClipboardImagePreviewDecoder.maximumThumbnailDimension)
        XCTAssertEqual(result.image.height, ClipboardImagePreviewDecoder.maximumThumbnailDimension / 2)
        let small = record(try encoded([bitmap(width: 16, height: 8)]))
        let originalSize = try XCTUnwrap(ClipboardImagePreviewDecoder.decode(record: small, maxPixelSize: 128))
        XCTAssertEqual(originalSize.image.width, 16)
        XCTAssertEqual(originalSize.image.height, 8)
        XCTAssertEqual(ClipboardImagePreviewDecoder.boundedPixelSize(Int.min), 1)
    }

    func testRejectsUnsafeSourceMetadataAndOversizeEncodedData() {
        XCTAssertFalse(ClipboardImagePreviewDecoder.dimensionsAreSafe(width: .infinity, height: 10))
        XCTAssertFalse(ClipboardImagePreviewDecoder.dimensionsAreSafe(width: .nan, height: 10))
        XCTAssertFalse(ClipboardImagePreviewDecoder.dimensionsAreSafe(width: 0, height: 10))
        XCTAssertFalse(ClipboardImagePreviewDecoder.dimensionsAreSafe(width: 10.5, height: 10))
        XCTAssertFalse(ClipboardImagePreviewDecoder.dimensionsAreSafe(width: 40_000, height: 10))
        XCTAssertFalse(ClipboardImagePreviewDecoder.dimensionsAreSafe(width: 20_000, height: 20_000))
        XCTAssertTrue(ClipboardImagePreviewDecoder.dimensionsAreSafe(width: 8000, height: 6000))
        let oversized = record(Data(repeating: 0, count: HistoryPolicy.maximumEntryBytes + 1))
        XCTAssertNil(ClipboardImagePreviewDecoder.decode(record: oversized, maxPixelSize: 32))
    }

    func testCacheSeparatesImageContentByRecordAndRequestedSize() async throws {
        let cache = ClipboardImagePreviewCache()
        let red = record(try encoded([bitmap()]))
        let blue = record(try encoded([bitmap(red: 0, blue: 1)]))
        let redValue = await cache.preview(for: red, maxPixelSize: 16)
        let blueValue = await cache.preview(for: blue, maxPixelSize: 16)
        let largerValue = await cache.preview(for: red, maxPixelSize: 32)
        let repeatedValue = await cache.preview(for: red, maxPixelSize: 16)
        let first = try XCTUnwrap(redValue)
        let second = try XCTUnwrap(blueValue)
        let larger = try XCTUnwrap(largerValue)
        let repeated = try XCTUnwrap(repeatedValue)
        XCTAssertGreaterThan(try color(first.image).red, 200)
        XCTAssertGreaterThan(try color(second.image).blue, 200)
        XCTAssertEqual(first.image.width, 16)
        XCTAssertEqual(larger.image.width, 32)
        XCTAssertTrue(first.image === repeated.image, "Repeated loads should reuse the decoded bitmap.")
    }

    @MainActor
    func testLatePreviousLoadCannotReplaceNewSelection() async throws {
        let first = record(Data())
        let second = record(Data())
        let firstStarted = expectation(description: "First load started")
        let secondStarted = expectation(description: "Second load started")
        var pending: [UUID: CheckedContinuation<ClipboardImagePreviewBitmap?, Never>] = [:]
        let model = ClipboardImagePreviewModel { record, _ in
            await withCheckedContinuation { continuation in
                pending[record.id] = continuation
                (record.id == first.id ? firstStarted : secondStarted).fulfill()
            }
        }
        let firstTask = Task { await model.load(record: first, maxPixelSize: 32) }
        await fulfillment(of: [firstStarted], timeout: 2)
        let secondTask = Task { await model.load(record: second, maxPixelSize: 32) }
        await fulfillment(of: [secondStarted], timeout: 2)
        pending[second.id]?.resume(returning: ClipboardImagePreviewBitmap(image: try bitmap(width: 40, height: 80), pixelWidth: 400, pixelHeight: 800))
        await secondTask.value
        pending[first.id]?.resume(returning: ClipboardImagePreviewBitmap(image: try bitmap(), pixelWidth: 800, pixelHeight: 400))
        await firstTask.value
        guard case .ready(let preview) = model.state else { return XCTFail("Expected the current selection's preview.") }
        XCTAssertEqual(preview.pixelWidth, 400)
        XCTAssertEqual(preview.pixelHeight, 800)
    }

    @MainActor
    func testNewLoadClearsPreviousImageAndReportsUnavailable() async throws {
        let first = record(Data())
        let second = record(Data())
        let decoded = ClipboardImagePreviewBitmap(image: try bitmap(), pixelWidth: 80, pixelHeight: 40)
        let secondStarted = expectation(description: "Replacement load started")
        var pending: CheckedContinuation<ClipboardImagePreviewBitmap?, Never>?
        let model = ClipboardImagePreviewModel { record, _ in
            if record.id == first.id { return decoded }
            return await withCheckedContinuation { continuation in
                pending = continuation
                secondStarted.fulfill()
            }
        }
        await model.load(record: first, maxPixelSize: 32)
        guard case .ready = model.state else { return XCTFail("Expected initial image.") }
        let secondTask = Task { await model.load(record: second, maxPixelSize: 32) }
        await fulfillment(of: [secondStarted], timeout: 2)
        guard case .loading = model.state else {
            pending?.resume(returning: nil)
            await secondTask.value
            return XCTFail("Old images must disappear immediately when selection changes.")
        }
        pending?.resume(returning: nil)
        await secondTask.value
        guard case .unavailable = model.state else { return XCTFail("Failed decoding should show the unavailable state.") }
    }

    @MainActor
    func testCancelledTaskDoesNotPublishLatePreview() async throws {
        let source = record(Data())
        let decoded = ClipboardImagePreviewBitmap(image: try bitmap(), pixelWidth: 80, pixelHeight: 40)
        let started = expectation(description: "Load started")
        var pending: CheckedContinuation<ClipboardImagePreviewBitmap?, Never>?
        let model = ClipboardImagePreviewModel { _, _ in
            await withCheckedContinuation { continuation in
                pending = continuation
                started.fulfill()
            }
        }
        let task = Task { await model.load(record: source, maxPixelSize: 32) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        pending?.resume(returning: decoded)
        await task.value
        guard case .loading = model.state else { return XCTFail("A cancelled task must not publish its image.") }
    }
}
