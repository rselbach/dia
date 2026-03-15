import XCTest
@testable import DiaKit

final class DiaCoreTests: XCTestCase {
    private func testDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dia_core_\(name)_\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testOpenAndSaveRoundTripTracksRecentFiles() throws {
        let dir = try testDir("round_trip")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileA = dir.appendingPathComponent("diagram-a.mmd")
        let fileB = dir.appendingPathComponent("diagram-b.mmd")
        try "flowchart TD\nA-->B\n".write(to: fileA, atomically: true, encoding: .utf8)

        let core = DiaCore(maxRecentFiles: 10)
        let opened = try core.openFile(at: fileA)
        XCTAssertEqual(opened, "flowchart TD\nA-->B\n")
        XCTAssertFalse(core.dirty)

        core.setDirty(true)
        XCTAssertTrue(core.dirty)

        _ = try core.saveAs(to: fileB, content: "flowchart TD\nB-->C\n")
        let saved = try String(contentsOf: fileB, encoding: .utf8)
        XCTAssertEqual(saved, "flowchart TD\nB-->C\n")

        let recentPaths = core.recentFilePaths()
        XCTAssertTrue(recentPaths.contains(where: { $0.contains("diagram-b.mmd") }))
        XCTAssertTrue(recentPaths.contains(where: { $0.contains("diagram-a.mmd") }))
    }

    func testPersistRecentFilesRespectsLimitAndDedupes() throws {
        let dir = try testDir("recent")
        defer { try? FileManager.default.removeItem(at: dir) }

        let recentPath = dir.appendingPathComponent("recent-files.json")
        try "[\"./one.mmd\", \"./two.mmd\", \"./one.mmd\", \"./three.mmd\"]"
            .write(to: recentPath, atomically: true, encoding: .utf8)

        let core = DiaCore(maxRecentFiles: 2)
        try core.loadRecentFiles(from: recentPath)
        let loaded = core.recentFilePaths()
        XCTAssertTrue(loaded.contains(where: { $0.contains("one.mmd") }))
        XCTAssertTrue(loaded.contains(where: { $0.contains("two.mmd") }))
        XCTAssertFalse(loaded.contains(where: { $0.contains("three.mmd") }))

        try core.saveRecentFiles(to: recentPath)
        let reloaded = try String(contentsOf: recentPath, encoding: .utf8)
        XCTAssertTrue(reloaded.contains("one.mmd"))
        XCTAssertTrue(reloaded.contains("two.mmd"))
    }

    func testLoadRecentFilesMissingFileReturnsEmpty() throws {
        let dir = try testDir("missing")
        defer { try? FileManager.default.removeItem(at: dir) }

        let missingPath = dir.appendingPathComponent("does-not-exist.json")
        let core = DiaCore(maxRecentFiles: 10)
        try core.loadRecentFiles(from: missingPath)
        XCTAssertTrue(core.recentFiles.isEmpty)
    }

    func testDefaultDocumentHelpers() {
        let core = DiaCore(maxRecentFiles: 10)

        XCTAssertTrue(DiaCore.defaultDocumentContent.hasPrefix("sequenceDiagram"))
        XCTAssertTrue(DiaCore.defaultDocumentContent.contains("chicken fingers"))
        XCTAssertEqual(core.displayName(), "Untitled")
        XCTAssertEqual(core.suggestedDocumentName(), "diagram.mmd")
        XCTAssertEqual(core.suggestedExportName(), "diagram.png")
    }

    func testDisplayNameDerivesFromCurrentFile() throws {
        let dir = try testDir("helper_names")
        defer { try? FileManager.default.removeItem(at: dir) }

        let filePath = dir.appendingPathComponent("greendale-plan.mmd")
        try "flowchart TD\nA-->B\n".write(to: filePath, atomically: true, encoding: .utf8)

        let core = DiaCore(maxRecentFiles: 10)
        _ = try core.openFile(at: filePath)

        XCTAssertEqual(core.displayName(), "greendale-plan.mmd")
        XCTAssertEqual(core.suggestedDocumentName(), "greendale-plan.mmd")
        XCTAssertEqual(core.suggestedExportName(), "greendale-plan.png")
    }

    func testEnsureExtensionHelpers() {
        XCTAssertEqual(
            DiaCore.ensureDocumentExtension("/tmp/senor-chang"),
            "/tmp/senor-chang.mmd"
        )
        XCTAssertEqual(
            DiaCore.ensureDocumentExtension("/tmp/troy.mmd"),
            "/tmp/troy.mmd"
        )
        XCTAssertEqual(
            DiaCore.ensureExportExtension("/tmp/senor-chang"),
            "/tmp/senor-chang.png"
        )
        XCTAssertEqual(
            DiaCore.ensureExportExtension("/tmp/annie.svg"),
            "/tmp/annie.svg"
        )
    }

    func testNewDocumentResetsState() throws {
        let dir = try testDir("new_doc")
        defer { try? FileManager.default.removeItem(at: dir) }

        let filePath = dir.appendingPathComponent("test.mmd")
        try "content".write(to: filePath, atomically: true, encoding: .utf8)

        let core = DiaCore(maxRecentFiles: 10)
        _ = try core.openFile(at: filePath)
        XCTAssertNotNil(core.currentFile)

        core.newDocument()
        XCTAssertNil(core.currentFile)
        XCTAssertFalse(core.dirty)
    }

    func testSaveWithoutCurrentFileThrows() {
        let core = DiaCore(maxRecentFiles: 10)
        XCTAssertThrowsError(try core.save(content: "test")) { error in
            guard let diaError = error as? DiaError else {
                XCTFail("expected DiaError, got \(error)")
                return
            }
            switch diaError {
            case .missingCurrentFile:
                break
            default:
                XCTFail("expected missingCurrentFile, got \(diaError)")
            }
        }
    }

    func testMaxRecentFilesMinimumIsOne() {
        let core = DiaCore(maxRecentFiles: 0)
        XCTAssertEqual(core.displayName(), "Untitled")
    }
}
