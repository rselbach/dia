// Package core provides the business logic for dia: file management,
// recent-file tracking, theme catalog, and diagram defaults.
package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const (
	DefaultMaxRecentFiles = 10
	DefaultDocumentName   = "diagram.mmd"
	DefaultExportName     = "diagram.png"
	DefaultThemeID        = "default"
)

// DefaultDocumentContent returns the starter Community-themed sequence diagram.
func DefaultDocumentContent() string {
	return `sequenceDiagram
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
    Note over Abed: The empire crumbles`
}

// DiaCore holds editor state: current file, dirty flag, and recent-file list.
type DiaCore struct {
	currentFile    string
	dirty          bool
	recentFiles    []string
	maxRecentFiles int
}

// New creates a DiaCore with the given recent-file limit (minimum 1).
func New(maxRecentFiles int) *DiaCore {
	if maxRecentFiles < 1 {
		maxRecentFiles = 1
	}
	return &DiaCore{
		maxRecentFiles: maxRecentFiles,
	}
}

// OpenFile reads the file at path, updates state, and returns its content.
func (c *DiaCore) OpenFile(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("failed to read %s: %w", path, err)
	}

	normalized, err := normalizePath(path)
	if err != nil {
		return "", err
	}

	c.currentFile = normalized
	c.dirty = false
	c.addRecentFile(normalized)
	return string(data), nil
}

// NewDocument resets core state to a blank untitled document.
func (c *DiaCore) NewDocument() {
	c.currentFile = ""
	c.dirty = false
}

// CurrentFile returns the absolute path of the current file, or empty string.
func (c *DiaCore) CurrentFile() string {
	return c.currentFile
}

// CurrentFileName returns just the base name of the current file, or empty string.
func (c *DiaCore) CurrentFileName() string {
	if c.currentFile == "" {
		return ""
	}
	return filepath.Base(c.currentFile)
}

// DisplayName returns the file name for the title bar, or "Untitled".
func (c *DiaCore) DisplayName() string {
	name := c.CurrentFileName()
	if name == "" {
		return "Untitled"
	}
	return name
}

// SuggestedDocumentName returns the current file name or the default "diagram.mmd".
func (c *DiaCore) SuggestedDocumentName() string {
	name := c.CurrentFileName()
	if name == "" {
		return DefaultDocumentName
	}
	return name
}

// SuggestedExportName derives a .png name from the current file, or "diagram.png".
func (c *DiaCore) SuggestedExportName() string {
	if c.currentFile == "" {
		return DefaultExportName
	}
	stem := strings.TrimSuffix(filepath.Base(c.currentFile), filepath.Ext(c.currentFile))
	if stem == "" {
		return DefaultExportName
	}
	return stem + ".png"
}

// Save writes content to the current file. Returns the saved path.
func (c *DiaCore) Save(content string) (string, error) {
	if c.currentFile == "" {
		return "", errors.New("no current file is set; use save_as first")
	}
	return c.writeFile(c.currentFile, content)
}

// SaveAs writes content to the given path, updating current file. Returns the saved path.
func (c *DiaCore) SaveAs(path, content string) (string, error) {
	normalized, err := normalizePath(path)
	if err != nil {
		return "", err
	}
	return c.writeFile(normalized, content)
}

func (c *DiaCore) writeFile(path, content string) (string, error) {
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		return "", fmt.Errorf("failed to write %s: %w", path, err)
	}

	c.currentFile = path
	c.dirty = false
	c.addRecentFile(path)
	return path, nil
}

func (c *DiaCore) addRecentFile(path string) {
	next := make([]string, 0, c.maxRecentFiles)
	next = append(next, path)

	for _, existing := range c.recentFiles {
		if existing == path {
			continue
		}
		next = append(next, existing)
		if len(next) >= c.maxRecentFiles {
			break
		}
	}

	c.recentFiles = next
}

// SetDirty marks or clears the dirty flag.
func (c *DiaCore) SetDirty(dirty bool) {
	c.dirty = dirty
}

// IsDirty reports whether unsaved changes exist.
func (c *DiaCore) IsDirty() bool {
	return c.dirty
}

// RecentFiles returns the list of recent file paths.
func (c *DiaCore) RecentFiles() []string {
	return c.recentFiles
}

// RecentFilesJSON returns the recent files list as a JSON array string.
func (c *DiaCore) RecentFilesJSON() (string, error) {
	data, err := json.Marshal(c.recentFiles)
	if err != nil {
		return "", fmt.Errorf("json error: %w", err)
	}
	return string(data), nil
}

// LoadRecentFiles reads a JSON array of file paths from disk.
// Missing file is not an error; it simply results in an empty list.
func (c *DiaCore) LoadRecentFiles(path string) error {
	normalized, err := normalizePath(path)
	if err != nil {
		return err
	}

	data, err := os.ReadFile(normalized)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			c.recentFiles = nil
			return nil
		}
		return fmt.Errorf("failed to read %s: %w", normalized, err)
	}

	var parsed []string
	if err := json.Unmarshal(data, &parsed); err != nil {
		return fmt.Errorf("json error: %w", err)
	}

	deduped := make([]string, 0, c.maxRecentFiles)
	for _, entry := range parsed {
		candidate, err := normalizePath(entry)
		if err != nil {
			return err
		}

		alreadySeen := false
		for _, existing := range deduped {
			if existing == candidate {
				alreadySeen = true
				break
			}
		}
		if alreadySeen {
			continue
		}

		deduped = append(deduped, candidate)
		if len(deduped) >= c.maxRecentFiles {
			break
		}
	}

	c.recentFiles = deduped
	return nil
}

// SaveRecentFiles persists the recent file list as pretty-printed JSON.
func (c *DiaCore) SaveRecentFiles(path string) error {
	normalized, err := normalizePath(path)
	if err != nil {
		return err
	}

	if parent := filepath.Dir(normalized); parent != "" {
		if err := os.MkdirAll(parent, 0755); err != nil {
			return fmt.Errorf("failed to create directory %s: %w", parent, err)
		}
	}

	encoded, err := json.MarshalIndent(c.recentFiles, "", "  ")
	if err != nil {
		return fmt.Errorf("json error: %w", err)
	}
	encoded = append(encoded, '\n')

	if err := os.WriteFile(normalized, encoded, 0644); err != nil {
		return fmt.Errorf("failed to write %s: %w", normalized, err)
	}
	return nil
}

// EnsureDocumentExtension appends ".mmd" if the path has no extension.
func EnsureDocumentExtension(path string) string {
	return ensureExtension(path, ".mmd")
}

// EnsureExportExtension appends ".png" if the path has no extension.
func EnsureExportExtension(path string) string {
	return ensureExtension(path, ".png")
}

func ensureExtension(path, ext string) string {
	if filepath.Ext(path) == "" {
		return path + ext
	}
	return path
}

func normalizePath(path string) (string, error) {
	if path == "" {
		return "", errors.New("path must not be empty")
	}
	return filepath.Abs(path)
}
