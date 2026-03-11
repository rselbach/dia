# macOS Native UI (Swift)

This package is the native macOS frontend for dia.

It keeps file/document state in `dia_core` and focuses this target on native
presentation and interaction using SwiftUI, AppKit dialogs, and `WKWebView`
for Mermaid rendering.

## Current Scope

- Native macOS window and controls
- Split editor/preview layout
- Mermaid preview in `WKWebView`
- New / Open / Open Recent / Save / Save As / Export PNG
- Dirty-state title updates
- Recent-file persistence through `dia_core`
- App quit guard for unsaved changes

## Build

Build the Rust core first:

```bash
cargo build --release --manifest-path core/Cargo.toml
```

Then build or run the Swift app:

```bash
swift build --package-path macos-ui
swift run --package-path macos-ui
```

## Notes

- Mermaid is loaded from jsDelivr in this initial Swift frontend.
- The Rust core API is imported via the C header in `core/include/dia_core.h`.
