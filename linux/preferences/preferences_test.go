package preferences

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestLoadMissingFile(t *testing.T) {
	r := require.New(t)
	p, err := Load(filepath.Join(t.TempDir(), "nonexistent.json"))
	r.NoError(err)
	r.Equal(DefaultFontSize, p.EditorFontSize)
	r.Empty(p.DefaultThemeID)
	r.Empty(p.EditorFontName)
}

func TestSaveAndLoad(t *testing.T) {
	r := require.New(t)
	path := filepath.Join(t.TempDir(), "dia", "preferences.json")

	p := &Preferences{
		DefaultThemeID: "dracula",
		EditorFontName: "JetBrains Mono",
		EditorFontSize: 16.0,
	}
	r.NoError(p.Save(path))

	loaded, err := Load(path)
	r.NoError(err)
	r.Equal("dracula", loaded.DefaultThemeID)
	r.Equal("JetBrains Mono", loaded.EditorFontName)
	r.Equal(16.0, loaded.EditorFontSize)
}

func TestLoadDefaultsFontSizeOnZero(t *testing.T) {
	r := require.New(t)
	path := filepath.Join(t.TempDir(), "prefs.json")
	r.NoError(os.WriteFile(path, []byte(`{"defaultTheme":"forest","editorFontName":"Monospace","editorFontSize":0}`), 0644))

	loaded, err := Load(path)
	r.NoError(err)
	r.Equal(DefaultFontSize, loaded.EditorFontSize)
}

func TestClampFontSize(t *testing.T) {
	tests := map[string]struct {
		input float64
		want  float64
	}{
		"below min": {input: 5.0, want: MinFontSize},
		"at min":    {input: MinFontSize, want: MinFontSize},
		"in range":  {input: 16.0, want: 16.0},
		"at max":    {input: MaxFontSize, want: MaxFontSize},
		"above max": {input: 30.0, want: MaxFontSize},
	}

	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			r := require.New(t)
			r.Equal(tc.want, ClampFontSize(tc.input))
		})
	}
}

func TestDefaultPath(t *testing.T) {
	r := require.New(t)
	path, err := DefaultPath()
	r.NoError(err)
	r.Contains(path, "dia")
	r.Contains(path, "preferences.json")
}

func TestSaveCreatesParentDirectories(t *testing.T) {
	r := require.New(t)
	path := filepath.Join(t.TempDir(), "deep", "nested", "dir", "preferences.json")
	p := &Preferences{EditorFontSize: 14.0}
	r.NoError(p.Save(path))

	_, err := os.Stat(path)
	r.NoError(err)
}

func TestLoadInvalidJSON(t *testing.T) {
	r := require.New(t)
	path := filepath.Join(t.TempDir(), "bad.json")
	r.NoError(os.WriteFile(path, []byte(`{invalid`), 0644))

	_, err := Load(path)
	r.Error(err)
	r.Contains(err.Error(), "failed to parse")
}
