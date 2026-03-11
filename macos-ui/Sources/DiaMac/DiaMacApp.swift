import AppKit
import SwiftUI
import WebKit

@main
struct DiaMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
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

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                CodeEditorView(text: $state.source)
                    .frame(minWidth: 300)

                MermaidPreview(html: state.previewHTML, onCreated: state.attachPreview)
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
        CommandGroup(replacing: .newItem) {
            Button("New", action: state.newDocument)
                .keyboardShortcut("n", modifiers: .command)

            Button("Open...", action: state.openDocument)
                .keyboardShortcut("o", modifiers: .command)
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

        CommandMenu("Open Recent") {
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

        CommandMenu("Theme") {
            ForEach(MermaidTheme.allCases) { theme in
                Button(theme.label) {
                    state.selectedTheme = theme
                }
            }
        }
    }
}

// MARK: - Mermaid Preview (WKWebView)

private struct MermaidPreview: NSViewRepresentable {
    let html: String
    let onCreated: (WKWebView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: nil)
        onCreated(webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard html != context.coordinator.lastHTML else { return }
        context.coordinator.lastHTML = html
        nsView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator {
        var lastHTML = ""
    }
}
