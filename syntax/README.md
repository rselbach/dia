# dia_syntax

`dia_syntax` provides shared Mermaid syntax tokenization for native dia frontends.

## What This Contains

- Mermaid token classification (`keyword`, `operator`, `comment`, `label`)
- Character-offset spans suitable for native text editors
- Pure Rust API reusable by GTK and future macOS frontend

## API

- `highlight_spans(source: &str) -> Vec<HighlightSpan>`

Each `HighlightSpan` includes `start`, `end`, and `kind`, where offsets are
character indices (not bytes).
