use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::Duration;

use dia_core::DiaCore;
use dia_syntax::{highlight_spans, HighlightKind};
use gtk::{Application, ApplicationWindow};
use gtk4 as gtk;
use webkit6::prelude::*;
use webkit6::{ContextMenuItem, SnapshotOptions, SnapshotRegion, WebView};

const APP_ID: &str = "com.github.rselbach.dia.gtk";
const MERMAID_BUNDLE_NAME: &str = "mermaid.min.js";
const TAG_MERMAID_KEYWORD: &str = "dia-mermaid-keyword";
const TAG_MERMAID_OPERATOR: &str = "dia-mermaid-operator";
const TAG_MERMAID_COMMENT: &str = "dia-mermaid-comment";
const TAG_MERMAID_LABEL: &str = "dia-mermaid-label";

const DEFAULT_CONTENT: &str = "flowchart TD
    A[Start] --> B{Is it working?}
    B -->|Yes| C[Great!]
    B -->|No| D[Debug]
    D --> B
";

fn main() {
    let app = Application::builder().application_id(APP_ID).build();
    app.connect_activate(build_ui);
    app.run();
}

struct UiState {
    core: RefCell<DiaCore>,
    window: ApplicationWindow,
    buffer: gtk::TextBuffer,
    preview: WebView,
    status: gtk::Label,
    preview_base_uri: String,
    render_timer: RefCell<Option<gtk::glib::SourceId>>,
    highlight_timer: RefCell<Option<gtk::glib::SourceId>>,
    suppress_dirty_signal: Cell<bool>,
}

impl UiState {
    fn new(app: &Application) -> Rc<Self> {
        let window = ApplicationWindow::builder()
            .application(app)
            .default_width(1280)
            .default_height(800)
            .build();

        let root = gtk::Box::new(gtk::Orientation::Vertical, 6);
        root.set_margin_top(8);
        root.set_margin_bottom(8);
        root.set_margin_start(8);
        root.set_margin_end(8);

        let toolbar = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        let new_button = gtk::Button::with_label("New");
        let open_button = gtk::Button::with_label("Open");
        let open_recent_button = gtk::Button::with_label("Open Recent");
        let export_png_button = gtk::Button::with_label("Export PNG");
        let save_button = gtk::Button::with_label("Save");
        let save_as_button = gtk::Button::with_label("Save As");
        toolbar.append(&new_button);
        toolbar.append(&open_button);
        toolbar.append(&open_recent_button);
        toolbar.append(&export_png_button);
        toolbar.append(&save_button);
        toolbar.append(&save_as_button);

        let paned = gtk::Paned::new(gtk::Orientation::Horizontal);
        paned.set_wide_handle(true);
        paned.set_position(480);

        let text_buffer = gtk::TextBuffer::new(None::<&gtk::TextTagTable>);
        install_editor_tags(&text_buffer);
        text_buffer.set_text(DEFAULT_CONTENT);

        let editor = gtk::TextView::with_buffer(&text_buffer);
        editor.set_monospace(true);
        editor.set_wrap_mode(gtk::WrapMode::None);

        let editor_scroll = gtk::ScrolledWindow::new();
        editor_scroll.set_hexpand(true);
        editor_scroll.set_vexpand(true);
        editor_scroll.set_child(Some(&editor));

        let preview = WebView::new();
        preview.set_hexpand(true);
        preview.set_vexpand(true);

        paned.set_start_child(Some(&editor_scroll));
        paned.set_end_child(Some(&preview));

        let status = gtk::Label::new(None);
        status.set_xalign(0.0);
        status.set_wrap(true);

        root.append(&toolbar);
        root.append(&paned);
        root.append(&status);

        window.set_child(Some(&root));

        let state = Rc::new(Self {
            core: RefCell::new(DiaCore::new(10)),
            window,
            buffer: text_buffer,
            preview,
            status,
            preview_base_uri: mermaid_vendor_base_uri(),
            render_timer: RefCell::new(None),
            highlight_timer: RefCell::new(None),
            suppress_dirty_signal: Cell::new(false),
        });

        {
            let ui = state.clone();
            let buffer = ui.buffer.clone();
            buffer.connect_changed(move |_| {
                ui.on_buffer_changed();
            });
        }

        {
            let ui = state.clone();
            let key_controller = gtk::EventControllerKey::new();
            key_controller.connect_key_pressed(move |_, key, _, modifiers| {
                if !should_handle_auto_indent(key, modifiers) {
                    return gtk::glib::Propagation::Proceed;
                }

                if ui.handle_auto_indent_newline() {
                    return gtk::glib::Propagation::Stop;
                }

                gtk::glib::Propagation::Proceed
            });
            editor.add_controller(key_controller);
        }

        {
            let ui = state.clone();
            new_button.connect_clicked(move |_| {
                ui.handle_new();
            });
        }

        {
            let ui = state.clone();
            open_button.connect_clicked(move |_| {
                ui.handle_open();
            });
        }

        {
            let ui = state.clone();
            open_recent_button.connect_clicked(move |_| {
                ui.handle_open_recent();
            });
        }

        {
            let ui = state.clone();
            export_png_button.connect_clicked(move |_| {
                ui.handle_export_png();
            });
        }

        {
            let ui = state.clone();
            let preview = ui.preview.clone();
            preview.connect_context_menu(move |preview, context_menu, _| {
                let action = gtk::gio::SimpleAction::new("copy-preview-png", None);
                let status = ui.status.clone();
                let preview = preview.clone();
                action.connect_activate(move |_, _| {
                    let status = status.clone();
                    preview.snapshot(
                        SnapshotRegion::Visible,
                        SnapshotOptions::NONE,
                        None::<&gtk::gio::Cancellable>,
                        move |result| match result {
                            Ok(texture) => {
                                if let Some(display) = gtk::gdk::Display::default() {
                                    display.clipboard().set_texture(&texture);
                                    status.set_text("");
                                } else {
                                    status.set_text("copy failed: no display available");
                                }
                            }
                            Err(err) => status.set_text(&format!("copy failed: {err}")),
                        },
                    );
                });

                context_menu.append(&ContextMenuItem::new_separator());
                context_menu.append(&ContextMenuItem::from_gaction(&action, "Copy as PNG", None));
                false
            });
        }

        {
            let ui = state.clone();
            save_button.connect_clicked(move |_| {
                ui.handle_save();
            });
        }

        {
            let ui = state.clone();
            save_as_button.connect_clicked(move |_| {
                ui.handle_save_as();
            });
        }

        state
    }

    fn startup(&self) {
        if let Err(err) = ensure_mermaid_bundle_exists() {
            self.set_error(err);
        }

        if let Err(err) = self.load_recent_files() {
            self.set_error(format!("failed to load recent files: {err}"));
        }

        self.schedule_render();
        self.schedule_highlight();
        self.update_title();
        self.window.present();
    }

    fn on_buffer_changed(&self) {
        if self.suppress_dirty_signal.get() {
            return;
        }

        self.core.borrow_mut().set_dirty(true);
        self.update_title();
        self.schedule_render();
        self.schedule_highlight();
    }

    fn handle_new(&self) {
        if !self.confirm_discard_if_needed() {
            return;
        }

        {
            let mut core = self.core.borrow_mut();
            core.new_document();
        }

        self.set_editor_content(DEFAULT_CONTENT);
        self.clear_status();
        self.update_title();
        self.schedule_render();
    }

    fn handle_open(&self) {
        if !self.confirm_discard_if_needed() {
            return;
        }

        let Some(path) = self.choose_open_path() else {
            return;
        };

        self.open_document(&path);
    }

    fn handle_open_recent(&self) {
        if !self.confirm_discard_if_needed() {
            return;
        }

        let recent_files = self.core.borrow().recent_files().to_vec();
        if recent_files.is_empty() {
            self.set_error("no recent files available".to_string());
            return;
        }

        let Some(path) = self.choose_recent_path(&recent_files) else {
            return;
        };

        self.open_document(&path);
    }

    fn handle_export_png(&self) {
        let suggested = self
            .core
            .borrow()
            .current_file()
            .and_then(|path| path.file_stem())
            .and_then(|name| name.to_str())
            .map(|name| format!("{name}.png"))
            .unwrap_or("diagram.png".to_string());

        let Some(path) = self.choose_export_path(&suggested) else {
            return;
        };

        let final_path = ensure_png_extension(path);
        let status = self.status.clone();
        self.preview.snapshot(
            SnapshotRegion::Visible,
            SnapshotOptions::NONE,
            None::<&gtk::gio::Cancellable>,
            move |result| match result {
                Ok(texture) => match texture.save_to_png(&final_path) {
                    Ok(()) => status.set_text(""),
                    Err(err) => status.set_text(&format!("export failed: {err}")),
                },
                Err(err) => status.set_text(&format!("export failed: {err}")),
            },
        );
    }

    fn open_document(&self, path: &Path) {
        match self.core.borrow_mut().open_file(path) {
            Ok(content) => {
                self.set_editor_content(&content);
                self.clear_status();
                self.update_title();
                self.schedule_render();
                if let Err(err) = self.persist_recent_files() {
                    self.set_error(format!("failed to persist recent files: {err}"));
                }
            }
            Err(err) => {
                self.set_error(format!("open failed: {err}"));
            }
        }
    }

    fn handle_save(&self) {
        let content = self.buffer_text();
        let has_current_file = self.core.borrow().current_file().is_some();
        if has_current_file {
            match self.core.borrow_mut().save(&content) {
                Ok(_) => {
                    self.clear_status();
                    self.update_title();
                    if let Err(err) = self.persist_recent_files() {
                        self.set_error(format!("failed to persist recent files: {err}"));
                    }
                }
                Err(err) => {
                    self.set_error(format!("save failed: {err}"));
                }
            }
            return;
        }

        self.handle_save_as_with_content(&content);
    }

    fn handle_save_as(&self) {
        let content = self.buffer_text();
        self.handle_save_as_with_content(&content);
    }

    fn handle_save_as_with_content(&self, content: &str) {
        let suggested = self
            .core
            .borrow()
            .current_file()
            .and_then(|path| path.file_name())
            .and_then(|name| name.to_str())
            .unwrap_or("diagram.mmd")
            .to_owned();

        let Some(path) = self.choose_save_path(&suggested) else {
            return;
        };

        let final_path = ensure_mmd_extension(path);
        match self.core.borrow_mut().save_as(&final_path, content) {
            Ok(_) => {
                self.clear_status();
                self.update_title();
                if let Err(err) = self.persist_recent_files() {
                    self.set_error(format!("failed to persist recent files: {err}"));
                }
            }
            Err(err) => {
                self.set_error(format!("save as failed: {err}"));
            }
        }
    }

    fn confirm_discard_if_needed(&self) -> bool {
        if !self.core.borrow().is_dirty() {
            return true;
        }

        let dialog = gtk::MessageDialog::builder()
            .transient_for(&self.window)
            .modal(true)
            .message_type(gtk::MessageType::Question)
            .buttons(gtk::ButtonsType::YesNo)
            .text("Discard unsaved changes?")
            .secondary_text("Your current changes will be lost.")
            .build();

        let response = gtk::glib::MainContext::default().block_on(dialog.run_future());
        dialog.close();
        response == gtk::ResponseType::Yes
    }

    fn choose_open_path(&self) -> Option<PathBuf> {
        let dialog = gtk::FileChooserDialog::builder()
            .title("Open Mermaid Diagram")
            .transient_for(&self.window)
            .modal(true)
            .action(gtk::FileChooserAction::Open)
            .build();
        dialog.add_button("Cancel", gtk::ResponseType::Cancel);
        dialog.add_button("Open", gtk::ResponseType::Accept);

        let filter = gtk::FileFilter::new();
        filter.set_name(Some("Mermaid (*.mmd, *.mermaid)"));
        filter.add_pattern("*.mmd");
        filter.add_pattern("*.mermaid");
        dialog.add_filter(&filter);

        let response = gtk::glib::MainContext::default().block_on(dialog.run_future());
        let selected = if response == gtk::ResponseType::Accept {
            dialog.file().and_then(|file| file.path())
        } else {
            None
        };
        dialog.close();
        selected
    }

    fn choose_recent_path(&self, recent_files: &[PathBuf]) -> Option<PathBuf> {
        let dialog = gtk::Dialog::builder()
            .title("Open Recent")
            .transient_for(&self.window)
            .modal(true)
            .build();
        dialog.add_button("Cancel", gtk::ResponseType::Cancel);
        dialog.add_button("Open", gtk::ResponseType::Accept);
        dialog.set_default_response(gtk::ResponseType::Accept);

        let content = dialog.content_area();

        let prompt = gtk::Label::new(Some("Choose a recent Mermaid diagram"));
        prompt.set_xalign(0.0);
        content.append(&prompt);

        let combo = gtk::ComboBoxText::new();
        combo.set_hexpand(true);
        for path in recent_files {
            combo.append_text(&path.display().to_string());
        }
        combo.set_active(Some(0));
        content.append(&combo);

        let response = gtk::glib::MainContext::default().block_on(dialog.run_future());
        let selected = if response == gtk::ResponseType::Accept {
            combo
                .active()
                .and_then(|index| recent_files.get(index as usize).cloned())
        } else {
            None
        };
        dialog.close();
        selected
    }

    fn choose_save_path(&self, suggested_name: &str) -> Option<PathBuf> {
        let dialog = gtk::FileChooserDialog::builder()
            .title("Save Mermaid Diagram")
            .transient_for(&self.window)
            .modal(true)
            .action(gtk::FileChooserAction::Save)
            .build();
        dialog.add_button("Cancel", gtk::ResponseType::Cancel);
        dialog.add_button("Save", gtk::ResponseType::Accept);
        dialog.set_current_name(suggested_name);

        let filter = gtk::FileFilter::new();
        filter.set_name(Some("Mermaid (*.mmd)"));
        filter.add_pattern("*.mmd");
        dialog.add_filter(&filter);

        let response = gtk::glib::MainContext::default().block_on(dialog.run_future());
        let selected = if response == gtk::ResponseType::Accept {
            dialog.file().and_then(|file| file.path())
        } else {
            None
        };
        dialog.close();
        selected
    }

    fn choose_export_path(&self, suggested_name: &str) -> Option<PathBuf> {
        let dialog = gtk::FileChooserDialog::builder()
            .title("Export PNG")
            .transient_for(&self.window)
            .modal(true)
            .action(gtk::FileChooserAction::Save)
            .build();
        dialog.add_button("Cancel", gtk::ResponseType::Cancel);
        dialog.add_button("Export", gtk::ResponseType::Accept);
        dialog.set_current_name(suggested_name);

        let filter = gtk::FileFilter::new();
        filter.set_name(Some("PNG image (*.png)"));
        filter.add_pattern("*.png");
        dialog.add_filter(&filter);

        let response = gtk::glib::MainContext::default().block_on(dialog.run_future());
        let selected = if response == gtk::ResponseType::Accept {
            dialog.file().and_then(|file| file.path())
        } else {
            None
        };
        dialog.close();
        selected
    }

    fn set_editor_content(&self, text: &str) {
        self.suppress_dirty_signal.set(true);
        self.buffer.set_text(text);
        self.suppress_dirty_signal.set(false);
        self.schedule_highlight();
    }

    fn buffer_text(&self) -> String {
        let start = self.buffer.start_iter();
        let end = self.buffer.end_iter();
        self.buffer.text(&start, &end, false).to_string()
    }

    fn handle_auto_indent_newline(&self) -> bool {
        self.buffer.delete_selection(true, true);

        let Some(insert_mark) = self.buffer.mark("insert") else {
            return false;
        };

        let insert_iter = self.buffer.iter_at_mark(&insert_mark);
        let Some(line_start) = self.buffer.iter_at_line(insert_iter.line()) else {
            return false;
        };

        let prefix = self
            .buffer
            .text(&line_start, &insert_iter, false)
            .to_string();
        let indent = leading_indentation(&prefix);

        let mut insert_iter = self.buffer.iter_at_mark(&insert_mark);
        let insert_text = format!("\n{indent}");
        self.buffer.insert(&mut insert_iter, &insert_text);
        true
    }

    fn schedule_render(&self) {
        cancel_timer(&self.render_timer);

        let source = self.buffer_text();
        let preview = self.preview.clone();
        let base_uri = self.preview_base_uri.clone();
        let source_id = gtk::glib::timeout_add_local(Duration::from_millis(250), move || {
            preview.load_html(&diagram_html(&source), Some(&base_uri));
            gtk::glib::ControlFlow::Break
        });

        *self.render_timer.borrow_mut() = Some(source_id);
    }

    fn schedule_highlight(&self) {
        cancel_timer(&self.highlight_timer);

        let buffer = self.buffer.clone();
        let source_id = gtk::glib::timeout_add_local(Duration::from_millis(120), move || {
            apply_mermaid_highlighting(&buffer);
            gtk::glib::ControlFlow::Break
        });

        *self.highlight_timer.borrow_mut() = Some(source_id);
    }

    fn update_title(&self) {
        let (name, dirty) = {
            let core = self.core.borrow();
            let file_name = core
                .current_file()
                .and_then(|path| path.file_name())
                .and_then(|value| value.to_str())
                .unwrap_or("Untitled")
                .to_owned();
            (file_name, core.is_dirty())
        };

        let dirty_suffix = if dirty { " *" } else { "" };
        self.window
            .set_title(Some(&format!("dia (GTK) - {name}{dirty_suffix}")));
    }

    fn set_error(&self, message: String) {
        self.status.set_text(&message);
    }

    fn clear_status(&self) {
        self.status.set_text("");
    }

    fn load_recent_files(&self) -> Result<(), String> {
        let path = recent_files_path()?;
        self.core
            .borrow_mut()
            .load_recent_files(&path)
            .map_err(|err| err.to_string())
    }

    fn persist_recent_files(&self) -> Result<(), String> {
        let path = recent_files_path()?;
        self.core
            .borrow()
            .save_recent_files(&path)
            .map_err(|err| err.to_string())
    }
}

fn recent_files_path() -> Result<PathBuf, String> {
    let Some(config_root) = dirs::config_dir() else {
        return Err("could not resolve user config directory".to_string());
    };
    Ok(config_root.join("dia").join("recent-files.json"))
}

fn ensure_mmd_extension(mut path: PathBuf) -> PathBuf {
    if path.extension().is_none() {
        path.set_extension("mmd");
    }
    path
}

fn ensure_png_extension(mut path: PathBuf) -> PathBuf {
    if path.extension().is_none() {
        path.set_extension("png");
    }
    path
}

fn mermaid_bundle_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("vendor")
        .join(MERMAID_BUNDLE_NAME)
}

fn mermaid_vendor_base_uri() -> String {
    let vendor_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("vendor");
    let mut uri = gtk::gio::File::for_path(vendor_dir).uri().to_string();
    if !uri.ends_with('/') {
        uri.push('/');
    }
    uri
}

fn ensure_mermaid_bundle_exists() -> Result<(), String> {
    let bundle_path = mermaid_bundle_path();
    if bundle_path.is_file() {
        return Ok(());
    }

    Err(format!(
        "missing vendored Mermaid bundle: {}",
        bundle_path.display()
    ))
}

fn cancel_timer(timer: &RefCell<Option<gtk::glib::SourceId>>) {
    let Some(source_id) = timer.borrow_mut().take() else {
        return;
    };

    // One-shot sources are removed by GLib once they fire; avoid panicking on stale IDs.
    if gtk::glib::MainContext::default()
        .find_source_by_id(&source_id)
        .is_some()
    {
        source_id.remove();
    }
}

fn should_handle_auto_indent(key: gtk::gdk::Key, modifiers: gtk::gdk::ModifierType) -> bool {
    if key != gtk::gdk::Key::Return && key != gtk::gdk::Key::KP_Enter {
        return false;
    }

    let blocked = gtk::gdk::ModifierType::CONTROL_MASK
        | gtk::gdk::ModifierType::ALT_MASK
        | gtk::gdk::ModifierType::SUPER_MASK
        | gtk::gdk::ModifierType::META_MASK;

    !modifiers.intersects(blocked)
}

fn leading_indentation(line: &str) -> String {
    line.chars()
        .take_while(|value| matches!(value, ' ' | '\t'))
        .collect()
}

fn install_editor_tags(buffer: &gtk::TextBuffer) {
    let _ = buffer.create_tag(
        Some(TAG_MERMAID_KEYWORD),
        &[("foreground", &"#0f766e"), ("weight", &700i32)],
    );
    let _ = buffer.create_tag(
        Some(TAG_MERMAID_OPERATOR),
        &[("foreground", &"#b45309"), ("weight", &700i32)],
    );
    let _ = buffer.create_tag(
        Some(TAG_MERMAID_COMMENT),
        &[
            ("foreground", &"#64748b"),
            ("style", &gtk::pango::Style::Italic),
        ],
    );
    let _ = buffer.create_tag(Some(TAG_MERMAID_LABEL), &[("foreground", &"#9333ea")]);
}

fn apply_mermaid_highlighting(buffer: &gtk::TextBuffer) {
    clear_mermaid_highlighting(buffer);

    let start = buffer.start_iter();
    let end = buffer.end_iter();
    let text = buffer.text(&start, &end, false).to_string();

    for span in highlight_spans(&text) {
        let start = match i32::try_from(span.start) {
            Ok(value) => value,
            Err(_) => continue,
        };
        let end = match i32::try_from(span.end) {
            Ok(value) => value,
            Err(_) => continue,
        };
        apply_tag_range(buffer, tag_name_for_kind(span.kind), start, end);
    }
}

fn clear_mermaid_highlighting(buffer: &gtk::TextBuffer) {
    let tag_table = buffer.tag_table();

    let start = buffer.start_iter();
    let end = buffer.end_iter();
    for tag_name in [
        TAG_MERMAID_KEYWORD,
        TAG_MERMAID_OPERATOR,
        TAG_MERMAID_COMMENT,
        TAG_MERMAID_LABEL,
    ] {
        if let Some(tag) = tag_table.lookup(tag_name) {
            buffer.remove_tag(&tag, &start, &end);
        }
    }
}

fn tag_name_for_kind(kind: HighlightKind) -> &'static str {
    match kind {
        HighlightKind::Keyword => TAG_MERMAID_KEYWORD,
        HighlightKind::Operator => TAG_MERMAID_OPERATOR,
        HighlightKind::Comment => TAG_MERMAID_COMMENT,
        HighlightKind::Label => TAG_MERMAID_LABEL,
    }
}

fn apply_tag_range(buffer: &gtk::TextBuffer, tag_name: &str, start: i32, end: i32) {
    if start >= end {
        return;
    }

    let tag_table = buffer.tag_table();
    let Some(tag) = tag_table.lookup(tag_name) else {
        return;
    };

    let start_iter = buffer.iter_at_offset(start);
    let end_iter = buffer.iter_at_offset(end);
    buffer.apply_tag(&tag, &start_iter, &end_iter);
}

fn diagram_html(source: &str) -> String {
    let source_json = match serde_json::to_string(source) {
        Ok(value) => value,
        Err(err) => {
            let escaped = html_escape(&format!("failed to encode source: {err}"));
            return format!(
                "<!doctype html><html><body><pre style='color:#b00020'>{escaped}</pre></body></html>"
            );
        }
    };

    format!(
        r#"<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <style>
      html, body {{
        margin: 0;
        height: 100%;
        font-family: "Iosevka", "Fira Code", monospace;
        background: #f8fafc;
      }}
      #root {{
        height: 100%;
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 16px;
        box-sizing: border-box;
      }}
      #diagram svg {{
        width: 100%;
        height: auto;
        max-height: calc(100vh - 40px);
      }}
      #error {{
        color: #b00020;
        white-space: pre-wrap;
        font-family: monospace;
      }}
    </style>
    <script src="{MERMAID_BUNDLE_NAME}"></script>
  </head>
  <body>
    <div id="root">
      <div id="diagram"></div>
      <pre id="error"></pre>
    </div>
    <script>
      const source = {source_json};
      const diagramEl = document.getElementById("diagram");
      const errorEl = document.getElementById("error");
      if (typeof mermaid === "undefined") {{
        errorEl.textContent = "failed to load local Mermaid bundle";
      }} else {{
      mermaid.initialize({{ startOnLoad: false, securityLevel: "strict", theme: "default" }});

      if (!source.trim()) {{
        diagramEl.textContent = "";
        errorEl.textContent = "";
      }} else {{
        mermaid.render("dia-preview", source)
          .then((result) => {{
            diagramEl.innerHTML = result.svg;
            errorEl.textContent = "";
          }})
          .catch((err) => {{
            diagramEl.innerHTML = "";
            errorEl.textContent = String(err);
          }});
      }}
      }}
    </script>
  </body>
</html>
"#
    )
}

fn html_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

fn build_ui(app: &Application) {
    let ui = UiState::new(app);
    ui.startup();
}

#[cfg(test)]
mod tests {
    use super::{leading_indentation, should_handle_auto_indent};
    use gtk4 as gtk;

    #[test]
    fn keeps_space_and_tab_indentation() {
        assert_eq!(leading_indentation("    line"), "    ");
        assert_eq!(leading_indentation("\t\tline"), "\t\t");
        assert_eq!(leading_indentation("  \t line"), "  \t ");
    }

    #[test]
    fn handles_return_without_modifier() {
        assert!(should_handle_auto_indent(
            gtk::gdk::Key::Return,
            gtk::gdk::ModifierType::empty()
        ));
    }

    #[test]
    fn ignores_return_with_command_modifiers() {
        assert!(!should_handle_auto_indent(
            gtk::gdk::Key::Return,
            gtk::gdk::ModifierType::CONTROL_MASK
        ));
        assert!(!should_handle_auto_indent(
            gtk::gdk::Key::KP_Enter,
            gtk::gdk::ModifierType::ALT_MASK
        ));
    }
}
