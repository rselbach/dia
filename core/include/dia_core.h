#ifndef DIA_CORE_H
#define DIA_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DiaCore DiaCore;

typedef struct DiaResult {
  int32_t code;
  char *value;
  char *error;
} DiaResult;

enum {
  DIA_RESULT_OK = 0,
  DIA_RESULT_ERROR = 1,
};

DiaCore *dia_core_new(uint32_t max_recent_files);
void dia_core_free(DiaCore *core);

DiaResult dia_core_open_file(DiaCore *core, const char *path);
DiaResult dia_core_new_document(DiaCore *core);
DiaResult dia_core_save(DiaCore *core, const char *content);
DiaResult dia_core_save_as(DiaCore *core, const char *path, const char *content);

DiaResult dia_core_set_dirty(DiaCore *core, int32_t dirty);
/* Returns 1 for dirty, 0 for clean, and -1 for invalid input (e.g. null core). */
int32_t dia_core_is_dirty(const DiaCore *core);

DiaResult dia_core_current_file(const DiaCore *core);
DiaResult dia_core_display_name(const DiaCore *core);
DiaResult dia_core_suggested_document_name(const DiaCore *core);
DiaResult dia_core_suggested_export_name(const DiaCore *core);
DiaResult dia_core_default_document_content(void);
DiaResult dia_core_default_theme_id(void);
DiaResult dia_core_mermaid_theme_catalog_json(void);
DiaResult dia_core_normalize_theme_id(const char *theme_id);
DiaResult dia_core_mermaid_config_js(const char *theme_id);
DiaResult dia_core_mermaid_highlight_spans_json(const char *source);
DiaResult dia_core_auto_indent_insertion(const char *prefix);
DiaResult dia_core_ensure_document_extension(const char *path);
DiaResult dia_core_ensure_export_extension(const char *path);
DiaResult dia_core_recent_files_json(const DiaCore *core);
DiaResult dia_core_load_recent_files(DiaCore *core, const char *path);
DiaResult dia_core_save_recent_files(const DiaCore *core, const char *path);

void dia_string_free(char *value);

#ifdef __cplusplus
}
#endif

#endif
