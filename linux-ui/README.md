# Linux Native UI (GTK)

This crate is a Linux-native frontend for dia.

It keeps application state and file behavior in `dia_core` and focuses this
crate on presentation and user interaction.

## Current Scope

- Native GTK window and controls
- Split editor/preview layout
- Mermaid preview in `WebKitGTK`
- Mermaid-aware syntax highlighting in the source editor via shared `dia_syntax`
- Auto-indent on Enter in the source editor
- Open / Open Recent / Save / Save As / Export PNG / Right-click Copy as PNG
- Dirty-state title updates
- Recent-file persistence through `dia_core`
- Desktop integration metadata (`.desktop`, icon theme assets, AppStream metainfo)
- Mermaid file association for `.mmd` and `.mermaid`

## System Dependencies

On Arch Linux:

```bash
sudo pacman -S --needed rust gtk4 webkitgtk-6.0
```

## Run

```bash
cargo run
```

## Notes

- Mermaid is vendored locally at `vendor/mermaid.min.js`, so preview rendering
  works offline.
- Linux packaging installs `com.rselbach.dia.desktop` and MIME metadata so
  Mermaid files can be opened directly in dia from desktop file managers.
- This crate is intentionally Linux-focused; macOS UI work will live in a
  separate native frontend.
