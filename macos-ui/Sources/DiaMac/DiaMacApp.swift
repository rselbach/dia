import AppKit
import SwiftUI
import WebKit

private enum AppMetadata {
    static let displayName = "Dia"
    static let fallbackVersion = "0.1.0"

    static var versionString: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (shortVersion, buildVersion) {
        case let (short?, build?) where !short.isEmpty && !build.isEmpty && short != build:
            return "\(short) (\(build))"
        case let (short?, _) where !short.isEmpty:
            return short
        case let (_, build?) where !build.isEmpty:
            return build
        default:
            return fallbackVersion
        }
    }

    static var aboutCredits: NSAttributedString {
        NSAttributedString(
            string: "Native macOS Mermaid editor and preview.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
    }

    static func configureApplicationIdentity() {
        ProcessInfo.processInfo.processName = displayName
    }

    static func showAboutPanel() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: displayName,
            .applicationVersion: versionString,
            .credits: aboutCredits,
        ])
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@main
struct DiaMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var preferences = AppPreferences()
    @StateObject private var state: AppState

    init() {
        AppMetadata.configureApplicationIdentity()
        NSApplication.shared.setActivationPolicy(.regular)
        let preferences = AppPreferences()
        _preferences = StateObject(wrappedValue: preferences)
        _state = StateObject(wrappedValue: AppState(preferences: preferences))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .environmentObject(preferences)
                .frame(minWidth: 960, minHeight: 620)
                .onAppear {
                    appDelegate.state = state
                    state.startup()
                }
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            DiaCommands(state: state)
        }

        Settings {
            PreferencesView()
                .environmentObject(preferences)
        }
    }
}

// MARK: - App Delegate

private final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?

    func applicationDidFinishLaunching(_: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard let state else { return .terminateNow }
        return state.confirmBeforeQuit() ? .terminateNow : .terminateCancel
    }
}

// MARK: - Content View

private struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                CodeEditorView(text: $state.source, font: preferences.editorFont)
                    .frame(minWidth: 300)

                MermaidPreview(
                    html: state.previewHTML,
                    zoomScale: state.previewZoomScale,
                    onCreated: state.attachPreview,
                    onZoomChanged: state.updatePreviewZoomScaleFromGesture,
                    onCopyPNG: state.copyPreviewAsPNG,
                    onCopySVG: state.copyPreviewAsSVG
                )
                    .frame(minWidth: 300)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            statusBar
                .animation(.easeInOut(duration: 0.25), value: state.statusMessage.isEmpty)
        }
        .toolbar { toolbarContent }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button(action: state.newDocument) {
                Label("New", systemImage: "doc.badge.plus")
            }
            .help("New Document")

            Button(action: state.openDocument) {
                Label("Open", systemImage: "folder")
            }
            .help("Open Document")

            Button(action: state.saveDocument) {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .help("Save Document")
        }

        ToolbarItem(placement: .automatic) {
            Picker("Theme", selection: $state.selectedTheme) {
                ForEach(MermaidTheme.allCases) { theme in
                    Text(theme.label).tag(theme)
                }
            }
            .pickerStyle(.menu)
            .help("Diagram Theme")
        }

        ToolbarItem(placement: .primaryAction) {
            Button(action: state.exportPNG) {
                Label("Export PNG", systemImage: "photo")
            }
            .help("Export as PNG")
        }

        ToolbarItem(placement: .automatic) {
            Menu {
                Button("Zoom In", action: state.zoomInPreview)
                Button("Zoom Out", action: state.zoomOutPreview)
                Divider()
                Button("Actual Size", action: state.resetPreviewZoom)
            } label: {
                Label("Zoom", systemImage: "plus.magnifyingglass")
            }
            .help("Preview Zoom")
        }

        ToolbarItem(placement: .automatic) {
            Text("\(Int((state.previewZoomScale * 100).rounded()))%")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 48, alignment: .trailing)
        }
    }

    // MARK: Status Bar

    @ViewBuilder
    private var statusBar: some View {
        if !state.statusMessage.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))

                Text(state.statusMessage)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)

                Spacer()

                Button(action: state.dismissStatus) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .opacity(0.7)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.85))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Menu Bar Commands

private struct DiaCommands: Commands {
    @ObservedObject var state: AppState

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(AppMetadata.displayName)", action: AppMetadata.showAboutPanel)
        }

        CommandGroup(replacing: .newItem) {
            Button("New", action: state.newDocument)
                .keyboardShortcut("n", modifiers: .command)

            Button("Open...", action: state.openDocument)
                .keyboardShortcut("o", modifiers: .command)

            Menu("Open Recent") {
                if state.recentFiles.isEmpty {
                    Button("No Recent Files") {}
                        .disabled(true)
                } else {
                    ForEach(state.recentFiles, id: \.self) { path in
                        Button(path) {
                            state.openRecent(path: path)
                        }
                    }
                }
            }
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save", action: state.saveDocument)
                .keyboardShortcut("s", modifiers: .command)

            Button("Save As...", action: state.saveDocumentAs)
                .keyboardShortcut("S", modifiers: [.command, .shift])
        }

        CommandGroup(after: .saveItem) {
            Button("Export PNG...", action: state.exportPNG)
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }

        CommandGroup(after: .toolbar) {
            Menu("Theme") {
                Picker("Theme", selection: $state.selectedTheme) {
                    ForEach(MermaidTheme.allCases) { theme in
                        Text(theme.label).tag(theme)
                    }
                }
            }
        }

        CommandGroup(after: .sidebar) {
            Button("Zoom In", action: state.zoomInPreview)
                .keyboardShortcut("+", modifiers: .command)

            Button("Zoom Out", action: state.zoomOutPreview)
                .keyboardShortcut("-", modifiers: .command)

            Button("Actual Size", action: state.resetPreviewZoom)
                .keyboardShortcut("0", modifiers: .command)
        }
    }
}

// MARK: - Mermaid Preview (WKWebView)

private struct MermaidPreview: NSViewRepresentable {
    let html: String
    let zoomScale: CGFloat
    let onCreated: (PreviewWebView) -> Void
    let onZoomChanged: (CGFloat) -> Void
    let onCopyPNG: () -> Void
    let onCopySVG: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onZoomChanged: onZoomChanged)
    }

    func makeNSView(context: Context) -> PreviewWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: "zoomChanged")

        let webView = PreviewWebView(frame: .zero, configuration: configuration)
        webView.copyPNGHandler = onCopyPNG
        webView.copySVGHandler = onCopySVG
        context.coordinator.lastHTML = html
        context.coordinator.lastZoomScale = zoomScale
        webView.loadHTMLString(html, baseURL: nil)
        onCreated(webView)
        return webView
    }

    func updateNSView(_ nsView: PreviewWebView, context: Context) {
        if html != context.coordinator.lastHTML {
            context.coordinator.lastHTML = html
            nsView.loadHTMLString(html, baseURL: nil)
        }

        context.coordinator.lastZoomScale = zoomScale
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onZoomChanged: (CGFloat) -> Void
        var lastHTML = ""
        var lastZoomScale: CGFloat = 1

        init(onZoomChanged: @escaping (CGFloat) -> Void) {
            self.onZoomChanged = onZoomChanged
        }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "zoomChanged" else { return }

            let nextScale: CGFloat?
            if let number = message.body as? NSNumber {
                nextScale = CGFloat(truncating: number)
            } else if let value = message.body as? Double {
                nextScale = CGFloat(value)
            } else if let value = message.body as? CGFloat {
                nextScale = value
            } else {
                nextScale = nil
            }

            guard let nextScale else { return }
            lastZoomScale = nextScale
            onZoomChanged(nextScale)
        }
    }
}

@MainActor
private final class PreviewWebView: WKWebView {
    var copyPNGHandler: (() -> Void)?
    var copySVGHandler: (() -> Void)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.removeAllItems()

        let copyPNGItem = NSMenuItem(title: "Copy as PNG", action: #selector(handleCopyPNG), keyEquivalent: "")
        copyPNGItem.target = self
        menu.addItem(copyPNGItem)

        let copySVGItem = NSMenuItem(title: "Copy as SVG", action: #selector(handleCopySVG), keyEquivalent: "")
        copySVGItem.target = self
        menu.addItem(copySVGItem)

        super.willOpenMenu(menu, with: event)
    }

    @objc private func handleCopyPNG() {
        copyPNGHandler?()
    }

    @objc private func handleCopySVG() {
        copySVGHandler?()
    }
}
