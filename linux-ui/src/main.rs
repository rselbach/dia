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
const DEFAULT_EDITOR_FONT_SIZE: f64 = 14.0;
const MIN_EDITOR_FONT_SIZE: f64 = 10.0;
const MAX_EDITOR_FONT_SIZE: f64 = 24.0;

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

#[derive(Clone)]
struct EditorFontOption {
    family: String,
    label: String,
}

#[derive(Clone)]
struct AppPreferences {
    default_theme_id: String,
    editor_font_name: String,
    editor_font_size: f64,
}

#[derive(Default, Deserialize, Serialize)]
struct StoredAppPreferences {
    #[serde(rename = "defaultTheme")]
    #[serde(default)]
    default_theme_id: String,
    #[serde(rename = "editorFontName")]
    #[serde(default)]
    editor_font_name: String,
    #[serde(rename = "editorFontSize")]
    editor_font_size: Option<f64>,
}

struct AppSetup {
    themes: Vec<MermaidThemeInfo>,
    fonts: Vec<EditorFontOption>,
    preferences: AppPreferences,
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
    editor: gtk::TextView,
    editor_css_provider: gtk::CssProvider,
    preview: WebView,
    status: gtk::Label,
    preview_base_uri: String,
    available_themes: Vec<MermaidThemeInfo>,
    available_fonts: Vec<EditorFontOption>,
    preferences: RefCell<AppPreferences>,
    preview_theme: RefCell<PreviewTheme>,
    startup_errors: Vec<String>,
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
        let preferences_button = gtk::Button::with_label("Preferences");
        toolbar.append(&new_button);
        toolbar.append(&open_button);
        toolbar.append(&open_recent_button);
        toolbar.append(&export_png_button);
        toolbar.append(&save_button);
        toolbar.append(&save_as_button);
        toolbar.append(&preferences_button);

        let paned = gtk::Paned::new(gtk::Orientation::Horizontal);
        paned.set_wide_handle(true);
        paned.set_position(480);

        let text_buffer = gtk::TextBuffer::new(None::<&gtk::TextTagTable>);
        install_editor_tags(&text_buffer);
        text_buffer.set_text(DiaCore::default_document_content());

        let editor = gtk::TextView::with_buffer(&text_buffer);
        editor.set_widget_name("diagram-editor");
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

        let app_setup = load_app_setup(&editor);
        let editor_css_provider = gtk::CssProvider::new();
        if let Some(display) = gtk::gdk::Display::default() {
            gtk::style_context_add_provider_for_display(
                &display,
                &editor_css_provider,
                gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
            );
        }

        root.append(&toolbar);
        root.append(&paned);
        root.append(&status);

        window.set_child(Some(&root));

        let state = Rc::new(Self {
            core: RefCell::new(DiaCore::new(10)),
            window,
            buffer: text_buffer,
            editor: editor.clone(),
            editor_css_provider,
            preview,
            status,
            preview_base_uri: mermaid_vendor_base_uri(),
            available_themes: app_setup.themes,
            available_fonts: app_setup.fonts,
            preferences: RefCell::new(app_setup.preferences),
            preview_theme: RefCell::new(app_setup.preview_theme),
            startup_errors: app_setup.startup_errors,
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
            preferences_button.connect_clicked(move |_| {
                ui.handle_preferences();
            });
        }

        state.apply_editor_preferences();

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

        startup_errors.extend(self.startup_errors.iter().cloned());

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

    fn handle_preferences(&self) {
        let current = self.preferences.borrow().clone();

        let dialog = gtk::Dialog::builder()
            .title("Preferences")
            .transient_for(&self.window)
            .modal(true)
            .build();
        dialog.add_button("Cancel", gtk::ResponseType::Cancel);
        dialog.add_button("Save", gtk::ResponseType::Accept);
        dialog.set_default_response(gtk::ResponseType::Accept);

        let content = dialog.content_area();
        let grid = gtk::Grid::builder()
            .column_spacing(12)
            .row_spacing(12)
            .margin_top(16)
            .margin_bottom(16)
            .margin_start(16)
            .margin_end(16)
            .build();

        let font_label = gtk::Label::new(Some("Editor Font"));
        font_label.set_xalign(0.0);
        let font_combo = gtk::ComboBoxText::new();
        font_combo.set_hexpand(true);
        for option in &self.available_fonts {
            font_combo.append(Some(&option.family), &option.label);
        }
        font_combo.set_active_id(Some(&current.editor_font_name));

        let size_label = gtk::Label::new(Some("Font Size"));
        size_label.set_xalign(0.0);
        let size_adjustment = gtk::Adjustment::new(
            current.editor_font_size,
            MIN_EDITOR_FONT_SIZE,
            MAX_EDITOR_FONT_SIZE,
            1.0,
            2.0,
            0.0,
        );
        let size_spin = gtk::SpinButton::new(Some(&size_adjustment), 1.0, 0);
        size_spin.set_hexpand(true);

        let theme_label = gtk::Label::new(Some("Default Theme"));
        theme_label.set_xalign(0.0);
        let theme_combo = gtk::ComboBoxText::new();
        theme_combo.set_hexpand(true);
        for theme in &self.available_themes {
            theme_combo.append(Some(&theme.id), &theme.label);
        }
        theme_combo.set_active_id(Some(&current.default_theme_id));

        grid.attach(&font_label, 0, 0, 1, 1);
        grid.attach(&font_combo, 1, 0, 1, 1);
        grid.attach(&size_label, 0, 1, 1, 1);
        grid.attach(&size_spin, 1, 1, 1, 1);
        grid.attach(&theme_label, 0, 2, 1, 1);
        grid.attach(&theme_combo, 1, 2, 1, 1);
        content.append(&grid);

        let response = gtk::glib::MainContext::default().block_on(dialog.run_future());
        if response == gtk::ResponseType::Accept {
            let next = AppPreferences {
                default_theme_id: theme_combo
                    .active_id()
                    .map(|value| value.to_string())
                    .unwrap_or_else(|| current.default_theme_id.clone()),
                editor_font_name: font_combo
                    .active_id()
                    .map(|value| value.to_string())
                    .unwrap_or_else(|| current.editor_font_name.clone()),
                editor_font_size: size_spin.value(),
            };
            self.apply_preferences(next);
        }

        dialog.close();
    }

    fn apply_preferences(&self, next: AppPreferences) {
        let normalized_theme_id = DiaCore::normalize_theme_id(&next.default_theme_id).to_string();
        let resolved_font_name =
            resolve_editor_font_name(&self.available_fonts, &next.editor_font_name);
        let resolved_font_size = clamp_editor_font_size(next.editor_font_size);

        let current = self.preferences.borrow().clone();
        let theme_changed = current.default_theme_id != normalized_theme_id;

        if theme_changed {
            let Some(preview_theme) =
                preview_theme_for_id(&self.available_themes, &normalized_theme_id)
            else {
                self.set_error(format!(
                    "theme '{}' is unavailable in the shared catalog",
                    normalized_theme_id
                ));
                return;
            };
            self.preview_theme.replace(preview_theme);
        }

        let resolved = AppPreferences {
            default_theme_id: normalized_theme_id,
            editor_font_name: resolved_font_name,
            editor_font_size: resolved_font_size,
        };

        self.preferences.replace(resolved.clone());
        self.apply_editor_preferences();

        if theme_changed {
            self.schedule_render();
        }

        if let Err(err) = save_preferences(&resolved) {
            self.set_error(format!("failed to save preferences: {err}"));
            return;
        }

        self.clear_status();
    }

    fn apply_editor_preferences(&self) {
        let preferences = self.preferences.borrow();
        self.editor_css_provider.load_from_data(&build_editor_css(
            &preferences.editor_font_name,
            preferences.editor_font_size,
        ));
        self.editor.queue_draw();
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

fn clamp_editor_font_size(size: f64) -> f64 {
    size.clamp(MIN_EDITOR_FONT_SIZE, MAX_EDITOR_FONT_SIZE)
}

fn resolve_editor_font_name(options: &[EditorFontOption], font_name: &str) -> String {
    let trimmed = font_name.trim();
    if let Some(option) = options
        .iter()
        .find(|option| option.family.eq_ignore_ascii_case(trimmed))
    {
        return option.family.clone();
    }

    default_editor_font_name(options)
}

fn default_editor_font_name(options: &[EditorFontOption]) -> String {
    options
        .first()
        .map(|option| option.family.clone())
        .unwrap_or_else(|| "Monospace".to_string())
}

fn load_editor_font_options(editor: &gtk::TextView) -> Vec<EditorFontOption> {
    let mut families = editor
        .pango_context()
        .list_families()
        .into_iter()
        .filter(|family| family.is_monospace())
        .map(|family| family.name().to_string())
        .collect::<Vec<_>>();
    families.sort();
    families.dedup();

    let mut options = vec![EditorFontOption {
        family: "monospace".to_string(),
        label: "System Monospace".to_string(),
    }];
    for family in families {
        if family.eq_ignore_ascii_case("monospace") {
            continue;
        }

        options.push(EditorFontOption {
            family: family.clone(),
            label: family,
        });
    }

    options
}

fn build_editor_css(font_name: &str, font_size: f64) -> String {
    let font_family = css_font_family_value(font_name);
    let clamped_font_size = clamp_editor_font_size(font_size);
    format!(
        r#"
textview#diagram-editor,
textview#diagram-editor text {{
  font-family: {};
  font-size: {}pt;
}}
"#,
        font_family, clamped_font_size
    )
}

fn escape_css_string(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

fn css_font_family_value(value: &str) -> String {
    if value.eq_ignore_ascii_case("monospace") {
        return "monospace".to_string();
    }

    format!("\"{}\"", escape_css_string(value))
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
      #diagram {{
        width: 100%;
        height: 100%;
        min-width: 0;
        min-height: 0;
        display: flex;
        align-items: center;
        justify-content: center;
        overflow: hidden;
        touch-action: none;
        cursor: grab;
        user-select: none;
        -webkit-user-select: none;
      }}
      #diagram.is-panning {{
        cursor: grabbing;
      }}
      #diagram .pan-inner {{
        width: 100%;
        height: 100%;
        display: flex;
        align-items: center;
        justify-content: center;
      }}
      #diagram .zoom-inner {{
        width: 100%;
        height: 100%;
        display: flex;
        align-items: center;
        justify-content: center;
      }}
      #diagram .zoom-inner svg {{
        width: 100%;
        height: 100%;
        max-width: 100%;
        max-height: 100%;
        user-select: none;
        -webkit-user-select: none;
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
      const zoomInnerClass = "zoom-inner";
      const panInnerClass = "pan-inner";
      const zoomMin = 0.25;
      const zoomMax = 4;
      let zoomLevel = 1;
      let panX = 0;
      let panY = 0;

      function hasRenderedSVG() {{
        return diagramEl.querySelector("svg") !== null;
      }}

      function applyPan() {{
        const panInner = diagramEl.querySelector(`.${{panInnerClass}}`);
        if (!panInner) return;
        panInner.style.transform = `translate(${{panX}}px, ${{panY}}px)`;
      }}

      function panBounds(level) {{
        const zoom = Number.isFinite(level) ? level : zoomLevel;
        const width = diagramEl ? diagramEl.clientWidth : 0;
        const height = diagramEl ? diagramEl.clientHeight : 0;
        const maxX = Math.max(0, ((width * zoom) - width) / 2);
        const maxY = Math.max(0, ((height * zoom) - height) / 2);
        return {{ maxX, maxY }};
      }}

      function clampPan(x, y, level) {{
        const bounds = panBounds(level);
        return {{
          x: Math.max(-bounds.maxX, Math.min(bounds.maxX, x)),
          y: Math.max(-bounds.maxY, Math.min(bounds.maxY, y)),
        }};
      }}

      window.setPan = function(x, y) {{
        const clamped = clampPan(x, y, zoomLevel);
        panX = clamped.x;
        panY = clamped.y;
        applyPan();
        return {{ x: panX, y: panY }};
      }};

      function applyZoom() {{
        const zoomInner = diagramEl.querySelector(`.${{zoomInnerClass}}`);
        if (!zoomInner) return;
        zoomInner.style.transform = `scale(${{zoomLevel}})`;
        zoomInner.style.transformOrigin = "center center";
      }}

      window.setZoom = function(level) {{
        const newZoom = Math.min(zoomMax, Math.max(zoomMin, level));
        const clamped = clampPan(panX, panY, newZoom);
        panX = clamped.x;
        panY = clamped.y;
        zoomLevel = newZoom;
        applyPan();
        applyZoom();
        return zoomLevel;
      }};

      window.zoomIn = function() {{
        return window.setZoom(Math.round((zoomLevel + 0.1) * 100) / 100);
      }};

      window.zoomOut = function() {{
        return window.setZoom(Math.round((zoomLevel - 0.1) * 100) / 100);
      }};

      window.resetZoom = function() {{
        return window.setZoom(1);
      }};

      function bindInteractions() {{
        if (diagramEl.dataset.interactionsBound === "1") return;
        diagramEl.dataset.interactionsBound = "1";

        let isPanning = false;
        let activePointerId = null;
        let lastX = 0;
        let lastY = 0;
        let gestureStartZoom = 1;

        diagramEl.addEventListener("pointerdown", (event) => {{
          if (event.button !== 0 || !hasRenderedSVG() || zoomLevel <= 1) return;
          isPanning = true;
          activePointerId = event.pointerId;
          lastX = event.clientX;
          lastY = event.clientY;
          diagramEl.classList.add("is-panning");
          diagramEl.setPointerCapture(event.pointerId);
          event.preventDefault();
        }});

        diagramEl.addEventListener("pointermove", (event) => {{
          if (!isPanning || event.pointerId !== activePointerId) return;
          const dx = event.clientX - lastX;
          const dy = event.clientY - lastY;
          lastX = event.clientX;
          lastY = event.clientY;
          window.setPan(panX + dx, panY + dy);
          event.preventDefault();
        }});

        function stopPanning(event) {{
          if (!isPanning) return;
          if (activePointerId !== null && event.pointerId !== activePointerId) return;
          isPanning = false;
          activePointerId = null;
          diagramEl.classList.remove("is-panning");
        }}

        diagramEl.addEventListener("pointerup", stopPanning);
        diagramEl.addEventListener("pointercancel", stopPanning);
        diagramEl.addEventListener("lostpointercapture", stopPanning);

        diagramEl.addEventListener("wheel", (event) => {{
          if (!hasRenderedSVG()) return;
          event.preventDefault();
          const delta = event.deltaY === 0 ? event.deltaX : event.deltaY;
          if (delta === 0) return;
          const scaleFactor = Math.exp(-delta * 0.002);
          window.setZoom(zoomLevel * scaleFactor);
        }}, {{ passive: false }});

        document.addEventListener("gesturestart", (event) => {{
          gestureStartZoom = zoomLevel;
          event.preventDefault();
        }}, {{ passive: false }});

        document.addEventListener("gesturechange", (event) => {{
          event.preventDefault();
          window.setZoom(gestureStartZoom * event.scale);
        }}, {{ passive: false }});
      }}

      if (typeof mermaid === "undefined") {{
        errorEl.textContent = "failed to load local Mermaid bundle";
      }} else {{
      mermaid.initialize({});
      bindInteractions();

      if (!source.trim()) {{
        diagramEl.innerHTML = "";
        panX = 0;
        panY = 0;
        errorEl.textContent = "";
      }} else {{
        mermaid.render("dia-preview", source)
          .then((result) => {{
            diagramEl.innerHTML = `<div class="${{panInnerClass}}"><div class="${{zoomInnerClass}}">${{result.svg}}</div></div>`;
            const svg = diagramEl.querySelector(`.${{zoomInnerClass}} svg`);
            if (svg) {{
              const padding = 16;
              const bbox = svg.getBBox();
              if (bbox.width > 0 && bbox.height > 0) {{
                const minX = bbox.x - padding;
                const minY = bbox.y - padding;
                const width = bbox.width + (padding * 2);
                const height = bbox.height + (padding * 2);
                svg.setAttribute("viewBox", `${{minX}} ${{minY}} ${{width}} ${{height}}`);
              }}

              svg.setAttribute("width", "100%");
              svg.setAttribute("height", "100%");
              svg.setAttribute("preserveAspectRatio", "xMidYMid meet");
              svg.style.display = "block";
              svg.style.maxWidth = "100%";
              svg.style.maxHeight = "100%";
            }}
            window.setPan(panX, panY);
            applyZoom();
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

fn load_app_setup(editor: &gtk::TextView) -> AppSetup {
    let theme_id = DiaCore::normalize_theme_id(DiaCore::default_theme_id()).to_string();
    let mut startup_errors = Vec::new();
    let fonts = load_editor_font_options(editor);
    let fallback_font_name = default_editor_font_name(&fonts);

    let themes = match load_theme_catalog() {
        Ok(value) => value,
        Err(err) => {
            startup_errors.push(err);
            vec![fallback_theme_info(&theme_id)]
        }
    };

    let stored_preferences = match load_stored_preferences() {
        Ok(value) => value.unwrap_or_default(),
        Err(err) => {
            startup_errors.push(err);
            StoredAppPreferences::default()
        }
    };

    let preferred_theme_id = if stored_preferences.default_theme_id.trim().is_empty() {
        theme_id.clone()
    } else {
        stored_preferences.default_theme_id
    };
    let normalized_theme_id = DiaCore::normalize_theme_id(&preferred_theme_id).to_string();
    let default_theme_id = if themes.iter().any(|theme| theme.id == normalized_theme_id) {
        normalized_theme_id
    } else {
        startup_errors.push(format!(
            "shared theme catalog is missing theme '{}'",
            normalized_theme_id
        ));
        theme_id
    };

    let resolved_stored_font_name =
        resolve_editor_font_name(&fonts, &stored_preferences.editor_font_name);
    let editor_font_name = if stored_preferences.editor_font_name.trim().is_empty() {
        fallback_font_name.clone()
    } else if resolved_stored_font_name != fallback_font_name
        || stored_preferences
            .editor_font_name
            .eq_ignore_ascii_case(&fallback_font_name)
    {
        resolved_stored_font_name
    } else {
        startup_errors.push(format!(
            "saved editor font '{}' is unavailable; using '{}'",
            stored_preferences.editor_font_name, fallback_font_name
        ));
        fallback_font_name.clone()
    };

    let editor_font_size = clamp_editor_font_size(
        stored_preferences
            .editor_font_size
            .unwrap_or(DEFAULT_EDITOR_FONT_SIZE),
    );

    let preferences = AppPreferences {
        default_theme_id: default_theme_id.clone(),
        editor_font_name,
        editor_font_size,
    };

    let preview_theme = preview_theme_for_id(&themes, &preferences.default_theme_id)
        .unwrap_or_else(|| {
            startup_errors.push(format!(
                "failed to build preview theme for '{}'",
                preferences.default_theme_id
            ));
            PreviewTheme {
                info: fallback_theme_info(&preferences.default_theme_id),
                mermaid_config_js: DiaCore::mermaid_config_js(&preferences.default_theme_id),
            }
        });

    AppSetup {
        themes,
        fonts,
        preferences,
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

fn load_stored_preferences() -> Result<Option<StoredAppPreferences>, String> {
    let path = preferences_path()?;
    let data = match fs::read_to_string(&path) {
        Ok(value) => value,
        Err(source) if source.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(source) => {
            return Err(format!("failed to read {}: {}", path.display(), source));
        }
    };

    let preferences: StoredAppPreferences = serde_json::from_str(&data)
        .map_err(|err| format!("failed to parse {}: {}", path.display(), err))?;

    Ok(Some(preferences))
}

fn save_preferences(preferences: &AppPreferences) -> Result<(), String> {
    let path = preferences_path()?;
    let Some(parent) = path.parent() else {
        return Err(format!(
            "failed to resolve parent directory for {}",
            path.display()
        ));
    };

    fs::create_dir_all(parent)
        .map_err(|err| format!("failed to create directory {}: {}", parent.display(), err))?;

    let stored_preferences = StoredAppPreferences {
        default_theme_id: preferences.default_theme_id.clone(),
        editor_font_name: preferences.editor_font_name.clone(),
        editor_font_size: Some(clamp_editor_font_size(preferences.editor_font_size)),
    };
    let mut encoded = serde_json::to_string_pretty(&stored_preferences)
        .map_err(|err| format!("failed to encode preferences: {err}"))?;
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
    use super::{
        build_editor_css, diagram_html, preview_theme_for_id, should_handle_auto_indent,
        MermaidThemeInfo, PreviewTheme,
    };
    use dia_core::DiaCore;
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

    #[test]
    fn preview_html_sizes_svg_to_fill_preview_pane() {
        let preview_theme = PreviewTheme {
            info: MermaidThemeInfo {
                id: "default".to_string(),
                label: "Default".to_string(),
                preview_background: "#ffffff".to_string(),
                error_color: "#b91c1c".to_string(),
            },
            mermaid_config_js: DiaCore::mermaid_config_js("default"),
        };

        let html = diagram_html("flowchart TD\nA-->B\n", &preview_theme);

        assert!(html.contains("#diagram {"));
        assert!(html.contains("width: 100%;"));
        assert!(html.contains("height: 100%;"));
        assert!(html.contains("max-width: 100%;"));
        assert!(html.contains("max-height: 100%;"));
        assert!(html.contains("svg.setAttribute(\"width\", \"100%\")"));
        assert!(html.contains("svg.setAttribute(\"height\", \"100%\")"));
        assert!(html.contains("svg.setAttribute(\"preserveAspectRatio\", \"xMidYMid meet\")"));
        assert!(html.contains("const zoomMin = 0.25;"));
        assert!(html.contains("window.setZoom = function(level)"));
        assert!(html.contains("window.setPan = function(x, y)"));
        assert!(html.contains("diagramEl.addEventListener(\"wheel\""));
        assert!(html.contains("diagramEl.addEventListener(\"pointerdown\""));
        assert!(html.contains("zoomInnerClass"));
        assert!(html.contains("panInnerClass"));
    }

    #[test]
    fn editor_css_uses_selected_font_and_size() {
        let css = build_editor_css("JetBrains Mono", 18.0);

        assert!(css.contains("textview#diagram-editor"));
        assert!(css.contains("font-family: \"JetBrains Mono\";"));
        assert!(css.contains("font-size: 18pt;"));
    }
}
