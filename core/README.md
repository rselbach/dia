# dia_core

`dia_core` is a Rust library meant to be embedded by native macOS and Linux apps.

## What This Contains

- Document file operations (`open_file`, `save`, `save_as`)
- Dirty-state tracking
- Recent file list tracking and persistence
- Public Rust API for Rust-native frontends
- C ABI so Swift, Qt, and GTK can all call the same core

## Build

```bash
cargo build --release
```

Artifacts are produced under `target/release/`:

- `libdia_core.a` (static)
- `libdia_core.so` (Linux shared)
- `libdia_core.dylib` (macOS shared)

## ABI Contract

- Public header: `include/dia_core.h`
- `DiaResult.code == DIA_RESULT_OK` means success
- On success, `DiaResult.value` may contain UTF-8 text; on error, `DiaResult.error` contains a UTF-8 message
- Every non-null `value` or `error` returned by the library must be released with `dia_string_free`

## Example (C-like usage)

```c
DiaCore *core = dia_core_new(10);

DiaResult result = dia_core_open_file(core, "/tmp/diagram.mmd");
if (result.code != DIA_RESULT_OK) {
  fprintf(stderr, "open failed: %s\n", result.error);
  dia_string_free(result.error);
  dia_core_free(core);
  return;
}

printf("content: %s\n", result.value);
dia_string_free(result.value);
dia_core_free(core);
```
