use std::ffi::{CStr, CString};
use std::fs;
use std::os::raw::c_char;
use std::panic::{catch_unwind, UnwindSafe};
use std::path::{Path, PathBuf};

const DEFAULT_MAX_RECENT_FILES: usize = 10;

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
}
