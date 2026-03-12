import Foundation
import DiaCoreFFI

enum DiaCoreBridgeError: Error, LocalizedError {
    case unavailable
    case runtime(String)
    case invalidRecentFiles(String)
    case invalidThemeCatalog(String)
    case invalidHighlightSpans(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "dia_core handle is unavailable"
        case let .runtime(message):
            return message
        case let .invalidRecentFiles(message):
            return "invalid recent-files payload: \(message)"
        case let .invalidThemeCatalog(message):
            return "invalid theme catalog payload: \(message)"
        case let .invalidHighlightSpans(message):
            return "invalid highlight spans payload: \(message)"
        }
    }
}

struct MermaidThemeInfo: Decodable, Identifiable, Hashable {
    let id: String
    let label: String
    let previewBackground: String
    let errorColor: String
}

struct MermaidHighlightSpan: Decodable {
    let start: Int
    let end: Int
    let kind: String
}

final class DiaCoreBridge {
    private var handle: OpaquePointer?

    init(maxRecentFiles: UInt32 = 10) {
        handle = dia_core_new(maxRecentFiles)
    }

    deinit {
        dia_core_free(handle)
    }

    func openFile(path: String) throws -> String {
        try path.withCString { cPath in
            guard let handle else {
                throw DiaCoreBridgeError.unavailable
            }
            return try stringResult(from: dia_core_open_file(handle, cPath))
        }
    }

    func newDocument() throws {
        guard let handle else {
            throw DiaCoreBridgeError.unavailable
        }
        _ = try stringResult(from: dia_core_new_document(handle))
    }

    func save(content: String) throws -> String {
        try content.withCString { cContent in
            guard let handle else {
                throw DiaCoreBridgeError.unavailable
            }
            return try stringResult(from: dia_core_save(handle, cContent))
        }
    }

    func saveAs(path: String, content: String) throws -> String {
        try path.withCString { cPath in
            try content.withCString { cContent in
                guard let handle else {
                    throw DiaCoreBridgeError.unavailable
                }
                return try stringResult(from: dia_core_save_as(handle, cPath, cContent))
            }
        }
    }

    func setDirty(_ dirty: Bool) throws {
        guard let handle else {
            throw DiaCoreBridgeError.unavailable
        }
        _ = try stringResult(from: dia_core_set_dirty(handle, dirty ? 1 : 0))
    }

    func isDirty() -> Bool {
        guard let handle else {
            return false
        }
        return dia_core_is_dirty(handle) == 1
    }

    func currentFile() throws -> String? {
        guard let handle else {
            throw DiaCoreBridgeError.unavailable
        }
        let value = try stringResult(from: dia_core_current_file(handle))
        return value.isEmpty ? nil : value
    }

    func displayName() throws -> String {
        guard let handle else {
            throw DiaCoreBridgeError.unavailable
        }
        return try stringResult(from: dia_core_display_name(handle))
    }

    func suggestedDocumentName() throws -> String {
        guard let handle else {
            throw DiaCoreBridgeError.unavailable
        }
        return try stringResult(from: dia_core_suggested_document_name(handle))
    }

    func suggestedExportName() throws -> String {
        guard let handle else {
            throw DiaCoreBridgeError.unavailable
        }
        return try stringResult(from: dia_core_suggested_export_name(handle))
    }

    func defaultDocumentContent() throws -> String {
        try stringResult(from: dia_core_default_document_content())
    }

    func defaultThemeID() throws -> String {
        try stringResult(from: dia_core_default_theme_id())
    }

    func mermaidThemeCatalog() throws -> [MermaidThemeInfo] {
        let payload = try stringResult(from: dia_core_mermaid_theme_catalog_json())
        guard let data = payload.data(using: .utf8) else {
            throw DiaCoreBridgeError.invalidThemeCatalog("expected UTF-8 JSON")
        }

        do {
            return try JSONDecoder().decode([MermaidThemeInfo].self, from: data)
        } catch {
            throw DiaCoreBridgeError.invalidThemeCatalog(error.localizedDescription)
        }
    }

    func normalizeThemeID(_ themeID: String) throws -> String {
        try themeID.withCString { cThemeID in
            try stringResult(from: dia_core_normalize_theme_id(cThemeID))
        }
    }

    func mermaidConfigJS(themeID: String) throws -> String {
        try themeID.withCString { cThemeID in
            try stringResult(from: dia_core_mermaid_config_js(cThemeID))
        }
    }

    func mermaidHighlightSpans(source: String) throws -> [MermaidHighlightSpan] {
        let payload = try source.withCString { cSource in
            try stringResult(from: dia_core_mermaid_highlight_spans_json(cSource))
        }

        guard let data = payload.data(using: .utf8) else {
            throw DiaCoreBridgeError.invalidHighlightSpans("expected UTF-8 JSON")
        }

        do {
            return try JSONDecoder().decode([MermaidHighlightSpan].self, from: data)
        } catch {
            throw DiaCoreBridgeError.invalidHighlightSpans(error.localizedDescription)
        }
    }

    func autoIndentInsertion(prefix: String) throws -> String {
        try prefix.withCString { cPrefix in
            try stringResult(from: dia_core_auto_indent_insertion(cPrefix))
        }
    }

    func ensureDocumentExtension(path: String) throws -> String {
        try path.withCString { cPath in
            try stringResult(from: dia_core_ensure_document_extension(cPath))
        }
    }

    func ensureExportExtension(path: String) throws -> String {
        try path.withCString { cPath in
            try stringResult(from: dia_core_ensure_export_extension(cPath))
        }
    }

    func recentFiles() throws -> [String] {
        guard let handle else {
            throw DiaCoreBridgeError.unavailable
        }

        let payload = try stringResult(from: dia_core_recent_files_json(handle))
        guard let data = payload.data(using: .utf8) else {
            throw DiaCoreBridgeError.invalidRecentFiles("expected UTF-8 JSON")
        }

        do {
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            throw DiaCoreBridgeError.invalidRecentFiles(error.localizedDescription)
        }
    }

    func loadRecentFiles(path: String) throws {
        try path.withCString { cPath in
            guard let handle else {
                throw DiaCoreBridgeError.unavailable
            }
            _ = try stringResult(from: dia_core_load_recent_files(handle, cPath))
        }
    }

    func saveRecentFiles(path: String) throws {
        try path.withCString { cPath in
            guard let handle else {
                throw DiaCoreBridgeError.unavailable
            }
            _ = try stringResult(from: dia_core_save_recent_files(handle, cPath))
        }
    }

    private func stringResult(from result: DiaResult) throws -> String {
        let result = result
        defer {
            if let value = result.value {
                dia_string_free(value)
            }
            if let error = result.error {
                dia_string_free(error)
            }
        }

        if result.code != DIA_RESULT_OK {
            let message = result.error.map { String(cString: $0) } ?? "unknown dia_core error"
            throw DiaCoreBridgeError.runtime(message)
        }

        guard let value = result.value else {
            return ""
        }
        return String(cString: value)
    }
}
