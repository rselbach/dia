package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/wailsapp/wails/v2/pkg/menu"
	"github.com/wailsapp/wails/v2/pkg/runtime"
)

const maxRecentFiles = 10

const recentFilesConfigName = "recent-files.json"

// FileResult is returned to the frontend after file operations.
type FileResult struct {
	Content  string `json:"content"`
	FilePath string `json:"filePath"`
	Error    string `json:"error,omitempty"`
}

// App holds application state and exposes methods to the frontend.
type App struct {
	ctx         context.Context
	version     string
	currentFile string
	dirty       bool
	allowClose  bool
	recentFiles []string
	recentPath  string
	recentMenu  *menu.Menu
}

// GetVersion returns the build version string.
func (a *App) GetVersion() string { return a.version }

func NewApp() *App {
	return &App{}
}

func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
	err := a.loadRecentFiles()
	if err != nil {
		runtime.LogErrorf(a.ctx, "failed to load recent files: %v", err)
	}
	a.refreshRecentMenu()
}

func (a *App) shutdown(_ context.Context) {}

// OpenFile shows a native open dialog and returns the file content.
func (a *App) OpenFile() FileResult {
	path, err := runtime.OpenFileDialog(a.ctx, runtime.OpenDialogOptions{
		Title: "Open Mermaid Diagram",
		Filters: []runtime.FileFilter{
			{DisplayName: "Mermaid (*.mmd *.mermaid)", Pattern: "*.mmd;*.mermaid"},
			{DisplayName: "All Files (*.*)", Pattern: "*.*"},
		},
	})
	if err != nil {
		return FileResult{Error: fmt.Sprintf("dialog error: %v", err)}
	}
	if path == "" {
		return FileResult{}
	}

	return a.openFilePath(path)
}

func (a *App) openFilePath(path string) FileResult {
	data, err := os.ReadFile(path)
	if err != nil {
		return FileResult{Error: fmt.Sprintf("read error: %v", err)}
	}

	a.currentFile = path
	a.dirty = false
	a.addRecentFile(path)
	a.updateTitle()
	return FileResult{Content: string(data), FilePath: path}
}

// SaveWithContent writes editor content to the current file.
// If no file is set, falls through to SaveAsWithContent.
func (a *App) SaveWithContent(content string) FileResult {
	if a.currentFile == "" {
		return a.SaveAsWithContent(content)
	}
	return a.doWrite(a.currentFile, content)
}

// SaveAsWithContent shows a native save dialog then writes.
func (a *App) SaveAsWithContent(content string) FileResult {
	path, err := runtime.SaveFileDialog(a.ctx, runtime.SaveDialogOptions{
		Title:           "Save Mermaid Diagram",
		DefaultFilename: "diagram.mmd",
		Filters: []runtime.FileFilter{
			{DisplayName: "Mermaid (*.mmd)", Pattern: "*.mmd"},
			{DisplayName: "All Files (*.*)", Pattern: "*.*"},
		},
	})
	if err != nil {
		return FileResult{Error: fmt.Sprintf("dialog error: %v", err)}
	}
	if path == "" {
		return FileResult{}
	}

	a.currentFile = path
	return a.doWrite(path, content)
}

func (a *App) doWrite(path, content string) FileResult {
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		return FileResult{Error: fmt.Sprintf("write error: %v", err)}
	}
	a.currentFile = path
	a.dirty = false
	a.addRecentFile(path)
	a.updateTitle()
	return FileResult{FilePath: path}
}

// SetDirty is called from the frontend when editor content changes.
func (a *App) SetDirty(dirty bool) {
	a.dirty = dirty
	a.updateTitle()
}

// ConfirmDiscard shows a dialog asking to save unsaved changes.
// Returns true if the user wants to proceed (discard).
func (a *App) ConfirmDiscard() bool {
	if !a.dirty {
		return true
	}
	result, err := runtime.MessageDialog(a.ctx, runtime.MessageDialogOptions{
		Type:          runtime.QuestionDialog,
		Title:         "Unsaved Changes",
		Message:       "You have unsaved changes. Discard them?",
		DefaultButton: "No",
		Buttons:       []string{"Yes", "No"},
	})
	if err != nil {
		return false
	}
	return result == "Yes"
}

func (a *App) AllowCloseOnce() {
	a.allowClose = true
}

func (a *App) beforeClose(_ context.Context) (prevent bool) {
	if a.allowClose {
		a.allowClose = false
		return false
	}
	if !a.dirty {
		return false
	}

	result, err := runtime.MessageDialog(a.ctx, runtime.MessageDialogOptions{
		Type:          runtime.QuestionDialog,
		Title:         "Unsaved Changes",
		Message:       "You have unsaved changes. Save before quitting?",
		DefaultButton: "Save",
		CancelButton:  "Cancel",
		Buttons:       []string{"Save", "Discard", "Cancel"},
	})
	if err != nil {
		return true
	}

	switch result {
	case "Save":
		runtime.EventsEmit(a.ctx, "app:save-and-quit")
		return true
	case "Discard":
		return false
	default:
		return true
	}
}

func (a *App) initRecentMenu(menuRef *menu.Menu) {
	a.recentMenu = menuRef
	a.refreshRecentMenu()
}

func (a *App) addRecentFile(path string) {
	cleanPath := normalizeRecentPath(path)
	if cleanPath == "" {
		return
	}

	next := []string{cleanPath}
	for _, recentPath := range a.recentFiles {
		if recentPath == cleanPath {
			continue
		}
		next = append(next, recentPath)
		if len(next) >= maxRecentFiles {
			break
		}
	}

	a.recentFiles = next
	a.persistRecentFiles()
	a.refreshRecentMenu()
}

func (a *App) removeRecentFile(path string) {
	cleanPath := normalizeRecentPath(path)
	if cleanPath == "" {
		return
	}
	next := make([]string, 0, len(a.recentFiles))
	for _, recentPath := range a.recentFiles {
		if recentPath == cleanPath {
			continue
		}
		next = append(next, recentPath)
	}
	if len(next) == len(a.recentFiles) {
		return
	}
	a.recentFiles = next
	a.persistRecentFiles()
	a.refreshRecentMenu()
}

func (a *App) clearRecentFiles() {
	a.recentFiles = nil
	a.persistRecentFiles()
	a.refreshRecentMenu()
}

func (a *App) openRecentFile(path string) {
	if !a.ConfirmDiscard() {
		return
	}

	result := a.openFilePath(path)
	if result.Error != "" {
		a.removeRecentFile(path)
	}
	runtime.EventsEmit(a.ctx, "file:opened", result)
}

func (a *App) refreshRecentMenu() {
	if a.recentMenu == nil {
		return
	}

	a.recentMenu.Items = nil

	if len(a.recentFiles) == 0 {
		a.recentMenu.AddText("No Recent Files", nil, nil).Disable()
		if a.ctx != nil {
			runtime.MenuUpdateApplicationMenu(a.ctx)
		}
		return
	}

	for _, recentPath := range a.recentFiles {
		path := recentPath
		label := filepath.Base(path)
		dir := filepath.Dir(path)
		if dir != "." {
			label = fmt.Sprintf("%s (%s)", label, dir)
		}

		a.recentMenu.AddText(label, nil, func(_ *menu.CallbackData) {
			a.openRecentFile(path)
		})
	}

	a.recentMenu.AddSeparator()
	a.recentMenu.AddText("Clear Menu", nil, func(_ *menu.CallbackData) {
		a.clearRecentFiles()
	})

	if a.ctx != nil {
		runtime.MenuUpdateApplicationMenu(a.ctx)
	}
}

func (a *App) persistRecentFiles() {
	err := a.saveRecentFiles()
	if err == nil {
		return
	}
	runtime.LogErrorf(a.ctx, "failed to persist recent files: %v", err)
}

func (a *App) loadRecentFiles() error {
	path, err := a.getRecentFilesPath()
	if err != nil {
		return err
	}

	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			a.recentFiles = nil
			return nil
		}
		return fmt.Errorf("read %s: %w", path, err)
	}

	var recent []string
	err = json.Unmarshal(data, &recent)
	if err != nil {
		return fmt.Errorf("decode %s: %w", path, err)
	}

	a.recentFiles = normalizeRecentFiles(recent)
	return nil
}

func (a *App) saveRecentFiles() error {
	path, err := a.getRecentFilesPath()
	if err != nil {
		return err
	}

	dir := filepath.Dir(path)
	err = os.MkdirAll(dir, 0o755)
	if err != nil {
		return fmt.Errorf("mkdir %s: %w", dir, err)
	}

	data, err := json.MarshalIndent(a.recentFiles, "", "  ")
	if err != nil {
		return fmt.Errorf("encode recent files: %w", err)
	}
	data = append(data, '\n')

	err = os.WriteFile(path, data, 0o644)
	if err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}

	return nil
}

func (a *App) getRecentFilesPath() (string, error) {
	if a.recentPath != "" {
		return a.recentPath, nil
	}

	configDir, err := os.UserConfigDir()
	if err != nil {
		return "", fmt.Errorf("resolve user config dir: %w", err)
	}

	a.recentPath = filepath.Join(configDir, "dia", recentFilesConfigName)
	return a.recentPath, nil
}

func normalizeRecentFiles(paths []string) []string {
	result := make([]string, 0, maxRecentFiles)
	seen := make(map[string]struct{}, maxRecentFiles)

	for _, path := range paths {
		cleanPath := normalizeRecentPath(path)
		if cleanPath == "" {
			continue
		}

		if _, ok := seen[cleanPath]; ok {
			continue
		}
		seen[cleanPath] = struct{}{}
		result = append(result, cleanPath)
		if len(result) >= maxRecentFiles {
			break
		}
	}

	return result
}

func normalizeRecentPath(path string) string {
	cleanPath := filepath.Clean(path)
	if cleanPath == "." {
		return ""
	}

	absPath, err := filepath.Abs(cleanPath)
	if err == nil {
		return absPath
	}

	return cleanPath
}

func (a *App) updateTitle() {
	name := "Untitled"
	if a.currentFile != "" {
		name = filepath.Base(a.currentFile)
	}
	title := fmt.Sprintf("dia - %s", name)
	if a.dirty {
		title += " *"
	}
	runtime.WindowSetTitle(a.ctx, title)
}
