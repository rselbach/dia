import AppKit
import Combine
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
    @Published private(set) var previewZoomScale: CGFloat = 1
    @Published var selectedTheme: MermaidTheme = .defaultTheme {
        didSet {
            if preferences.defaultTheme != selectedTheme {
                preferences.defaultTheme = selectedTheme
            }
            schedulePreviewRender()
        }
    }

    let preferences: AppPreferences

    private let core: DiaCoreBridge
    private let recentFilesPath: String

    private var didStartup = false
    private var suppressDirtySignal = false
    private var renderWorkItem: DispatchWorkItem?
    private weak var previewWebView: WKWebView?
    private var cancellables: Set<AnyCancellable> = []

    init(core: DiaCoreBridge = DiaCoreBridge(), preferences: AppPreferences? = nil) {
        self.core = core
        let resolvedPreferences = preferences ?? AppPreferences()
        self.preferences = resolvedPreferences
        source = defaultSource
        let initialTheme = resolvedPreferences.defaultTheme
        selectedTheme = initialTheme
        previewHTML = Self.diagramHTML(for: defaultSource, theme: initialTheme)
        recentFilesPath = Self.makeRecentFilesPath()

        resolvedPreferences.$defaultTheme
            .removeDuplicates()
            .sink { [weak self] theme in
                guard let self, self.selectedTheme != theme else { return }
                self.selectedTheme = theme
            }
            .store(in: &cancellables)
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
        applyPreviewZoom()
    }

    func zoomInPreview() {
        setPreviewZoomScale(previewZoomScale * 1.2)
    }

    func zoomOutPreview() {
        setPreviewZoomScale(previewZoomScale / 1.2)
    }

    func resetPreviewZoom() {
        setPreviewZoomScale(1)
    }

    func updatePreviewZoomScaleFromGesture(_ scale: CGFloat) {
        previewZoomScale = clampedPreviewZoomScale(scale)
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

        snapshotPreviewPNG(from: webView) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }

                let pngData: Data
                switch result {
                case .success(let data):
                    pngData = data
                case .failure(let error):
                    self.setError("export failed: \(error.localizedDescription)")
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
            DispatchQueue.main.async {
                self.applyPreviewZoom()
            }
        }

        renderWorkItem = nextRender
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: nextRender)
    }

    private func clearStatus() {
        statusMessage = ""
    }

    private func snapshotPreviewPNG(from webView: WKWebView, completion: @escaping (Result<Data, Error>) -> Void) {
        webView.takeSnapshot(with: nil) { image, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard let image,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let pngData = bitmap.representation(using: .png, properties: [:])
            else {
                completion(.failure(PreviewExportError.pngEncodingFailed))
                return
            }

            completion(.success(pngData))
        }
    }

    func copyPreviewAsPNG() {
        guard let webView = previewWebView else {
            setError("preview is not ready")
            return
        }

        snapshotPreviewPNG(from: webView) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }

                switch result {
                case .success(let pngData):
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setData(pngData, forType: .png)
                    self.clearStatus()
                case .failure(let error):
                    self.setError("copy failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func copyPreviewAsSVG() {
        guard let webView = previewWebView else {
            setError("preview is not ready")
            return
        }

        let script = "document.querySelector('#diagram svg')?.outerHTML ?? null;"
        webView.evaluateJavaScript(script) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }

                if let error {
                    self.setError("copy failed: \(error.localizedDescription)")
                    return
                }

                guard let svg = result as? String, !svg.isEmpty else {
                    self.setError("copy failed: preview SVG not available")
                    return
                }

                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(svg, forType: .string)
                self.clearStatus()
            }
        }
    }

    private func setPreviewZoomScale(_ scale: CGFloat) {
        previewZoomScale = clampedPreviewZoomScale(scale)
        applyPreviewZoom()
    }

    private func clampedPreviewZoomScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, 0.25), 4)
    }

    private func applyPreviewZoom() {
        previewWebView?.evaluateJavaScript(
            "typeof window.setZoom === 'function' ? window.setZoom(\(previewZoomScale)) : null;"
        ) { [weak self] _, error in
            guard let self, let error else { return }
            self.setError("preview zoom failed: \(error.localizedDescription)")
        }
    }

    private func setError(_ message: String) {
        statusMessage = message
    }

    private enum PreviewExportError: LocalizedError {
        case pngEncodingFailed

        var errorDescription: String? {
            switch self {
            case .pngEncodingFailed:
                "could not encode PNG"
            }
        }
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
                user-select: none;
                -webkit-user-select: none;
              }
              #root {
                height: 100%;
                display: flex;
                align-items: center;
                justify-content: center;
                padding: 24px;
                box-sizing: border-box;
              }
              #diagram {
                width: 100%;
                height: 100%;
                display: flex;
                align-items: center;
                justify-content: center;
                overflow: hidden;
                touch-action: none;
                cursor: grab;
                user-select: none;
                -webkit-user-select: none;
              }
              #diagram.is-panning {
                cursor: grabbing;
              }
              #diagram .pan-inner {
                width: 100%;
                height: 100%;
                display: flex;
                align-items: center;
                justify-content: center;
              }
              #diagram .zoom-inner {
                width: 100%;
                height: 100%;
                display: flex;
                align-items: center;
                justify-content: center;
              }
              #diagram .zoom-inner svg {
                width: 100%;
                height: 100%;
                max-width: 100%;
                max-height: 100%;
                user-select: none;
                -webkit-user-select: none;
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
              const zoomInnerClass = "zoom-inner";
              const panInnerClass = "pan-inner";
              const zoomMin = 0.25;
              const zoomMax = 4;
              let zoomLevel = 1;
              let panX = 0;
              let panY = 0;

              function hasRenderedSVG() {
                return diagramEl.querySelector("svg") !== null;
              }

              function applyPan() {
                const panInner = diagramEl.querySelector(`.${panInnerClass}`);
                if (!panInner) return;
                panInner.style.transform = `translate(${panX}px, ${panY}px)`;
              }

              function panBounds(level) {
                const zoom = Number.isFinite(level) ? level : zoomLevel;
                const width = diagramEl ? diagramEl.clientWidth : 0;
                const height = diagramEl ? diagramEl.clientHeight : 0;
                const maxX = Math.max(0, ((width * zoom) - width) / 2);
                const maxY = Math.max(0, ((height * zoom) - height) / 2);
                return { maxX, maxY };
              }

              function clampPan(x, y, level) {
                const bounds = panBounds(level);
                return {
                  x: Math.max(-bounds.maxX, Math.min(bounds.maxX, x)),
                  y: Math.max(-bounds.maxY, Math.min(bounds.maxY, y)),
                };
              }

              window.setPan = function(x, y) {
                const clamped = clampPan(x, y, zoomLevel);
                panX = clamped.x;
                panY = clamped.y;
                applyPan();
                return { x: panX, y: panY };
              };

              function notifyZoomChanged() {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.zoomChanged) {
                  window.webkit.messageHandlers.zoomChanged.postMessage(zoomLevel);
                }
              }

              function applyZoom() {
                const zoomInner = diagramEl.querySelector(`.${zoomInnerClass}`);
                if (!zoomInner) return;
                zoomInner.style.transform = `scale(${zoomLevel})`;
                zoomInner.style.transformOrigin = "center center";
                notifyZoomChanged();
              }

              window.setZoom = function(level) {
                const newZoom = Math.min(zoomMax, Math.max(zoomMin, level));
                const clamped = clampPan(panX, panY, newZoom);
                panX = clamped.x;
                panY = clamped.y;
                zoomLevel = newZoom;
                applyPan();
                applyZoom();
                return zoomLevel;
              };

              window.zoomIn = function() {
                return window.setZoom(Math.round((zoomLevel + 0.1) * 100) / 100);
              };

              window.zoomOut = function() {
                return window.setZoom(Math.round((zoomLevel - 0.1) * 100) / 100);
              };

              window.resetZoom = function() {
                return window.setZoom(1);
              };

              function bindInteractions() {
                if (diagramEl.dataset.interactionsBound === "1") return;
                diagramEl.dataset.interactionsBound = "1";

                let isPanning = false;
                let activePointerId = null;
                let lastX = 0;
                let lastY = 0;
                let gestureStartZoom = 1;

                diagramEl.addEventListener("pointerdown", (event) => {
                  if (event.button !== 0 || !hasRenderedSVG() || zoomLevel <= 1) return;
                  isPanning = true;
                  activePointerId = event.pointerId;
                  lastX = event.clientX;
                  lastY = event.clientY;
                  diagramEl.classList.add("is-panning");
                  diagramEl.setPointerCapture(event.pointerId);
                  event.preventDefault();
                });

                diagramEl.addEventListener("pointermove", (event) => {
                  if (!isPanning || event.pointerId !== activePointerId) return;
                  const dx = event.clientX - lastX;
                  const dy = event.clientY - lastY;
                  lastX = event.clientX;
                  lastY = event.clientY;
                  window.setPan(panX + dx, panY + dy);
                  event.preventDefault();
                });

                function stopPanning(event) {
                  if (!isPanning) return;
                  if (activePointerId !== null && event.pointerId !== activePointerId) return;
                  isPanning = false;
                  activePointerId = null;
                  diagramEl.classList.remove("is-panning");
                }

                diagramEl.addEventListener("pointerup", stopPanning);
                diagramEl.addEventListener("pointercancel", stopPanning);
                diagramEl.addEventListener("lostpointercapture", stopPanning);

                diagramEl.addEventListener("wheel", (event) => {
                  if (!hasRenderedSVG()) return;
                  event.preventDefault();
                  const delta = event.deltaY === 0 ? event.deltaX : event.deltaY;
                  if (delta === 0) return;
                  const scaleFactor = Math.exp(-delta * 0.002);
                  window.setZoom(zoomLevel * scaleFactor);
                }, { passive: false });

                document.addEventListener("gesturestart", (event) => {
                  gestureStartZoom = zoomLevel;
                  event.preventDefault();
                }, { passive: false });

                document.addEventListener("gesturechange", (event) => {
                  event.preventDefault();
                  window.setZoom(gestureStartZoom * event.scale);
                }, { passive: false });
              }

              bindInteractions();

              if (typeof mermaid === "undefined") {
                errorEl.textContent = "failed to load Mermaid from CDN";
              } else {
                mermaid.initialize(\(theme.mermaidConfigJS));
                if (!source.trim()) {
                  diagramEl.innerHTML = "";
                  panX = 0;
                  panY = 0;
                  errorEl.textContent = "";
                } else {
                  mermaid.render("dia-preview", source)
                    .then((result) => {
                      diagramEl.innerHTML = `<div class="${panInnerClass}"><div class="${zoomInnerClass}">${result.svg}</div></div>`;
                      const svg = diagramEl.querySelector(`.${zoomInnerClass} svg`);
                      if (svg) {
                        const padding = 16;
                        const bbox = svg.getBBox();
                        if (bbox.width > 0 && bbox.height > 0) {
                          const minX = bbox.x - padding;
                          const minY = bbox.y - padding;
                          const width = bbox.width + (padding * 2);
                          const height = bbox.height + (padding * 2);
                          svg.setAttribute("viewBox", `${minX} ${minY} ${width} ${height}`);
                        }

                        svg.setAttribute("width", "100%");
                        svg.setAttribute("height", "100%");
                        svg.setAttribute("preserveAspectRatio", "xMidYMid meet");
                        svg.style.display = "block";
                        svg.style.maxWidth = "100%";
                        svg.style.maxHeight = "100%";
                      }
                      window.setPan(panX, panY);
                      applyZoom();
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
