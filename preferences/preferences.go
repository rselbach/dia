// Package preferences handles loading and saving user preferences for dia.
package preferences

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

const (
	DefaultFontSize = 14.0
	MinFontSize     = 10.0
	MaxFontSize     = 24.0
)

// Preferences holds user-configurable settings.
type Preferences struct {
	DefaultThemeID string  `json:"defaultTheme"`
	EditorFontName string  `json:"editorFontName"`
	EditorFontSize float64 `json:"editorFontSize"`
}

// Load reads preferences from path. Returns defaults if the file doesn't exist.
func Load(path string) (*Preferences, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return defaults(), nil
		}
		return nil, fmt.Errorf("failed to read %s: %w", path, err)
	}

	var p Preferences
	if err := json.Unmarshal(data, &p); err != nil {
		return nil, fmt.Errorf("failed to parse %s: %w", path, err)
	}

	if p.EditorFontSize == 0 {
		p.EditorFontSize = DefaultFontSize
	}
	return &p, nil
}

// Save writes preferences as pretty-printed JSON to path.
func (p *Preferences) Save(path string) error {
	parent := filepath.Dir(path)
	if err := os.MkdirAll(parent, 0755); err != nil {
		return fmt.Errorf("failed to create directory %s: %w", parent, err)
	}

	encoded, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to encode preferences: %w", err)
	}
	encoded = append(encoded, '\n')

	if err := os.WriteFile(path, encoded, 0644); err != nil {
		return fmt.Errorf("failed to write %s: %w", path, err)
	}
	return nil
}

// DefaultPath returns the platform-standard preferences file path.
func DefaultPath() (string, error) {
	configDir, err := os.UserConfigDir()
	if err != nil {
		return "", fmt.Errorf("could not resolve user config directory: %w", err)
	}
	return filepath.Join(configDir, "dia", "preferences.json"), nil
}

// ClampFontSize clamps a font size to the valid range [MinFontSize, MaxFontSize].
func ClampFontSize(size float64) float64 {
	switch {
	case size < MinFontSize:
		return MinFontSize
	case size > MaxFontSize:
		return MaxFontSize
	default:
		return size
	}
}

func defaults() *Preferences {
	return &Preferences{
		EditorFontSize: DefaultFontSize,
	}
}
