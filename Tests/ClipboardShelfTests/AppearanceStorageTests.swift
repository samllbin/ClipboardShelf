import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ClipboardShelf

final class AppearanceStorageTests: XCTestCase {
    private var directory: URL!
    private var storage: AppearanceStorage!
    private var backgroundURL: URL { directory.appendingPathComponent("appearance/background.png") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardShelfAppearanceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storage = AppearanceStorage(directory: directory)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func generatedImage(width: Int = 48, height: Int = 32, filename: String = "input.png", frames: Int = 1) throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.15, green: 0.55, blue: 0.35, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.9, green: 0.7, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let url = directory.appendingPathComponent(filename)
        let type = frames == 1 ? UTType.png : UTType.gif
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frames, nil))
        for _ in 0..<frames { CGImageDestinationAddImage(destination, image, nil) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func dimensions(_ image: NSImage) throws -> CGSize {
        let bitmap = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        return CGSize(width: bitmap.width, height: bitmap.height)
    }

    func testRoundTripAndRestrictivePermissions() throws {
        XCTAssertNil(try storage.loadBackground())
        let input = try generatedImage()
        let imported = try storage.importBackground(from: input)
        XCTAssertEqual(try dimensions(imported), CGSize(width: 48, height: 32))
        let restarted = AppearanceStorage(directory: directory)
        let loaded = try XCTUnwrap(restarted.loadBackground())
        XCTAssertEqual(try dimensions(loaded), CGSize(width: 48, height: 32))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(backgroundURL as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let fileMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: backgroundURL.path)[.posixPermissions] as? NSNumber)
        let directoryMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: backgroundURL.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(fileMode.intValue & 0o777, 0o600)
        XCTAssertEqual(directoryMode.intValue & 0o777, 0o700)
    }

    func testInvalidInputPreservesPreviousBackground() throws {
        _ = try storage.importBackground(from: generatedImage())
        let previous = try Data(contentsOf: backgroundURL)
        let invalid = directory.appendingPathComponent("invalid.png")
        try Data("not an image".utf8).write(to: invalid)
        XCTAssertThrowsError(try storage.importBackground(from: invalid))
        XCTAssertEqual(try Data(contentsOf: backgroundURL), previous)
        XCTAssertNotNil(try storage.loadBackground())
    }

    func testRemovePersistsAcrossRestartAndIsIdempotent() throws {
        _ = try storage.importBackground(from: generatedImage())
        try storage.removeBackground()
        XCTAssertFalse(FileManager.default.fileExists(atPath: backgroundURL.path))
        XCTAssertNil(try AppearanceStorage(directory: directory).loadBackground())
        XCTAssertNoThrow(try storage.removeBackground())
    }

    func testLargeImageDownsamplesWithoutChangingAspectRatio() throws {
        let imported = try storage.importBackground(from: generatedImage(width: 4400, height: 2200))
        XCTAssertEqual(try dimensions(imported), CGSize(width: 2200, height: 1100))
        let loaded = try XCTUnwrap(storage.loadBackground())
        XCTAssertEqual(try dimensions(loaded), CGSize(width: 2200, height: 1100))
    }

    func testAnimatedInputPersistsOnlyFirstFrameAsPNG() throws {
        _ = try storage.importBackground(from: generatedImage(filename: "animated.gif", frames: 2))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(backgroundURL as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
    }

    func testOversizeFileIsRejectedBeforeDecodeAndPreservesPreviousBackground() throws {
        _ = try storage.importBackground(from: generatedImage())
        let previous = try Data(contentsOf: backgroundURL)
        let oversized = directory.appendingPathComponent("oversize.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: Data()))
        let file = try FileHandle(forWritingTo: oversized)
        try file.truncate(atOffset: 50 * 1024 * 1024 + 1)
        try file.close()
        XCTAssertThrowsError(try storage.importBackground(from: oversized)) { error in
            guard case AppearanceStorageError.inputTooLarge = error else {
                return XCTFail("Expected size rejection, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: backgroundURL), previous)
    }

    func testNonFileURLAndDirectoryAreRejectedWithoutReplacingBackground() throws {
        _ = try storage.importBackground(from: generatedImage())
        let previous = try Data(contentsOf: backgroundURL)
        XCTAssertThrowsError(try storage.importBackground(from: URL(string: "https://example.invalid/background.png")!))
        XCTAssertThrowsError(try storage.importBackground(from: directory))
        XCTAssertEqual(try Data(contentsOf: backgroundURL), previous)
    }
}
