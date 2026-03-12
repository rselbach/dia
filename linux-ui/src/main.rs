use std::cell::{Cell, RefCell};
use std::fs;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::Duration;

use dia_core::DiaCore;
use dia_syntax::{auto_indent_insertion, highlight_spans, HighlightKind};
use gtk::{Application, ApplicationWindow};
use gtk4 as gtk;
use serde::{Deserialize, Serialize};
use webkit6::prelude::*;
use webkit6::{ContextMenuItem, SnapshotOptions, SnapshotRegion, WebView};

const APP_ID: &str = "com.github.rselbach.dia.gtk";
const MERMAID_BUNDLE_NAME: &str = "mermaid.min.js";
const TAG_MERMAID_KEYWORD: &str = "dia-mermaid-keyword";
const TAG_MERMAID_OPERATOR: &str = "dia-mermaid-operator";
const TAG_MERMAID_COMMENT: &str = "dia-mermaid-comment";
const TAG_MERMAID_LABEL: &str = "dia-mermaid-label";

#[derive(Clone, Deserialize)]
struct MermaidThemeInfo {
    id: String,
    label: String,
    #[serde(rename = "previewBackground")]
    preview_background: String,
    #[serde(rename = "errorColor")]
    error_color: String,
}

#[derive(Clone)]
struct PreviewTheme {
    info: MermaidThemeInfo,
    mermaid_config_js: String,
}

#[derive(Deserialize, Serialize)]
struct AppPreferences {
    #[serde(rename = "defaultTheme")]
    default_theme_id: String,
}

struct ThemeSetup {
    themes: Vec<MermaidThemeInfo>,
    selected_theme_id: String,
    preview_theme: PreviewTheme,
    startup_errors: Vec<String>,
}

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
    available_themes: Vec<MermaidThemeInfo>,
    selected_theme_id: RefCell<String>,
    preview_theme: RefCell<PreviewTheme>,
    theme_startup_errors: Vec<String>,
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
        let theme_label = gtk::Label::new(Some("Theme"));
        let theme_combo = gtk::ComboBoxText::new();
        theme_combo.set_hexpand(false);
        toolbar.append(&new_button);
        toolbar.append(&open_button);
        toolbar.append(&open_recent_button);
        toolbar.append(&export_png_button);
        toolbar.append(&save_button);
        toolbar.append(&save_as_button);
        toolbar.append(&theme_label);
        toolbar.append(&theme_combo);

        let paned = gtk::Paned::new(gtk::Orientation::Horizontal);
        paned.set_wide_handle(true);
        paned.set_position(480);

        let text_buffer = gtk::TextBuffer::new(None::<&gtk::TextTagTable>);
        install_editor_tags(&text_buffer);
        text_buffer.set_text(DiaCore::default_document_content());

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

        let theme_setup = load_theme_setup();
        for theme in &theme_setup.themes {
            theme_combo.append(Some(&theme.id), &theme.label);
        }
        theme_combo.set_active_id(Some(&theme_setup.selected_theme_id));

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
            available_themes: theme_setup.themes,
            selected_theme_id: RefCell::new(theme_setup.selected_theme_id),
            preview_theme: RefCell::new(theme_setup.preview_theme),
            theme_startup_errors: theme_setup.startup_errors,
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

        {
            let ui = state.clone();
            theme_combo.connect_changed(move |combo| {
                let Some(theme_id) = combo.active_id() else {
                    return;
                };

                ui.handle_theme_changed(theme_id.as_str());
            });
        }

        state
    }

    fn startup(&self) {
        let mut startup_errors = Vec::new();

        if let Err(err) = ensure_mermaid_bundle_exists() {
            startup_errors.push(err);
        }

        if let Err(err) = self.load_recent_files() {
            startup_errors.push(format!("failed to load recent files: {err}"));
        }

        startup_errors.extend(self.theme_startup_errors.iter().cloned());

        if startup_errors.is_empty() {
            self.clear_status();
        } else {
            self.set_error(startup_errors.join(" | "));
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

        self.set_editor_content(DiaCore::default_document_content());
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
        let suggested = self.core.borrow().suggested_export_name();

        let Some(path) = self.choose_export_path(&suggested) else {
            return;
        };

        let final_path = DiaCore::ensure_export_extension(&path);
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
        let suggested = self.core.borrow().suggested_document_name();

        let Some(path) = self.choose_save_path(&suggested) else {
            return;
        };

        let final_path = DiaCore::ensure_document_extension(&path);
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

        let mut insert_iter = self.buffer.iter_at_mark(&insert_mark);
        let insert_text = auto_indent_insertion(&prefix);
        self.buffer.insert(&mut insert_iter, &insert_text);
        true
    }

    fn handle_theme_changed(&self, theme_id: &str) {
        let normalized_theme_id = DiaCore::normalize_theme_id(theme_id).to_string();
        if *self.selected_theme_id.borrow() == normalized_theme_id {
            return;
        }

        let Some(preview_theme) =
            preview_theme_for_id(&self.available_themes, &normalized_theme_id)
        else {
            self.set_error(format!(
                "theme '{}' is unavailable in the shared catalog",
                normalized_theme_id
            ));
            return;
        };

        self.selected_theme_id.replace(normalized_theme_id.clone());
        self.preview_theme.replace(preview_theme);
        self.schedule_render();

        if let Err(err) = save_theme_preference(&normalized_theme_id) {
            self.set_error(format!("failed to save theme preference: {err}"));
        }
    }

    fn schedule_render(&self) {
        cancel_timer(&self.render_timer);

        let source = self.buffer_text();
        let preview = self.preview.clone();
        let base_uri = self.preview_base_uri.clone();
        let preview_theme = self.preview_theme.borrow().clone();
        let source_id = gtk::glib::timeout_add_local(Duration::from_millis(250), move || {
            preview.load_html(&diagram_html(&source, &preview_theme), Some(&base_uri));
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
            (core.display_name(), core.is_dirty())
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
    let config_root = config_root()?;
    Ok(config_root.join("dia").join("recent-files.json"))
}

fn preferences_path() -> Result<PathBuf, String> {
    let config_root = config_root()?;
    Ok(config_root.join("dia").join("preferences.json"))
}

fn config_root() -> Result<PathBuf, String> {
    let Some(config_root) = dirs::config_dir() else {
        return Err("could not resolve user config directory".to_string());
    };
    Ok(config_root)
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

fn diagram_html(source: &str, preview_theme: &PreviewTheme) -> String {
    let source_json = match serde_json::to_string(source) {
        Ok(value) => value,
        Err(err) => {
            let escaped = html_escape(&format!("failed to encode source: {err}"));
            return format!(
                "<!doctype html><html><body style='background:{}'><pre style='color:{}'>{escaped}</pre></body></html>",
                preview_theme.info.preview_background,
                preview_theme.info.error_color,
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
        background: {};
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
        color: {};
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
      mermaid.initialize({});

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
    "#,
        preview_theme.info.preview_background,
        preview_theme.info.error_color,
        preview_theme.mermaid_config_js
    )
}

fn load_theme_setup() -> ThemeSetup {
    let theme_id = DiaCore::normalize_theme_id(DiaCore::default_theme_id()).to_string();
    let mut startup_errors = Vec::new();

    let themes = match load_theme_catalog() {
        Ok(value) => value,
        Err(err) => {
            startup_errors.push(err);
            vec![fallback_theme_info(&theme_id)]
        }
    };

    let saved_theme_id = match load_theme_preference() {
        Ok(value) => value,
        Err(err) => {
            startup_errors.push(err);
            None
        }
    };

    let preferred_theme_id = saved_theme_id.unwrap_or_else(|| theme_id.clone());
    let normalized_theme_id = DiaCore::normalize_theme_id(&preferred_theme_id).to_string();
    let selected_theme_id = if themes.iter().any(|theme| theme.id == normalized_theme_id) {
        normalized_theme_id
    } else {
        startup_errors.push(format!(
            "shared theme catalog is missing theme '{}'",
            normalized_theme_id
        ));
        theme_id
    };

    let preview_theme = preview_theme_for_id(&themes, &selected_theme_id).unwrap_or_else(|| {
        startup_errors.push(format!(
            "failed to build preview theme for '{}'",
            selected_theme_id
        ));
        PreviewTheme {
            info: fallback_theme_info(&selected_theme_id),
            mermaid_config_js: DiaCore::mermaid_config_js(&selected_theme_id),
        }
    });

    ThemeSetup {
        themes,
        selected_theme_id,
        preview_theme,
        startup_errors,
    }
}

fn load_theme_catalog() -> Result<Vec<MermaidThemeInfo>, String> {
    let catalog = DiaCore::mermaid_theme_catalog_json()
        .map_err(|err| format!("failed to load shared theme catalog: {err}"))?;

    let themes: Vec<MermaidThemeInfo> = serde_json::from_str(&catalog)
        .map_err(|err| format!("failed to decode shared theme catalog: {err}"))?;

    if themes.is_empty() {
        return Err("shared theme catalog is empty".to_string());
    }

    Ok(themes)
}

fn load_theme_preference() -> Result<Option<String>, String> {
    let path = preferences_path()?;
    let data = match fs::read_to_string(&path) {
        Ok(value) => value,
        Err(source) if source.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(source) => {
            return Err(format!("failed to read {}: {}", path.display(), source));
        }
    };

    let preferences: AppPreferences = serde_json::from_str(&data)
        .map_err(|err| format!("failed to parse {}: {}", path.display(), err))?;

    if preferences.default_theme_id.trim().is_empty() {
        return Ok(None);
    }

    Ok(Some(preferences.default_theme_id))
}

fn save_theme_preference(theme_id: &str) -> Result<(), String> {
    let path = preferences_path()?;
    let Some(parent) = path.parent() else {
        return Err(format!(
            "failed to resolve parent directory for {}",
            path.display()
        ));
    };

    fs::create_dir_all(parent)
        .map_err(|err| format!("failed to create directory {}: {}", parent.display(), err))?;

    let preferences = AppPreferences {
        default_theme_id: theme_id.to_string(),
    };
    let mut encoded = serde_json::to_string_pretty(&preferences)
        .map_err(|err| format!("failed to encode theme preferences: {err}"))?;
    encoded.push('\n');

    fs::write(&path, encoded).map_err(|err| format!("failed to write {}: {}", path.display(), err))
}

fn preview_theme_for_id(themes: &[MermaidThemeInfo], theme_id: &str) -> Option<PreviewTheme> {
    let info = themes.iter().find(|theme| theme.id == theme_id)?.clone();
    Some(PreviewTheme {
        info,
        mermaid_config_js: DiaCore::mermaid_config_js(theme_id),
    })
}

fn fallback_theme_info(theme_id: &str) -> MermaidThemeInfo {
    MermaidThemeInfo {
        id: theme_id.to_string(),
        label: "Default".to_string(),
        preview_background: "#ffffff".to_string(),
        error_color: "#b91c1c".to_string(),
    }
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
    use super::{preview_theme_for_id, should_handle_auto_indent, MermaidThemeInfo};
    use gtk4 as gtk;

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

    #[test]
    fn builds_preview_theme_from_shared_theme_info() {
        let themes = vec![MermaidThemeInfo {
            id: "forest".to_string(),
            label: "Forest".to_string(),
            preview_background: "#ffffff".to_string(),
            error_color: "#b91c1c".to_string(),
        }];

        let preview_theme = preview_theme_for_id(&themes, "forest")
            .expect("preview theme should exist for catalog id");

        assert_eq!(preview_theme.info.id, "forest");
        assert!(preview_theme
            .mermaid_config_js
            .contains("theme: \"forest\""));
    }
}
