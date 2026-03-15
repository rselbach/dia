package theme

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestThemesCatalog(t *testing.T) {
	r := require.New(t)
	all := Themes()
	r.Len(all, 11)
	r.Equal("default", all[0].ID)
	r.Equal("solarized", all[len(all)-1].ID)
}

func TestNormalizeThemeID(t *testing.T) {
	tests := map[string]struct {
		input string
		want  string
	}{
		"known theme":   {input: "forest", want: "forest"},
		"unknown theme": {input: "not-a-theme", want: "default"},
		"default":       {input: "default", want: "default"},
		"dracula":       {input: "dracula", want: "dracula"},
	}

	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			r := require.New(t)
			r.Equal(tc.want, NormalizeThemeID(tc.input))
		})
	}
}

func TestMermaidConfigJS(t *testing.T) {
	tests := map[string]struct {
		themeID      string
		wantContains []string
		wantMissing  []string
	}{
		"built-in theme uses theme name": {
			themeID:      "forest",
			wantContains: []string{`theme: "forest"`, `securityLevel: "strict"`},
			wantMissing:  []string{"themeVariables"},
		},
		"custom theme uses base with variables": {
			themeID:      "dracula",
			wantContains: []string{`theme: "base"`, "themeVariables:", `primaryColor: "#bd93f9"`},
		},
		"unknown falls back to default": {
			themeID:      "nonexistent",
			wantContains: []string{`theme: "default"`},
		},
	}

	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			r := require.New(t)
			config := MermaidConfigJS(tc.themeID)
			for _, s := range tc.wantContains {
				r.Contains(config, s)
			}
			for _, s := range tc.wantMissing {
				r.NotContains(config, s)
			}
		})
	}
}

func TestThemeInfoFields(t *testing.T) {
	r := require.New(t)
	all := Themes()

	for _, ti := range all {
		r.NotEmpty(ti.ID, "theme ID must not be empty")
		r.NotEmpty(ti.Label, "theme label must not be empty for %s", ti.ID)
		r.NotEmpty(ti.PreviewBackground, "preview background must not be empty for %s", ti.ID)
		r.NotEmpty(ti.ErrorColor, "error color must not be empty for %s", ti.ID)
	}
}
