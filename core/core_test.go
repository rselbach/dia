package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
)

func testDir(t *testing.T, name string) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), name)
	r := require.New(t)
	r.NoError(os.MkdirAll(dir, 0755))
	return dir
}

func TestOpenAndSaveRoundTrip(t *testing.T) {
	r := require.New(t)
	dir := testDir(t, "round_trip")

	fileA := filepath.Join(dir, "diagram-a.mmd")
	fileB := filepath.Join(dir, "diagram-b.mmd")
	r.NoError(os.WriteFile(fileA, []byte("flowchart TD\nA-->B\n"), 0644))

	c := New(10)
	opened, err := c.OpenFile(fileA)
	r.NoError(err)
	r.Equal("flowchart TD\nA-->B\n", opened)
	r.False(c.IsDirty())

	c.SetDirty(true)
	r.True(c.IsDirty())

	_, err = c.SaveAs(fileB, "flowchart TD\nB-->C\n")
	r.NoError(err)

	saved, err := os.ReadFile(fileB)
	r.NoError(err)
	r.Equal("flowchart TD\nB-->C\n", string(saved))

	recentJSON, err := c.RecentFilesJSON()
	r.NoError(err)
	r.Contains(recentJSON, "diagram-b.mmd")
	r.Contains(recentJSON, "diagram-a.mmd")
}

func TestPersistRecentFilesRespectsLimitAndDedupes(t *testing.T) {
	r := require.New(t)
	dir := testDir(t, "recent")
	recentPath := filepath.Join(dir, "recent-files.json")
	r.NoError(os.WriteFile(recentPath, []byte(`["./one.mmd", "./two.mmd", "./one.mmd", "./three.mmd"]`), 0644))

	c := New(2)
	r.NoError(c.LoadRecentFiles(recentPath))

	loaded, err := c.RecentFilesJSON()
	r.NoError(err)
	r.Contains(loaded, "one.mmd")
	r.Contains(loaded, "two.mmd")
	r.NotContains(loaded, "three.mmd")

	r.NoError(c.SaveRecentFiles(recentPath))
	reloaded, err := os.ReadFile(recentPath)
	r.NoError(err)
	r.Contains(string(reloaded), "one.mmd")
	r.Contains(string(reloaded), "two.mmd")
}

func TestSharedDocumentHelpers(t *testing.T) {
	tests := map[string]struct {
		setup       func(*DiaCore)
		wantDisplay string
		wantDocName string
		wantExport  string
	}{
		"untitled defaults": {
			setup:       func(_ *DiaCore) {},
			wantDisplay: "Untitled",
			wantDocName: "diagram.mmd",
			wantExport:  "diagram.png",
		},
	}

	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			r := require.New(t)
			c := New(10)
			tc.setup(c)
			r.Equal(tc.wantDisplay, c.DisplayName())
			r.Equal(tc.wantDocName, c.SuggestedDocumentName())
			r.Equal(tc.wantExport, c.SuggestedExportName())
		})
	}
}

func TestDocumentHelpersFromOpenedFile(t *testing.T) {
	r := require.New(t)
	dir := testDir(t, "helper_names")
	filePath := filepath.Join(dir, "greendale-plan.mmd")
	r.NoError(os.WriteFile(filePath, []byte("flowchart TD\nA-->B\n"), 0644))

	c := New(10)
	_, err := c.OpenFile(filePath)
	r.NoError(err)

	r.Equal("greendale-plan.mmd", c.DisplayName())
	r.Equal("greendale-plan.mmd", c.SuggestedDocumentName())
	r.Equal("greendale-plan.png", c.SuggestedExportName())
}

func TestEnsureExtensions(t *testing.T) {
	tests := map[string]struct {
		fn   func(string) string
		path string
		want string
	}{
		"document adds mmd when missing": {
			fn:   EnsureDocumentExtension,
			path: "/tmp/senor-chang",
			want: "/tmp/senor-chang.mmd",
		},
		"document keeps existing ext": {
			fn:   EnsureDocumentExtension,
			path: "/tmp/troy.mmd",
			want: "/tmp/troy.mmd",
		},
		"export adds png when missing": {
			fn:   EnsureExportExtension,
			path: "/tmp/senor-chang",
			want: "/tmp/senor-chang.png",
		},
		"export keeps existing ext": {
			fn:   EnsureExportExtension,
			path: "/tmp/annie.svg",
			want: "/tmp/annie.svg",
		},
	}

	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			r := require.New(t)
			r.Equal(tc.want, tc.fn(tc.path))
		})
	}
}

func TestDefaultDocumentContent(t *testing.T) {
	r := require.New(t)
	content := DefaultDocumentContent()
	r.Contains(content, "sequenceDiagram")
	r.Contains(content, "Jeff")
	r.Contains(content, "Abed")
	r.Contains(content, "chicken fingers")
}

func TestSaveWithNoCurrentFileReturnsError(t *testing.T) {
	r := require.New(t)
	c := New(10)
	_, err := c.Save("content")
	r.Error(err)
	r.Contains(err.Error(), "no current file")
}

func TestLoadRecentFilesMissingFileIsNotError(t *testing.T) {
	r := require.New(t)
	dir := testDir(t, "missing")
	c := New(10)
	r.NoError(c.LoadRecentFiles(filepath.Join(dir, "nonexistent.json")))
	r.Empty(c.RecentFiles())
}

func TestRecentFilesJSON(t *testing.T) {
	r := require.New(t)
	dir := testDir(t, "json")
	file := filepath.Join(dir, "troy.mmd")
	r.NoError(os.WriteFile(file, []byte("graph LR\n"), 0644))

	c := New(10)
	_, err := c.OpenFile(file)
	r.NoError(err)

	jsonStr, err := c.RecentFilesJSON()
	r.NoError(err)

	var paths []string
	r.NoError(json.Unmarshal([]byte(jsonStr), &paths))
	r.Len(paths, 1)
	r.Contains(paths[0], "troy.mmd")
}
