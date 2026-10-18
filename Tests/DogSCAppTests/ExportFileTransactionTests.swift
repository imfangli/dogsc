import Foundation
import XCTest
@testable import DogSCApp

final class ExportFileTransactionTests: XCTestCase {
    func testPublishesNewVideoAndSubtitleFiles() throws {
        try withFolder { folder in
            let outputs = try makeOutputs(in: folder)
            try ExportFileTransaction.promote(outputs)
            XCTAssertEqual(try contents(outputs[0].finalURL), "new video")
            XCTAssertEqual(try contents(outputs[1].finalURL), "new subtitles")
            XCTAssertTrue(outputs.allSatisfy { !FileManager.default.fileExists(atPath: $0.temporaryURL.path) })
            XCTAssertEqual(try names(in: folder), ["movie.mp4", "movie.srt"])
        }
    }

    func testReplacesExistingPairAndRemovesBackups() throws {
        try withFolder { folder in
            let outputs = try makeOutputs(in: folder)
            try "old video".write(to: outputs[0].finalURL, atomically: true, encoding: .utf8)
            try "old subtitles".write(to: outputs[1].finalURL, atomically: true, encoding: .utf8)
            try ExportFileTransaction.promote(outputs)
            XCTAssertEqual(try contents(outputs[0].finalURL), "new video")
            XCTAssertEqual(try contents(outputs[1].finalURL), "new subtitles")
            XCTAssertEqual(try names(in: folder), ["movie.mp4", "movie.srt"])
        }
    }

    func testFailedSecondPublicationRestoresExistingVideoAndSubtitle() throws {
        try withFolder { folder in
            let outputs = try makeOutputs(in: folder)
            try "old video".write(to: outputs[0].finalURL, atomically: true, encoding: .utf8)
            try "old subtitles".write(to: outputs[1].finalURL, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: outputs[1].temporaryURL)
            XCTAssertThrowsError(try ExportFileTransaction.promote(outputs))
            XCTAssertEqual(try contents(outputs[0].finalURL), "old video")
            XCTAssertEqual(try contents(outputs[1].finalURL), "old subtitles")
            XCTAssertEqual(try names(in: folder), ["movie.mp4", "movie.srt"])
        }
    }

    func testFailedSecondPublicationRemovesNewVideoAndPreservesOldSubtitle() throws {
        try withFolder { folder in
            let outputs = try makeOutputs(in: folder)
            try "old subtitles".write(to: outputs[1].finalURL, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: outputs[1].temporaryURL)
            XCTAssertThrowsError(try ExportFileTransaction.promote(outputs))
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputs[0].finalURL.path))
            XCTAssertEqual(try contents(outputs[1].finalURL), "old subtitles")
            XCTAssertEqual(try names(in: folder), ["movie.srt"])
        }
    }

    func testDirectoryDestinationIsRejectedBeforeChangingEitherOutput() throws {
        try withFolder { folder in
            let outputs = try makeOutputs(in: folder)
            try "old video".write(to: outputs[0].finalURL, atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(at: outputs[1].finalURL, withIntermediateDirectories: false)
            let marker = outputs[1].finalURL.appendingPathComponent("keep.txt")
            try "keep directory".write(to: marker, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try ExportFileTransaction.promote(outputs))
            XCTAssertEqual(try contents(outputs[0].finalURL), "old video")
            XCTAssertEqual(try contents(marker), "keep directory")
            XCTAssertTrue(outputs.allSatisfy { FileManager.default.fileExists(atPath: $0.temporaryURL.path) })
            XCTAssertFalse(try names(in: folder).contains { $0.contains("dogsc-export-backup") })
        }
    }

    func testDuplicateAliasesAreRejectedBeforePublishing() throws {
        try withFolder { folder in
            let outputs = try makeOutputs(in: folder)
            let alias = folder.appendingPathComponent("folder/../movie.mp4")
            let conflicting = [outputs[0], ExportFileTransaction.Output(
                temporaryURL: outputs[1].temporaryURL, finalURL: alias)]
            XCTAssertThrowsError(try ExportFileTransaction.promote(conflicting))
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputs[0].finalURL.path))
            XCTAssertTrue(outputs.allSatisfy { FileManager.default.fileExists(atPath: $0.temporaryURL.path) })
        }
    }

    func testSingleOutputPromotionRemainsCompatible() throws {
        try withFolder { folder in
            let outputs = try makeOutputs(in: folder)
            try "old video".write(to: outputs[0].finalURL, atomically: true, encoding: .utf8)
            try ExportFileTransaction.promote(temporaryURL: outputs[0].temporaryURL, to: outputs[0].finalURL)
            XCTAssertEqual(try contents(outputs[0].finalURL), "new video")
            XCTAssertFalse(try names(in: folder).contains { $0.contains("dogsc-export-backup") })
        }
    }

    private func makeOutputs(in folder: URL) throws -> [ExportFileTransaction.Output] {
        try [("mp4", "new video"), ("srt", "new subtitles")].map { ext, text in
            let final = folder.appendingPathComponent("movie." + ext)
            let temporary = ExportFileTransaction.makeTemporaryURL(for: final)
            try text.write(to: temporary, atomically: true, encoding: .utf8)
            return ExportFileTransaction.Output(temporaryURL: temporary, finalURL: final)
        }
    }

    private func contents(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private func withFolder(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "DogSC-Export-Transaction-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }
}
