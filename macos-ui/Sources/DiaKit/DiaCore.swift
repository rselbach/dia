import Foundation

public enum DiaError: Error, LocalizedError {
    case io(context: String, underlying: Error)
    case missingCurrentFile
    case emptyPath
    case jsonDecode(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case let .io(context, underlying):
            return "\(context): \(underlying.localizedDescription)"
        case .missingCurrentFile:
            return "no current file is set; use save_as first"
        case .emptyPath:
            return "path must not be empty"
        case let .jsonDecode(underlying):
            return "json error: \(underlying.localizedDescription)"
        }
    }
}

public final class DiaCore {
    // swiftlint:disable:next line_length
    public static let defaultDocumentContent: String = "sequenceDiagram\n    participant Jeff\n    participant Abed\n    participant StarBurns\n    participant Dean\n    participant StudyGroup as Study Group\n\n    Jeff->>Abed: We need chicken fingers\n    Abed->>Abed: Becomes fry cook\n    Note over Abed: Controls the supply\n    \n    Abed->>StarBurns: You handle distribution\n    StarBurns->>StudyGroup: Chicken fingers... for a price\n    StudyGroup->>StarBurns: Bribes & favors\n    StarBurns->>Abed: Reports tribute\n    \n    Jeff->>Abed: I need extra fingers for a date\n    Abed-->>Jeff: You'll wait like everyone else\n    Jeff->>Jeff: What have we created?\n    \n    Dean->>Abed: Why is everyone so happy?\n    Abed-->>Dean: Efficient cafeteria management\n    Dean->>Dean: Something's not right...\n    \n    StudyGroup->>Jeff: This has gone too far\n    Jeff->>Abed: We have to shut it down\n    Abed->>Abed: Destroys the fryer\n    Note over Abed: The empire crumbles"

    private static let defaultDocumentName = "diagram.mmd"
    private static let defaultExportName = "diagram.png"
    private static let defaultMaxRecentFiles = 10

    public private(set) var currentFile: URL?
    public private(set) var dirty: Bool = false
    public private(set) var recentFiles: [URL] = []
    private let maxRecentFiles: Int

    public init(maxRecentFiles: Int = 10) {
        self.maxRecentFiles = max(maxRecentFiles, 1)
    }

    public func openFile(at url: URL) throws -> String {
        let data: String
        do {
            data = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw DiaError.io(context: "failed to read \(url.path)", underlying: error)
        }

        let normalized = url.standardizedFileURL
        currentFile = normalized
        dirty = false
        addRecentFile(normalized)
        return data
    }

    public func newDocument() {
        currentFile = nil
        dirty = false
    }

    public func setDirty(_ value: Bool) {
        dirty = value
    }

    public func currentFileName() -> String? {
        currentFile?.lastPathComponent
    }

    public func displayName() -> String {
        guard let name = currentFileName(), !name.isEmpty else {
            return "Untitled"
        }
        return name
    }

    public func suggestedDocumentName() -> String {
        guard let name = currentFileName(), !name.isEmpty else {
            return Self.defaultDocumentName
        }
        return name
    }

    public func suggestedExportName() -> String {
        guard let stem = currentFile?.deletingPathExtension().lastPathComponent,
              !stem.isEmpty
        else {
            return Self.defaultExportName
        }
        return "\(stem).png"
    }

    public func save(content: String) throws -> URL {
        guard let file = currentFile else {
            throw DiaError.missingCurrentFile
        }
        return try writeFile(to: file, content: content)
    }

    public func saveAs(to url: URL, content: String) throws -> URL {
        try writeFile(to: url.standardizedFileURL, content: content)
    }

    public func recentFilePaths() -> [String] {
        recentFiles.map(\.path)
    }

    public func loadRecentFiles(from url: URL) throws {
        let normalized = url.standardizedFileURL
        let data: Data
        do {
            data = try Data(contentsOf: normalized)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            recentFiles = []
            return
        } catch {
            throw DiaError.io(context: "failed to read \(normalized.path)", underlying: error)
        }

        let parsed: [String]
        do {
            parsed = try JSONDecoder().decode([String].self, from: data)
        } catch {
            throw DiaError.jsonDecode(underlying: error)
        }

        var normalizedList: [URL] = []
        for entry in parsed {
            let candidate = URL(fileURLWithPath: entry).standardizedFileURL
            guard !normalizedList.contains(candidate) else { continue }
            normalizedList.append(candidate)
            if normalizedList.count >= maxRecentFiles { break }
        }

        recentFiles = normalizedList
    }

    public func saveRecentFiles(to url: URL) throws {
        let normalized = url.standardizedFileURL
        let parent = normalized.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw DiaError.io(context: "failed to create directory \(parent.path)", underlying: error)
        }

        let values = recentFiles.map(\.path)
        let encoded: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            encoded = try encoder.encode(values)
        } catch {
            throw DiaError.jsonDecode(underlying: error)
        }

        var output = String(data: encoded, encoding: .utf8) ?? "[]"
        output.append("\n")

        do {
            try output.write(to: normalized, atomically: true, encoding: .utf8)
        } catch {
            throw DiaError.io(context: "failed to write \(normalized.path)", underlying: error)
        }
    }

    public static func ensureDocumentExtension(_ path: String) -> String {
        ensureExtension(path, ext: "mmd")
    }

    public static func ensureExportExtension(_ path: String) -> String {
        ensureExtension(path, ext: "png")
    }

    // MARK: - Private

    private func writeFile(to url: URL, content: String) throws -> URL {
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw DiaError.io(context: "failed to write \(url.path)", underlying: error)
        }

        currentFile = url
        dirty = false
        addRecentFile(url)
        return url
    }

    private func addRecentFile(_ url: URL) {
        var next: [URL] = [url]
        for existing in recentFiles {
            guard existing != url else { continue }
            next.append(existing)
            if next.count >= maxRecentFiles { break }
        }
        recentFiles = next
    }

    private static func ensureExtension(_ path: String, ext: String) -> String {
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension.isEmpty else { return path }
        return url.appendingPathExtension(ext).path
    }
}
