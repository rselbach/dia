package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/wailsapp/wails/v2/pkg/runtime"
)

// FileResult is returned to the frontend after file operations.
type FileResult struct {
	Content  string `json:"content"`
	FilePath string `json:"filePath"`
	Error    string `json:"error,omitempty"`
}

// App holds application state and exposes methods to the frontend.
type App struct {
	ctx         context.Context
	currentFile string
	dirty       bool
}

func NewApp() *App {
	return &App{}
}

func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
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

	data, err := os.ReadFile(path)
	if err != nil {
		return FileResult{Error: fmt.Sprintf("read error: %v", err)}
	}

	a.currentFile = path
	a.dirty = false
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
	a.dirty = false
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
