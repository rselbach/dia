You are working in the `dia` repo on the Linux host.

Goal: update the Linux UI to fully consume the shared logic that was recently moved into the Rust shared layers, following the same direction already applied on macOS. Do not touch the macOS UI except for reading it as reference if needed.

Context:
- Shared product logic was moved into `core/`
- Shared Mermaid language logic was moved into `syntax/`
- The relevant jj commit is: `501d3447` with message `refactor: share Mermaid logic across frontends`
- The previous macOS polish commit is: `a2912c93` if you need behavioral context

What is now shared in `core`:
- document defaults/naming/extension helpers
- theme catalog/default theme/config generation
- theme palette metadata (`previewBackground`, `errorColor`)
- FFI-facing wrappers for syntax helpers

Important shared APIs now available from `core/src/lib.rs` / `core/include/dia_core.h`:
- `DiaCore::default_document_content()`
- `DiaCore::display_name()`
- `DiaCore::suggested_document_name()`
- `DiaCore::suggested_export_name()`
- `DiaCore::ensure_document_extension(...)`
- `DiaCore::ensure_export_extension(...)`
- `DiaCore::default_theme_id()`
- `DiaCore::mermaid_theme_catalog_json()`
- `DiaCore::normalize_theme_id(...)`
- `DiaCore::mermaid_config_js(...)`
- `DiaCore::mermaid_highlight_spans_json(...)`
- `DiaCore::auto_indent_insertion(...)`

What is now shared in `syntax/src/lib.rs`:
- `highlight_spans(...)`
- `leading_indentation(...)`
- `auto_indent_insertion(...)`

What I want you to do:
1. Review `linux-ui/src/main.rs`
2. Make Linux consume the shared logic wherever it still duplicates behavior that now exists in `core` or `syntax`
3. Keep GTK/WebKit-specific rendering, menus, dialogs, clipboard, and preview interaction behavior in Linux UI
4. Do NOT move platform-specific UI code into shared crates
5. Prefer the shared source of truth wherever available

Specifically check and update Linux for:
- starter document content uses `DiaCore::default_document_content()`
- window/display name uses `DiaCore::display_name()`
- save/export suggested names use shared core helpers
- missing-extension handling uses shared core helpers
- editor auto-indent uses shared syntax helpers
- Mermaid syntax highlighting uses shared syntax helpers
- preview default theme uses `DiaCore::default_theme_id()`
- preview palette styling (`background`, `error color`) uses shared theme catalog metadata from `DiaCore::mermaid_theme_catalog_json()`
- avoid hardcoded duplicate theme ids, names, colors, or config if shared helpers now provide them

Constraints:
- Work only on Linux/shared Rust code needed for Linux
- Do not modify macOS behavior unless absolutely required for shared build consistency
- Do not reintroduce duplicated theme/tokenizer/default-content logic into Linux
- Keep the architecture sane: pure shared logic in `core`/`syntax`, GTK/WebKit glue in Linux UI

Verification:
- Run the relevant Rust tests/builds
- At minimum run:
  - `cargo test --manifest-path syntax/Cargo.toml`
  - `cargo test --manifest-path core/Cargo.toml`
  - `cargo build --manifest-path linux-ui/Cargo.toml`
- If Linux system packages are missing, report the exact pkg-config errors instead of hand-waving

Deliverables:
- implement the Linux-side updates
- summarize exactly what Linux now consumes from `core` and `syntax`
- call out any remaining Linux-only duplication that should stay local
