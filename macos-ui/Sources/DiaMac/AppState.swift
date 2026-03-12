import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import WebKit

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
    @Published var selectedThemeID: String = "default" {
        didSet {
            let normalizedID = normalizedThemeID(selectedThemeID)
            if normalizedID != selectedThemeID {
                selectedThemeID = normalizedID
                return
            }

            if preferences.defaultThemeID != selectedThemeID {
                preferences.defaultThemeID = selectedThemeID
            }
            schedulePreviewRender()
        }
    }

    let preferences: AppPreferences
    let themes: [MermaidThemeInfo]

    private let core: DiaCoreBridge
    private let recentFilesPath: String

    private var didStartup = false
    private var suppressDirtySignal = false
    private var renderWorkItem: DispatchWorkItem?
    private weak var previewWebView: WKWebView?
    private var cancellables: Set<AnyCancellable> = []
    private let defaultSource: String

    init(core: DiaCoreBridge = DiaCoreBridge(), preferences: AppPreferences? = nil) {
        self.core = core
        let resolvedPreferences = preferences ?? AppPreferences()
        self.preferences = resolvedPreferences
        themes = (try? core.mermaidThemeCatalog()) ?? []
        defaultSource = (try? core.defaultDocumentContent()) ?? ""
        source = defaultSource
        let initialThemeID = (try? core.normalizeThemeID(resolvedPreferences.defaultThemeID)) ?? "default"
        selectedThemeID = initialThemeID
        previewHTML = Self.diagramHTML(
            for: defaultSource,
            theme: themes.first(where: { $0.id == initialThemeID })
                ?? MermaidThemeInfo(id: "default", label: "Default", previewBackground: "#ffffff", errorColor: "#b91c1c"),
            mermaidConfigJS: (try? core.mermaidConfigJS(themeID: initialThemeID))
                ?? "{ startOnLoad: false, securityLevel: \"strict\", theme: \"default\" }"
        )
        recentFilesPath = Self.makeRecentFilesPath()

        resolvedPreferences.$defaultThemeID
            .removeDuplicates()
            .sink { [weak self] themeID in
                guard let self else { return }
                let normalizedThemeID = self.normalizedThemeID(themeID)
                guard self.selectedThemeID != normalizedThemeID else { return }
                self.selectedThemeID = normalizedThemeID
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

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let finalDestination = URL(fileURLWithPath: ensuredExportPath(for: destination.path))

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
                    try pngData.write(to: finalDestination, options: .atomic)
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

        guard panel.runModal() == .OK, let destination = panel.url else { return false }

        let finalDestination = ensuredDocumentPath(for: destination.path)

        do {
            _ = try core.saveAs(path: finalDestination, content: source)
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
        (try? core.suggestedDocumentName()) ?? "diagram.mmd"
    }

    private func suggestedExportName() -> String {
        (try? core.suggestedExportName()) ?? "diagram.png"
    }

    private func updateWindowTitle() {
        let name = (try? core.displayName()) ?? "Untitled"

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
        let themeID = selectedThemeID
        let mermaidConfigJS = mermaidConfigJS(for: themeID)
        let theme = themeInfo(for: themeID)
        let nextRender = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.previewHTML = Self.diagramHTML(for: source, theme: theme, mermaidConfigJS: mermaidConfigJS)
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

    private func ensuredDocumentPath(for path: String) -> String {
        (try? core.ensureDocumentExtension(path: path)) ?? path
    }

    private func ensuredExportPath(for path: String) -> String {
        (try? core.ensureExportExtension(path: path)) ?? path
    }

    private func normalizedThemeID(_ themeID: String) -> String {
        (try? core.normalizeThemeID(themeID)) ?? "default"
    }

    private func mermaidConfigJS(for themeID: String) -> String {
        (try? core.mermaidConfigJS(themeID: themeID))
            ?? "{ startOnLoad: false, securityLevel: \"strict\", theme: \"default\" }"
    }

    private func themeInfo(for themeID: String) -> MermaidThemeInfo {
        themes.first(where: { $0.id == themeID })
            ?? MermaidThemeInfo(
                id: "default",
                label: "Default",
                previewBackground: "#ffffff",
                errorColor: "#b91c1c"
            )
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

    static func diagramHTML(for source: String, theme: MermaidThemeInfo, mermaidConfigJS: String) -> String {
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
                mermaid.initialize(\(mermaidConfigJS));
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
