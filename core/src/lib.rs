use std::ffi::{CStr, CString};
use std::fs;
use std::os::raw::c_char;
use std::panic::{catch_unwind, UnwindSafe};
use std::path::{Path, PathBuf};

use dia_syntax::{auto_indent_insertion as syntax_auto_indent_insertion, highlight_spans};

const DEFAULT_MAX_RECENT_FILES: usize = 10;
const DEFAULT_DOCUMENT_CONTENT: &str = "\
sequenceDiagram
    participant Jeff
    participant Abed
    participant StarBurns
    participant Dean
    participant StudyGroup as Study Group

    Jeff->>Abed: We need chicken fingers
    Abed->>Abed: Becomes fry cook
    Note over Abed: Controls the supply
    
    Abed->>StarBurns: You handle distribution
    StarBurns->>StudyGroup: Chicken fingers... for a price
    StudyGroup->>StarBurns: Bribes & favors
    StarBurns->>Abed: Reports tribute
    
    Jeff->>Abed: I need extra fingers for a date
    Abed-->>Jeff: You'll wait like everyone else
    Jeff->>Jeff: What have we created?
    
    Dean->>Abed: Why is everyone so happy?
    Abed-->>Dean: Efficient cafeteria management
    Dean->>Dean: Something's not right...
    
    StudyGroup->>Jeff: This has gone too far
    Jeff->>Abed: We have to shut it down
    Abed->>Abed: Destroys the fryer
    Note over Abed: The empire crumbles\
";
const DEFAULT_DOCUMENT_NAME: &str = "diagram.mmd";
const DEFAULT_EXPORT_NAME: &str = "diagram.png";
const DEFAULT_THEME_ID: &str = "default";

struct MermaidThemeDef {
    id: &'static str,
    label: &'static str,
    preview_background: &'static str,
    error_color: &'static str,
    theme_variables: Option<&'static [(&'static str, &'static str)]>,
}

const CATPPUCCIN_VARS: &[(&str, &str)] = &[
    ("primaryColor", "#89b4fa"),
    ("primaryBorderColor", "#74c7ec"),
    ("secondaryColor", "#cba6f7"),
    ("secondaryBorderColor", "#b4befe"),
    ("tertiaryColor", "#a6e3a1"),
    ("tertiaryBorderColor", "#94e2d5"),
    ("lineColor", "#bac2de"),
    ("textColor", "#cdd6f4"),
];
const DRACULA_VARS: &[(&str, &str)] = &[
    ("primaryColor", "#bd93f9"),
    ("primaryBorderColor", "#6272a4"),
    ("secondaryColor", "#ff79c6"),
    ("secondaryBorderColor", "#ff79c6"),
    ("tertiaryColor", "#50fa7b"),
    ("tertiaryBorderColor", "#50fa7b"),
    ("lineColor", "#f8f8f2"),
    ("textColor", "#f8f8f2"),
];
const NORD_VARS: &[(&str, &str)] = &[
    ("primaryColor", "#5e81ac"),
    ("primaryBorderColor", "#4c566a"),
    ("secondaryColor", "#a3be8c"),
    ("secondaryBorderColor", "#4c566a"),
    ("tertiaryColor", "#d08770"),
    ("tertiaryBorderColor", "#4c566a"),
    ("lineColor", "#4c566a"),
    ("textColor", "#2e3440"),
];
const SYNTHWAVE_VARS: &[(&str, &str)] = &[
    ("primaryColor", "#f72585"),
    ("primaryBorderColor", "#ff6ec7"),
    ("secondaryColor", "#7209b7"),
    ("secondaryBorderColor", "#b5179e"),
    ("tertiaryColor", "#4361ee"),
    ("tertiaryBorderColor", "#4cc9f0"),
    ("lineColor", "#ff6ec7"),
    ("textColor", "#f0e6ff"),
];
const ROSE_VARS: &[(&str, &str)] = &[
    ("primaryColor", "#e11d48"),
    ("primaryBorderColor", "#be123c"),
    ("secondaryColor", "#fb7185"),
    ("secondaryBorderColor", "#f43f5e"),
    ("tertiaryColor", "#fda4af"),
    ("tertiaryBorderColor", "#fb7185"),
    ("lineColor", "#881337"),
    ("textColor", "#4c0519"),
];
const OCEAN_VARS: &[(&str, &str)] = &[
    ("primaryColor", "#0077b6"),
    ("primaryBorderColor", "#023e8a"),
    ("secondaryColor", "#00b4d8"),
    ("secondaryBorderColor", "#0096c7"),
    ("tertiaryColor", "#48cae4"),
    ("tertiaryBorderColor", "#0096c7"),
    ("lineColor", "#03045e"),
    ("textColor", "#03045e"),
];
const SOLARIZED_VARS: &[(&str, &str)] = &[
    ("primaryColor", "#268bd2"),
    ("primaryBorderColor", "#2aa198"),
    ("secondaryColor", "#859900"),
    ("secondaryBorderColor", "#859900"),
    ("tertiaryColor", "#b58900"),
    ("tertiaryBorderColor", "#cb4b16"),
    ("lineColor", "#586e75"),
    ("textColor", "#657b83"),
];

const MERMAID_THEMES: &[MermaidThemeDef] = &[
    MermaidThemeDef {
        id: "default",
        label: "Default",
        preview_background: "#ffffff",
        error_color: "#b91c1c",
        theme_variables: None,
    },
    MermaidThemeDef {
        id: "dark",
        label: "Dark",
        preview_background: "#333333",
        error_color: "#f38ba8",
        theme_variables: None,
    },
    MermaidThemeDef {
        id: "forest",
        label: "Forest",
        preview_background: "#ffffff",
        error_color: "#b91c1c",
        theme_variables: None,
    },
    MermaidThemeDef {
        id: "neutral",
        label: "Neutral",
        preview_background: "#ffffff",
        error_color: "#b91c1c",
        theme_variables: None,
    },
    MermaidThemeDef {
        id: "catppuccin",
        label: "Catppuccin",
        preview_background: "#1e1e2e",
        error_color: "#f38ba8",
        theme_variables: Some(CATPPUCCIN_VARS),
    },
    MermaidThemeDef {
        id: "dracula",
        label: "Dracula",
        preview_background: "#282a36",
        error_color: "#f38ba8",
        theme_variables: Some(DRACULA_VARS),
    },
    MermaidThemeDef {
        id: "nord",
        label: "Nord",
        preview_background: "#eceff4",
        error_color: "#b91c1c",
        theme_variables: Some(NORD_VARS),
    },
    MermaidThemeDef {
        id: "synthwave",
        label: "Synthwave",
        preview_background: "#1a1a2e",
        error_color: "#f38ba8",
        theme_variables: Some(SYNTHWAVE_VARS),
    },
    MermaidThemeDef {
        id: "rose",
        label: "Rose",
        preview_background: "#fff1f2",
        error_color: "#b91c1c",
        theme_variables: Some(ROSE_VARS),
    },
    MermaidThemeDef {
        id: "ocean",
        label: "Ocean",
        preview_background: "#eaf8ff",
        error_color: "#b91c1c",
        theme_variables: Some(OCEAN_VARS),
    },
    MermaidThemeDef {
        id: "solarized",
        label: "Solarized",
        preview_background: "#fdf6e3",
        error_color: "#b91c1c",
        theme_variables: Some(SOLARIZED_VARS),
    },
];

const DIA_OK: i32 = 0;
const DIA_ERROR: i32 = 1;

#[repr(C)]
pub struct DiaResult {
    pub code: i32,
    pub value: *mut c_char,
    pub error: *mut c_char,
}

impl DiaResult {
    fn ok(value: String) -> Self {
        Self {
            code: DIA_OK,
            value: string_into_raw(value),
            error: std::ptr::null_mut(),
        }
    }

    fn ok_empty() -> Self {
        Self {
            code: DIA_OK,
            value: std::ptr::null_mut(),
            error: std::ptr::null_mut(),
        }
    }

    fn err(message: String) -> Self {
        Self {
            code: DIA_ERROR,
            value: std::ptr::null_mut(),
            error: string_into_raw(message),
        }
    }
}

#[derive(Debug)]
pub struct DiaCore {
    current_file: Option<PathBuf>,
    dirty: bool,
    recent_files: Vec<PathBuf>,
    max_recent_files: usize,
}

impl DiaCore {
    pub fn new(max_recent_files: usize) -> Self {
        let max = max_recent_files.max(1);
        Self {
            current_file: None,
            dirty: false,
            recent_files: Vec::new(),
            max_recent_files: max,
        }
    }

    pub fn open_file(&mut self, path: &Path) -> Result<String, CoreError> {
        let data = fs::read_to_string(path).map_err(|source| CoreError::Io {
            context: format!("failed to read {}", path.display()),
            source,
        })?;

        let normalized = normalize_path(path)?;
        self.current_file = Some(normalized.clone());
        self.dirty = false;
        self.add_recent_file(normalized);
        Ok(data)
    }

    pub fn new_document(&mut self) {
        self.current_file = None;
        self.dirty = false;
    }

    pub fn current_file_name(&self) -> Option<String> {
        self.current_file
            .as_ref()
            .and_then(|path| path.file_name())
            .and_then(|name| name.to_str())
            .map(str::to_owned)
    }

    pub fn display_name(&self) -> String {
        self.current_file_name()
            .filter(|name| !name.is_empty())
            .unwrap_or_else(|| "Untitled".to_string())
    }

    pub fn suggested_document_name(&self) -> String {
        self.current_file_name()
            .filter(|name| !name.is_empty())
            .unwrap_or_else(|| DEFAULT_DOCUMENT_NAME.to_string())
    }

    pub fn suggested_export_name(&self) -> String {
        self.current_file
            .as_ref()
            .and_then(|path| path.file_stem())
            .and_then(|name| name.to_str())
            .filter(|name| !name.is_empty())
            .map(|name| format!("{name}.png"))
            .unwrap_or_else(|| DEFAULT_EXPORT_NAME.to_string())
    }

    pub fn save(&mut self, content: &str) -> Result<PathBuf, CoreError> {
        let path = self
            .current_file
            .clone()
            .ok_or(CoreError::MissingCurrentFile)?;
        self.write_file(path, content)
    }

    pub fn save_as(&mut self, path: &Path, content: &str) -> Result<PathBuf, CoreError> {
        self.write_file(normalize_path(path)?, content)
    }

    fn write_file(&mut self, path: PathBuf, content: &str) -> Result<PathBuf, CoreError> {
        fs::write(&path, content).map_err(|source| CoreError::Io {
            context: format!("failed to write {}", path.display()),
            source,
        })?;

        self.current_file = Some(path.clone());
        self.dirty = false;
        self.add_recent_file(path.clone());
        Ok(path)
    }

    fn add_recent_file(&mut self, path: PathBuf) {
        let mut next = Vec::with_capacity(self.max_recent_files);
        next.push(path.clone());

        for existing in &self.recent_files {
            if *existing == path {
                continue;
            }

            next.push(existing.clone());
            if next.len() >= self.max_recent_files {
                break;
            }
        }

        self.recent_files = next;
    }

    pub fn set_dirty(&mut self, dirty: bool) {
        self.dirty = dirty;
    }

    pub fn is_dirty(&self) -> bool {
        self.dirty
    }

    pub fn current_file(&self) -> Option<&Path> {
        self.current_file.as_deref()
    }

    pub fn current_file_string(&self) -> String {
        match &self.current_file {
            Some(path) => path.to_string_lossy().to_string(),
            None => String::new(),
        }
    }

    pub fn recent_files(&self) -> &[PathBuf] {
        &self.recent_files
    }

    pub fn default_document_content() -> &'static str {
        DEFAULT_DOCUMENT_CONTENT
    }

    pub fn default_theme_id() -> &'static str {
        DEFAULT_THEME_ID
    }

    pub fn mermaid_theme_catalog_json() -> Result<String, CoreError> {
        let values: Vec<_> = MERMAID_THEMES
            .iter()
            .map(|theme| {
                serde_json::json!({
                    "id": theme.id,
                    "label": theme.label,
                    "previewBackground": theme.preview_background,
                    "errorColor": theme.error_color,
                })
            })
            .collect();
        serde_json::to_string(&values).map_err(CoreError::Json)
    }

    pub fn normalize_theme_id(theme_id: &str) -> &'static str {
        mermaid_theme(theme_id)
            .map(|theme| theme.id)
            .unwrap_or(DEFAULT_THEME_ID)
    }

    pub fn mermaid_config_js(theme_id: &str) -> String {
        let theme = mermaid_theme(theme_id).unwrap_or(&MERMAID_THEMES[0]);
        let mut parts = vec![
            "startOnLoad: false".to_string(),
            "securityLevel: \"strict\"".to_string(),
        ];

        if let Some(variables) = theme.theme_variables {
            parts.push("theme: \"base\"".to_string());
            let var_parts = variables
                .iter()
                .map(|(key, value)| format!("{key}: \"{value}\""))
                .collect::<Vec<_>>();
            parts.push(format!("themeVariables: {{ {} }}", var_parts.join(", ")));
        } else {
            parts.push(format!("theme: \"{}\"", theme.id));
        }

        format!("{{ {} }}", parts.join(", "))
    }

    pub fn mermaid_highlight_spans_json(source: &str) -> Result<String, CoreError> {
        let values: Vec<_> = highlight_spans(source)
            .into_iter()
            .map(|span| {
                let kind = match span.kind {
                    dia_syntax::HighlightKind::Keyword => "keyword",
                    dia_syntax::HighlightKind::Operator => "operator",
                    dia_syntax::HighlightKind::Comment => "comment",
                    dia_syntax::HighlightKind::Label => "label",
                };

                serde_json::json!({
                    "start": span.start,
                    "end": span.end,
                    "kind": kind,
                })
            })
            .collect();

        serde_json::to_string(&values).map_err(CoreError::Json)
    }

    pub fn auto_indent_insertion(prefix: &str) -> String {
        syntax_auto_indent_insertion(prefix)
    }

    pub fn ensure_document_extension(path: &Path) -> PathBuf {
        ensure_extension(path, "mmd")
    }

    pub fn ensure_export_extension(path: &Path) -> PathBuf {
        ensure_extension(path, "png")
    }

    pub fn recent_files_json(&self) -> Result<String, CoreError> {
        let values: Vec<String> = self
            .recent_files
            .iter()
            .map(|path| path.to_string_lossy().to_string())
            .collect();
        serde_json::to_string(&values).map_err(CoreError::Json)
    }

    pub fn save_recent_files(&self, path: &Path) -> Result<(), CoreError> {
        let path = normalize_path(path)?;
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|source| CoreError::Io {
                context: format!("failed to create directory {}", parent.display()),
                source,
            })?;
        }

        let values: Vec<String> = self
            .recent_files
            .iter()
            .map(|entry| entry.to_string_lossy().to_string())
            .collect();
        let mut encoded = serde_json::to_string_pretty(&values).map_err(CoreError::Json)?;
        encoded.push('\n');

        fs::write(&path, encoded).map_err(|source| CoreError::Io {
            context: format!("failed to write {}", path.display()),
            source,
        })?;

        Ok(())
    }

    pub fn load_recent_files(&mut self, path: &Path) -> Result<(), CoreError> {
        let path = normalize_path(path)?;
        let data = match fs::read_to_string(&path) {
            Ok(contents) => contents,
            Err(source) if source.kind() == std::io::ErrorKind::NotFound => {
                self.recent_files = Vec::new();
                return Ok(());
            }
            Err(source) => {
                return Err(CoreError::Io {
                    context: format!("failed to read {}", path.display()),
                    source,
                })
            }
        };

        let parsed: Vec<String> = serde_json::from_str(&data).map_err(CoreError::Json)?;

        let mut normalized = Vec::with_capacity(self.max_recent_files);
        for entry in parsed {
            let candidate = normalize_path(Path::new(&entry))?;
            if normalized.iter().any(|item| *item == candidate) {
                continue;
            }

            normalized.push(candidate);
            if normalized.len() >= self.max_recent_files {
                break;
            }
        }

        self.recent_files = normalized;
        Ok(())
    }
}

#[derive(Debug)]
pub enum CoreError {
    Io {
        context: String,
        source: std::io::Error,
    },
    Json(serde_json::Error),
    MissingCurrentFile,
    NullPointer(&'static str),
    InvalidUtf8(&'static str),
    Panic,
}

impl std::fmt::Display for CoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io { context, source } => write!(f, "{}: {}", context, source),
            Self::Json(source) => write!(f, "json error: {}", source),
            Self::MissingCurrentFile => write!(f, "no current file is set; use save_as first"),
            Self::NullPointer(name) => write!(f, "argument '{}' cannot be null", name),
            Self::InvalidUtf8(name) => write!(f, "argument '{}' must be valid UTF-8", name),
            Self::Panic => write!(f, "panic in Rust core library"),
        }
    }
}

impl std::error::Error for CoreError {}

fn ffi_call<F>(func: F) -> DiaResult
where
    F: FnOnce() -> Result<DiaResult, CoreError> + UnwindSafe,
{
    match catch_unwind(func) {
        Ok(Ok(result)) => result,
        Ok(Err(err)) => DiaResult::err(err.to_string()),
        Err(_) => DiaResult::err(CoreError::Panic.to_string()),
    }
}

fn normalize_path(path: &Path) -> Result<PathBuf, CoreError> {
    if path.as_os_str().is_empty() {
        return Err(CoreError::InvalidUtf8("path"));
    }

    let candidate = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .map_err(|source| CoreError::Io {
                context: "failed to resolve current directory".to_string(),
                source,
            })?
            .join(path)
    };

    Ok(candidate)
}

fn ensure_extension(path: &Path, ext: &str) -> PathBuf {
    let mut next = path.to_path_buf();
    if next.extension().is_none() {
        next.set_extension(ext);
    }
    next
}

fn mermaid_theme(theme_id: &str) -> Option<&'static MermaidThemeDef> {
    MERMAID_THEMES.iter().find(|theme| theme.id == theme_id)
}

fn c_arg_to_string(value: *const c_char, name: &'static str) -> Result<String, CoreError> {
    if value.is_null() {
        return Err(CoreError::NullPointer(name));
    }

    let c_str = unsafe { CStr::from_ptr(value) };
    c_str
        .to_str()
        .map(str::to_owned)
        .map_err(|_| CoreError::InvalidUtf8(name))
}

fn c_arg_to_path(value: *const c_char, name: &'static str) -> Result<PathBuf, CoreError> {
    let text = c_arg_to_string(value, name)?;
    Ok(PathBuf::from(text))
}

fn string_into_raw(value: String) -> *mut c_char {
    CString::new(value)
        .unwrap_or_else(|_| {
            CString::new("internal error: string contains NUL").expect("valid literal")
        })
        .into_raw()
}

#[no_mangle]
pub extern "C" fn dia_core_new(max_recent_files: u32) -> *mut DiaCore {
    let max = if max_recent_files == 0 {
        DEFAULT_MAX_RECENT_FILES
    } else {
        max_recent_files as usize
    };
    Box::into_raw(Box::new(DiaCore::new(max)))
}

#[no_mangle]
pub extern "C" fn dia_core_free(core: *mut DiaCore) {
    if core.is_null() {
        return;
    }
    unsafe {
        drop(Box::from_raw(core));
    }
}

#[no_mangle]
pub extern "C" fn dia_string_free(value: *mut c_char) {
    if value.is_null() {
        return;
    }
    unsafe {
        drop(CString::from_raw(value));
    }
}

#[no_mangle]
pub extern "C" fn dia_core_open_file(core: *mut DiaCore, path: *const c_char) -> DiaResult {
    ffi_call(|| {
        let path = c_arg_to_path(path, "path")?;
        let core = unsafe { core.as_mut() }.ok_or(CoreError::NullPointer("core"))?;
        let content = core.open_file(&path)?;
        Ok(DiaResult::ok(content))
    })
}

#[no_mangle]
pub extern "C" fn dia_core_new_document(core: *mut DiaCore) -> DiaResult {
    ffi_call(|| {
        let core = unsafe { core.as_mut() }.ok_or(CoreError::NullPointer("core"))?;
        core.new_document();
        Ok(DiaResult::ok_empty())
    })
}

#[no_mangle]
pub extern "C" fn dia_core_save(core: *mut DiaCore, content: *const c_char) -> DiaResult {
    ffi_call(|| {
        let content = c_arg_to_string(content, "content")?;
        let core = unsafe { core.as_mut() }.ok_or(CoreError::NullPointer("core"))?;
        let saved_path = core.save(&content)?;
        Ok(DiaResult::ok(saved_path.to_string_lossy().to_string()))
    })
}

#[no_mangle]
pub extern "C" fn dia_core_save_as(
    core: *mut DiaCore,
    path: *const c_char,
    content: *const c_char,
) -> DiaResult {
    ffi_call(|| {
        let path = c_arg_to_path(path, "path")?;
        let content = c_arg_to_string(content, "content")?;
        let core = unsafe { core.as_mut() }.ok_or(CoreError::NullPointer("core"))?;
        let saved_path = core.save_as(&path, &content)?;
        Ok(DiaResult::ok(saved_path.to_string_lossy().to_string()))
    })
}

#[no_mangle]
pub extern "C" fn dia_core_set_dirty(core: *mut DiaCore, dirty: i32) -> DiaResult {
    ffi_call(|| {
        let core = unsafe { core.as_mut() }.ok_or(CoreError::NullPointer("core"))?;
        core.set_dirty(dirty != 0);
        Ok(DiaResult::ok_empty())
    })
}

#[no_mangle]
pub extern "C" fn dia_core_is_dirty(core: *const DiaCore) -> i32 {
    let Some(core_ref) = (unsafe { core.as_ref() }) else {
        return -1;
    };
    if core_ref.is_dirty() {
        return 1;
    }
    0
}

#[no_mangle]
pub extern "C" fn dia_core_current_file(core: *const DiaCore) -> DiaResult {
    ffi_call(|| {
        let core = unsafe { core.as_ref() }.ok_or(CoreError::NullPointer("core"))?;
        Ok(DiaResult::ok(core.current_file_string()))
    })
}

#[no_mangle]
pub extern "C" fn dia_core_default_document_content() -> DiaResult {
    DiaResult::ok(DiaCore::default_document_content().to_string())
}

#[no_mangle]
pub extern "C" fn dia_core_default_theme_id() -> DiaResult {
    DiaResult::ok(DiaCore::default_theme_id().to_string())
}

#[no_mangle]
pub extern "C" fn dia_core_mermaid_theme_catalog_json() -> DiaResult {
    match DiaCore::mermaid_theme_catalog_json() {
        Ok(value) => DiaResult::ok(value),
        Err(err) => DiaResult::err(err.to_string()),
    }
}

#[no_mangle]
pub extern "C" fn dia_core_normalize_theme_id(theme_id: *const c_char) -> DiaResult {
    ffi_call(|| {
        let theme_id = c_arg_to_string(theme_id, "theme_id")?;
        Ok(DiaResult::ok(
            DiaCore::normalize_theme_id(&theme_id).to_string(),
        ))
    })
}

#[no_mangle]
pub extern "C" fn dia_core_mermaid_config_js(theme_id: *const c_char) -> DiaResult {
    ffi_call(|| {
        let theme_id = c_arg_to_string(theme_id, "theme_id")?;
        Ok(DiaResult::ok(DiaCore::mermaid_config_js(&theme_id)))
    })
}

#[no_mangle]
pub extern "C" fn dia_core_mermaid_highlight_spans_json(source: *const c_char) -> DiaResult {
    ffi_call(|| {
        let source = c_arg_to_string(source, "source")?;
        let value = DiaCore::mermaid_highlight_spans_json(&source)?;
        Ok(DiaResult::ok(value))
    })
}

#[no_mangle]
pub extern "C" fn dia_core_auto_indent_insertion(prefix: *const c_char) -> DiaResult {
    ffi_call(|| {
        let prefix = c_arg_to_string(prefix, "prefix")?;
        Ok(DiaResult::ok(DiaCore::auto_indent_insertion(&prefix)))
    })
}

#[no_mangle]
pub extern "C" fn dia_core_display_name(core: *const DiaCore) -> DiaResult {
    ffi_call(|| {
        let core = unsafe { core.as_ref() }.ok_or(CoreError::NullPointer("core"))?;
        Ok(DiaResult::ok(core.display_name()))
    })
}

#[no_mangle]
pub extern "C" fn dia_core_suggested_document_name(core: *const DiaCore) -> DiaResult {
    ffi_call(|| {
        let core = unsafe { core.as_ref() }.ok_or(CoreError::NullPointer("core"))?;
        Ok(DiaResult::ok(core.suggested_document_name()))
    })
}

#[no_mangle]
pub extern "C" fn dia_core_suggested_export_name(core: *const DiaCore) -> DiaResult {
    ffi_call(|| {
        let core = unsafe { core.as_ref() }.ok_or(CoreError::NullPointer("core"))?;
        Ok(DiaResult::ok(core.suggested_export_name()))
    })
}

#[no_mangle]
pub extern "C" fn dia_core_ensure_document_extension(path: *const c_char) -> DiaResult {
    ffi_call(|| {
        let path = c_arg_to_path(path, "path")?;
        let next = DiaCore::ensure_document_extension(&path);
        Ok(DiaResult::ok(next.to_string_lossy().to_string()))
    })
}

#[no_mangle]
pub extern "C" fn dia_core_ensure_export_extension(path: *const c_char) -> DiaResult {
    ffi_call(|| {
        let path = c_arg_to_path(path, "path")?;
        let next = DiaCore::ensure_export_extension(&path);
        Ok(DiaResult::ok(next.to_string_lossy().to_string()))
    })
}

#[no_mangle]
pub extern "C" fn dia_core_recent_files_json(core: *const DiaCore) -> DiaResult {
    ffi_call(|| {
        let core = unsafe { core.as_ref() }.ok_or(CoreError::NullPointer("core"))?;
        let value = core.recent_files_json()?;
        Ok(DiaResult::ok(value))
    })
}

#[no_mangle]
pub extern "C" fn dia_core_load_recent_files(core: *mut DiaCore, path: *const c_char) -> DiaResult {
    ffi_call(|| {
        let path = c_arg_to_path(path, "path")?;
        let core = unsafe { core.as_mut() }.ok_or(CoreError::NullPointer("core"))?;
        core.load_recent_files(&path)?;
        Ok(DiaResult::ok_empty())
    })
}

#[no_mangle]
pub extern "C" fn dia_core_save_recent_files(
    core: *const DiaCore,
    path: *const c_char,
) -> DiaResult {
    ffi_call(|| {
        let path = c_arg_to_path(path, "path")?;
        let core = unsafe { core.as_ref() }.ok_or(CoreError::NullPointer("core"))?;
        core.save_recent_files(&path)?;
        Ok(DiaResult::ok_empty())
    })
}

#[cfg(test)]
mod tests {
    use super::DiaCore;
    use std::fs;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn test_dir(name: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock should be after unix epoch")
            .as_nanos();
        let path = std::env::temp_dir().join(format!("dia_core_{}_{}", name, nanos));
        fs::create_dir_all(&path).expect("must create temp test directory");
        path
    }

    #[test]
    fn open_and_save_round_trip_tracks_recent_files() {
        let dir = test_dir("round_trip");
        let file_a = dir.join("diagram-a.mmd");
        let file_b = dir.join("diagram-b.mmd");
        fs::write(&file_a, "flowchart TD\nA-->B\n").expect("must write file_a");

        let mut core = DiaCore::new(10);
        let opened = core.open_file(&file_a).expect("open_file should succeed");
        assert_eq!(opened, "flowchart TD\nA-->B\n");
        assert!(!core.is_dirty());

        core.set_dirty(true);
        assert!(core.is_dirty());

        core.save_as(&file_b, "flowchart TD\nB-->C\n")
            .expect("save_as should succeed");

        let saved_content = fs::read_to_string(&file_b).expect("must read saved file");
        assert_eq!(saved_content, "flowchart TD\nB-->C\n");

        let recent = core
            .recent_files_json()
            .expect("recent_files_json should encode");
        assert!(recent.contains("diagram-b.mmd"));
        assert!(recent.contains("diagram-a.mmd"));

        fs::remove_dir_all(&dir).expect("must remove temp directory");
    }

    #[test]
    fn persist_recent_files_respects_limit_and_dedupes() {
        let dir = test_dir("recent");
        let recent_path = dir.join("recent-files.json");
        fs::write(
            &recent_path,
            "[\"./one.mmd\", \"./two.mmd\", \"./one.mmd\", \"./three.mmd\"]",
        )
        .expect("must seed recent file");

        let mut core = DiaCore::new(2);
        core.load_recent_files(&recent_path)
            .expect("load_recent_files should succeed");
        let loaded = core
            .recent_files_json()
            .expect("recent_files_json should encode");

        assert!(loaded.contains("one.mmd"));
        assert!(loaded.contains("two.mmd"));
        assert!(!loaded.contains("three.mmd"));

        core.save_recent_files(&recent_path)
            .expect("save_recent_files should succeed");
        let reloaded = fs::read_to_string(&recent_path).expect("must read persisted recent file");
        assert!(reloaded.contains("one.mmd"));
        assert!(reloaded.contains("two.mmd"));

        fs::remove_dir_all(&dir).expect("must remove temp directory");
    }

    #[test]
    fn shared_document_helpers_use_expected_defaults() {
        let core = DiaCore::new(10);

        assert_eq!(DiaCore::default_document_content(), "sequenceDiagram\n    participant Jeff\n    participant Abed\n    participant StarBurns\n    participant Dean\n    participant StudyGroup as Study Group\n\n    Jeff->>Abed: We need chicken fingers\n    Abed->>Abed: Becomes fry cook\n    Note over Abed: Controls the supply\n    \n    Abed->>StarBurns: You handle distribution\n    StarBurns->>StudyGroup: Chicken fingers... for a price\n    StudyGroup->>StarBurns: Bribes & favors\n    StarBurns->>Abed: Reports tribute\n    \n    Jeff->>Abed: I need extra fingers for a date\n    Abed-->>Jeff: You'll wait like everyone else\n    Jeff->>Jeff: What have we created?\n    \n    Dean->>Abed: Why is everyone so happy?\n    Abed-->>Dean: Efficient cafeteria management\n    Dean->>Dean: Something's not right...\n    \n    StudyGroup->>Jeff: This has gone too far\n    Jeff->>Abed: We have to shut it down\n    Abed->>Abed: Destroys the fryer\n    Note over Abed: The empire crumbles");
        assert_eq!(core.display_name(), "Untitled");
        assert_eq!(core.suggested_document_name(), "diagram.mmd");
        assert_eq!(core.suggested_export_name(), "diagram.png");
    }

    #[test]
    fn shared_document_helpers_derive_names_from_current_file() {
        let dir = test_dir("helper_names");
        let file_path = dir.join("greendale-plan.mmd");
        fs::write(&file_path, "flowchart TD\nA-->B\n").expect("must write diagram file");

        let mut core = DiaCore::new(10);
        core.open_file(&file_path)
            .expect("open_file should succeed");

        assert_eq!(core.display_name(), "greendale-plan.mmd");
        assert_eq!(core.suggested_document_name(), "greendale-plan.mmd");
        assert_eq!(core.suggested_export_name(), "greendale-plan.png");

        fs::remove_dir_all(&dir).expect("must remove temp directory");
    }

    #[test]
    fn shared_extension_helpers_only_fill_missing_extensions() {
        let no_ext = PathBuf::from("/tmp/senor-chang");
        let has_doc_ext = PathBuf::from("/tmp/troy.mmd");
        let has_other_ext = PathBuf::from("/tmp/annie.svg");

        assert_eq!(
            DiaCore::ensure_document_extension(&no_ext),
            PathBuf::from("/tmp/senor-chang.mmd")
        );
        assert_eq!(
            DiaCore::ensure_document_extension(&has_doc_ext),
            has_doc_ext
        );
        assert_eq!(
            DiaCore::ensure_export_extension(&no_ext),
            PathBuf::from("/tmp/senor-chang.png")
        );
        assert_eq!(
            DiaCore::ensure_export_extension(&has_other_ext),
            has_other_ext
        );
    }

    #[test]
    fn theme_helpers_expose_catalog_and_default() {
        let catalog = DiaCore::mermaid_theme_catalog_json().expect("catalog should encode");

        assert!(catalog.contains("\"id\":\"default\""));
        assert!(catalog.contains("\"id\":\"solarized\""));
        assert_eq!(DiaCore::default_theme_id(), "default");
        assert_eq!(DiaCore::normalize_theme_id("forest"), "forest");
        assert_eq!(DiaCore::normalize_theme_id("not-a-theme"), "default");
    }

    #[test]
    fn theme_helpers_generate_expected_mermaid_config() {
        let forest = DiaCore::mermaid_config_js("forest");
        let dracula = DiaCore::mermaid_config_js("dracula");

        assert!(forest.contains("theme: \"forest\""));
        assert!(forest.contains("securityLevel: \"strict\""));
        assert!(dracula.contains("theme: \"base\""));
        assert!(dracula.contains("themeVariables:"));
        assert!(dracula.contains("primaryColor: \"#bd93f9\""));
    }

    #[test]
    fn syntax_helpers_expose_auto_indent_and_highlight_spans() {
        let insertion = DiaCore::auto_indent_insertion("    line");
        let spans = DiaCore::mermaid_highlight_spans_json("flowchart TD\nA -->|yes| B\n")
            .expect("highlight spans should encode");

        assert_eq!(insertion, "\n    ");
        assert!(spans.contains("\"kind\":\"keyword\""));
        assert!(spans.contains("\"kind\":\"operator\""));
        assert!(spans.contains("\"kind\":\"label\""));
    }
}
