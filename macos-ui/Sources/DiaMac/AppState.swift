import AppKit
import Foundation
import UniformTypeIdentifiers
import WebKit

private let defaultSource = """
flowchart TD
    A[Start] --> B{Is it working?}
    B -->|Yes| C[Great!]
    B -->|No| D[Debug]
    D --> B
"""

// MARK: - Mermaid Themes
//
//  All 11 themes from the Wails frontend, including 4 built-in Mermaid
//  themes and 7 custom themes that use Mermaid's "base" theme engine
//  with custom themeVariables.

enum MermaidTheme: String, CaseIterable, Identifiable {
    case defaultTheme = "default"
    case dark
    case forest
    case neutral
    case catppuccin
    case dracula
    case nord
    case synthwave
    case rose
    case ocean
    case solarized

    var id: String { rawValue }

    var label: String {
        switch self {
        case .defaultTheme: return "Default"
        case .dark: return "Dark"
        case .forest: return "Forest"
        case .neutral: return "Neutral"
        case .catppuccin: return "Catppuccin"
        case .dracula: return "Dracula"
        case .nord: return "Nord"
        case .synthwave: return "Synthwave"
        case .rose: return "Rose"
        case .ocean: return "Ocean"
        case .solarized: return "Solarized"
        }
    }

    var previewBackground: String {
        switch self {
        case .defaultTheme: return "#ffffff"
        case .dark: return "#333333"
        case .forest: return "#ffffff"
        case .neutral: return "#ffffff"
        case .catppuccin: return "#1e1e2e"
        case .dracula: return "#282a36"
        case .nord: return "#eceff4"
        case .synthwave: return "#1a1a2e"
        case .rose: return "#fff1f2"
        case .ocean: return "#eaf8ff"
        case .solarized: return "#fdf6e3"
        }
    }

    /// For custom themes, the error text needs to contrast with the
    /// preview background. Dark backgrounds get a light red,
    /// light backgrounds get a dark red.
    var errorColor: String {
        switch self {
        case .dark, .catppuccin, .dracula, .synthwave:
            return "#f38ba8"
        default:
            return "#b91c1c"
        }
    }

    /// Custom themes use Mermaid's "base" theme with variable overrides.
    /// Built-in themes return nil (they use the theme name directly).
    var themeVariables: [String: String]? {
        switch self {
        case .defaultTheme, .dark, .forest, .neutral:
            return nil
        case .catppuccin:
            return [
                "primaryColor": "#89b4fa", "primaryBorderColor": "#74c7ec",
                "secondaryColor": "#cba6f7", "secondaryBorderColor": "#b4befe",
                "tertiaryColor": "#a6e3a1", "tertiaryBorderColor": "#94e2d5",
                "lineColor": "#bac2de", "textColor": "#cdd6f4",
            ]
        case .dracula:
            return [
                "primaryColor": "#bd93f9", "primaryBorderColor": "#6272a4",
                "secondaryColor": "#ff79c6", "secondaryBorderColor": "#ff79c6",
                "tertiaryColor": "#50fa7b", "tertiaryBorderColor": "#50fa7b",
                "lineColor": "#f8f8f2", "textColor": "#f8f8f2",
            ]
        case .nord:
            return [
                "primaryColor": "#5e81ac", "primaryBorderColor": "#4c566a",
                "secondaryColor": "#a3be8c", "secondaryBorderColor": "#4c566a",
                "tertiaryColor": "#d08770", "tertiaryBorderColor": "#4c566a",
                "lineColor": "#4c566a", "textColor": "#2e3440",
            ]
        case .synthwave:
            return [
                "primaryColor": "#f72585", "primaryBorderColor": "#ff6ec7",
                "secondaryColor": "#7209b7", "secondaryBorderColor": "#b5179e",
                "tertiaryColor": "#4361ee", "tertiaryBorderColor": "#4cc9f0",
                "lineColor": "#ff6ec7", "textColor": "#f0e6ff",
            ]
        case .rose:
            return [
                "primaryColor": "#e11d48", "primaryBorderColor": "#be123c",
                "secondaryColor": "#fb7185", "secondaryBorderColor": "#f43f5e",
                "tertiaryColor": "#fda4af", "tertiaryBorderColor": "#fb7185",
                "lineColor": "#881337", "textColor": "#4c0519",
            ]
        case .ocean:
            return [
                "primaryColor": "#0077b6", "primaryBorderColor": "#023e8a",
                "secondaryColor": "#00b4d8", "secondaryBorderColor": "#0096c7",
                "tertiaryColor": "#48cae4", "tertiaryBorderColor": "#0096c7",
                "lineColor": "#03045e", "textColor": "#03045e",
            ]
        case .solarized:
            return [
                "primaryColor": "#268bd2", "primaryBorderColor": "#2aa198",
                "secondaryColor": "#859900", "secondaryBorderColor": "#859900",
                "tertiaryColor": "#b58900", "tertiaryBorderColor": "#cb4b16",
                "lineColor": "#586e75", "textColor": "#657b83",
            ]
        }
    }

    /// Generates the JavaScript object literal passed to mermaid.initialize().
    var mermaidConfigJS: String {
        var parts = [
            "startOnLoad: false",
            "securityLevel: \"strict\"",
        ]

        if let variables = themeVariables {
            parts.append("theme: \"base\"")
            let varParts = variables.sorted(by: { $0.key < $1.key })
                .map { "\($0.key): \"\($0.value)\"" }
            parts.append("themeVariables: { \(varParts.joined(separator: ", ")) }")
        } else {
            parts.append("theme: \"\(rawValue)\"")
        }

        return "{ \(parts.joined(separator: ", ")) }"
    }
}

// MARK: - Application State

@MainActor
final class AppState: ObservableObject {
    @Published var source: String {
        didSet {
            guard !suppressDirtySignal else { return }

            do {
                try core.setDirty(true)
            } catch {
                setError("failed to mark document dirty: \(error.localizedDescription)")
            }

            updateWindowTitle()
            schedulePreviewRender()
        }
    }

    @Published private(set) var previewHTML: String
    @Published private(set) var statusMessage: String = ""
    @Published private(set) var recentFiles: [String] = []
    @Published var selectedTheme: MermaidTheme = .defaultTheme {
        didSet {
            schedulePreviewRender()
        }
    }

    private let core: DiaCoreBridge
    private let recentFilesPath: String

    private var didStartup = false
    private var suppressDirtySignal = false
    private var renderWorkItem: DispatchWorkItem?
    private weak var previewWebView: WKWebView?

    init(core: DiaCoreBridge = DiaCoreBridge()) {
        self.core = core
        source = defaultSource
        previewHTML = Self.diagramHTML(for: defaultSource, theme: .defaultTheme)
        recentFilesPath = Self.makeRecentFilesPath()
    }

    // MARK: Lifecycle

    func startup() {
        guard !didStartup else { return }
        didStartup = true

        do {
            try core.loadRecentFiles(path: recentFilesPath)
            recentFiles = try core.recentFiles()
        } catch {
            setError("failed to load recent files: \(error.localizedDescription)")
        }

        schedulePreviewRender()
        updateWindowTitle()
    }

    func attachPreview(_ webView: WKWebView) {
        previewWebView = webView
    }

    // MARK: Document Operations

    func newDocument() {
        guard confirmDiscardIfNeeded() else { return }

        do {
            try core.newDocument()
        } catch {
            setError("new document failed: \(error.localizedDescription)")
            return
        }

        setLoadedSource(defaultSource)
        clearStatus()
        updateWindowTitle()
    }

    func openDocument() {
        guard confirmDiscardIfNeeded() else { return }

        let panel = NSOpenPanel()
        panel.title = "Open Mermaid Diagram"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "mmd"),
            UTType(filenameExtension: "mermaid"),
        ].compactMap { $0 }

        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        openDocument(path: path)
    }

    func openRecent(path: String) {
        guard confirmDiscardIfNeeded() else { return }
        openDocument(path: path)
    }

    func saveDocument() {
        _ = saveDocumentInternal(showStatusOnSuccess: true)
    }

    func saveDocumentAs() {
        _ = saveDocumentAsInternal(showStatusOnSuccess: true)
    }

    func exportPNG() {
        guard let webView = previewWebView else {
            setError("preview is not ready")
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export PNG"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedExportName()
        panel.allowedContentTypes = [UTType.png]

        guard panel.runModal() == .OK, var destination = panel.url else { return }

        if destination.pathExtension.lowercased() != "png" {
            destination.appendPathExtension("png")
        }

        webView.takeSnapshot(with: nil) { [weak self] image, error in
            DispatchQueue.main.async {
                guard let self else { return }

                if let error {
                    self.setError("export failed: \(error.localizedDescription)")
                    return
                }

                guard let image,
                      let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let pngData = bitmap.representation(using: .png, properties: [:])
                else {
                    self.setError("export failed: could not encode PNG")
                    return
                }

                do {
                    try pngData.write(to: destination, options: .atomic)
                    self.clearStatus()
                } catch {
                    self.setError("export failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func confirmBeforeQuit() -> Bool {
        guard core.isDirty() else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unsaved Changes"
        alert.informativeText = "You have unsaved changes. Save before quitting?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveDocumentInternal(showStatusOnSuccess: false)
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    // MARK: Status

    func dismissStatus() {
        statusMessage = ""
    }

    // MARK: - Private

    private func openDocument(path: String) {
        do {
            let content = try core.openFile(path: path)
            setLoadedSource(content)
            try persistAndReloadRecentFiles()
            clearStatus()
            updateWindowTitle()
        } catch {
            setError("open failed: \(error.localizedDescription)")
        }
    }

    private func saveDocumentInternal(showStatusOnSuccess: Bool) -> Bool {
        do {
            if try core.currentFile() == nil {
                return saveDocumentAsInternal(showStatusOnSuccess: showStatusOnSuccess)
            }

            _ = try core.save(content: source)
            try persistAndReloadRecentFiles()
            if showStatusOnSuccess { clearStatus() }
            updateWindowTitle()
            return true
        } catch {
            setError("save failed: \(error.localizedDescription)")
            return false
        }
    }

    private func saveDocumentAsInternal(showStatusOnSuccess: Bool) -> Bool {
        let panel = NSSavePanel()
        panel.title = "Save Mermaid Diagram"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedDocumentName()
        panel.allowedContentTypes = [UTType(filenameExtension: "mmd")].compactMap { $0 }

        guard panel.runModal() == .OK, var destination = panel.url else { return false }

        if destination.pathExtension.isEmpty {
            destination.appendPathExtension("mmd")
        }

        do {
            _ = try core.saveAs(path: destination.path, content: source)
            try persistAndReloadRecentFiles()
            if showStatusOnSuccess { clearStatus() }
            updateWindowTitle()
            return true
        } catch {
            setError("save as failed: \(error.localizedDescription)")
            return false
        }
    }

    private func setLoadedSource(_ content: String) {
        suppressDirtySignal = true
        source = content
        suppressDirtySignal = false
        schedulePreviewRender()
    }

    private func persistAndReloadRecentFiles() throws {
        try core.saveRecentFiles(path: recentFilesPath)
        recentFiles = try core.recentFiles()
    }

    private func confirmDiscardIfNeeded() -> Bool {
        guard core.isDirty() else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard Unsaved Changes?"
        alert.informativeText = "Your current changes will be lost."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func suggestedDocumentName() -> String {
        if let currentPath = try? core.currentFile() {
            let name = URL(fileURLWithPath: currentPath).lastPathComponent
            if !name.isEmpty { return name }
        }
        return "diagram.mmd"
    }

    private func suggestedExportName() -> String {
        if let currentPath = try? core.currentFile() {
            let url = URL(fileURLWithPath: currentPath)
            let stem = url.deletingPathExtension().lastPathComponent
            if !stem.isEmpty { return "\(stem).png" }
        }
        return "diagram.png"
    }

    private func updateWindowTitle() {
        let name: String
        if let currentPath = try? core.currentFile() {
            name = URL(fileURLWithPath: currentPath).lastPathComponent
        } else {
            name = "Untitled"
        }

        let isDirty = core.isDirty()

        DispatchQueue.main.async {
            for window in NSApplication.shared.windows {
                window.title = name
                window.subtitle = "dia"
                window.isDocumentEdited = isDirty
            }
        }
    }

    private func schedulePreviewRender() {
        renderWorkItem?.cancel()

        let source = source
        let theme = selectedTheme
        let nextRender = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.previewHTML = Self.diagramHTML(for: source, theme: theme)
        }

        renderWorkItem = nextRender
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: nextRender)
    }

    private func clearStatus() {
        statusMessage = ""
    }

    private func setError(_ message: String) {
        statusMessage = message
    }

    private static func makeRecentFilesPath() -> String {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return baseDirectory.appendingPathComponent("dia/recent-files.json").path
    }

    // MARK: - HTML Generation

    static func diagramHTML(for source: String, theme: MermaidTheme) -> String {
        let sourceJSON = jsonStringLiteral(source)
        return """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1" />
            <style>
              html, body {
                margin: 0;
                height: 100%;
                background: \(theme.previewBackground);
                font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
              }
              #root {
                height: 100%;
                display: flex;
                align-items: center;
                justify-content: center;
                padding: 24px;
                box-sizing: border-box;
              }
              #diagram svg {
                width: 100%;
                height: auto;
                max-height: calc(100vh - 48px);
              }
              #error {
                color: \(theme.errorColor);
                white-space: pre-wrap;
                font-family: Menlo, Monaco, monospace;
                font-size: 13px;
              }
            </style>
            <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
          </head>
          <body>
            <div id="root">
              <div id="diagram"></div>
              <pre id="error"></pre>
            </div>
            <script>
              const source = \(sourceJSON);
              const diagramEl = document.getElementById("diagram");
              const errorEl = document.getElementById("error");

              if (typeof mermaid === "undefined") {
                errorEl.textContent = "failed to load Mermaid from CDN";
              } else {
                mermaid.initialize(\(theme.mermaidConfigJS));
                if (!source.trim()) {
                  diagramEl.innerHTML = "";
                  errorEl.textContent = "";
                } else {
                  mermaid.render("dia-preview", source)
                    .then((result) => {
                      diagramEl.innerHTML = result.svg;
                      errorEl.textContent = "";
                    })
                    .catch((error) => {
                      diagramEl.innerHTML = "";
                      errorEl.textContent = String(error);
                    });
                }
              }
            </script>
          </body>
        </html>
        """
    }

    private static func jsonStringLiteral(_ value: String) -> String {
        guard let encoded = try? JSONEncoder().encode(value),
              let text = String(data: encoded, encoding: .utf8)
        else {
            return "\"\""
        }
        return text
    }
}
