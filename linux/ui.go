package main

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/diamondburned/gotk4/pkg/gdk/v4"
	"github.com/diamondburned/gotk4/pkg/gio/v2"
	"github.com/diamondburned/gotk4/pkg/glib/v2"
	"github.com/diamondburned/gotk4/pkg/gtk/v4"
	"github.com/diamondburned/gotk4/pkg/pango"
	"github.com/diamondburned/gotk4-webkitgtk/pkg/webkit/v6"

	"github.com/rselbach/dia/core"
	"github.com/rselbach/dia/preferences"
	"github.com/rselbach/dia/syntax"
	"github.com/rselbach/dia/theme"
)

const (
	mermaidBundleName   = "mermaid.min.js"
	tagKeyword          = "dia-mermaid-keyword"
	tagOperator         = "dia-mermaid-operator"
	tagComment          = "dia-mermaid-comment"
	tagLabel            = "dia-mermaid-label"
	renderDebounceMs    = 250
	highlightDebounceMs = 120
)

var appChromeCSS = `
menubutton#floating-preview-menu > button {
  border-radius: 8px;
  min-width: 36px;
  min-height: 36px;
  background: rgba(22, 26, 36, 0.75);
  border: 1px solid rgba(109, 146, 201, 0.55);
  color: #f8fbff;
  box-shadow: 0 6px 20px rgba(10, 14, 20, 0.35);
}

menubutton#floating-preview-menu > button:hover {
  background: rgba(35, 43, 61, 0.88);
  border-color: rgba(140, 179, 235, 0.8);
}

#status-line {
  color: #fca5a5;
  margin-top: 2px;
}
`

// EditorFontOption describes a font available for the editor.
type EditorFontOption struct {
	Family string
	Label  string
}

// UIState holds the entire application UI state.
type UIState struct {
	core              *core.DiaCore
	window            *gtk.ApplicationWindow
	app               *gtk.Application
	buffer            *gtk.TextBuffer
	editor            *gtk.TextView
	editorCSSProvider *gtk.CSSProvider
	preview           *webkit.WebView
	status            *gtk.Label
	previewBaseURI    string

	availableThemes []theme.ThemeInfo
	availableFonts  []EditorFontOption

	prefsThemeID string
	prefsFontName string
	prefsFontSize float64
	previewTheme  *PreviewTheme

	startupErrors  []string
	renderTimer    glib.SourceHandle
	highlightTimer glib.SourceHandle
	suppressDirty  bool
	started        bool
}

func newUIState(app *gtk.Application) *UIState {
	window := gtk.NewApplicationWindow(app)
	window.SetDefaultSize(1280, 800)

	installAppChromeCSS()

	root := gtk.NewBox(gtk.OrientationVertical, 6)
	root.SetMarginTop(8)
	root.SetMarginBottom(8)
	root.SetMarginStart(8)
	root.SetMarginEnd(8)

	paned := gtk.NewPaned(gtk.OrientationHorizontal)
	paned.SetWideHandle(true)
	paned.SetPosition(480)

	textBuffer := gtk.NewTextBuffer(nil)
	installEditorTags(textBuffer)
	textBuffer.SetText(core.DefaultDocumentContent())

	editor := gtk.NewTextViewWithBuffer(textBuffer)
	editor.SetName("diagram-editor")
	editor.SetMonospace(true)
	editor.SetWrapMode(gtk.WrapNone)

	editorScroll := gtk.NewScrolledWindow()
	editorScroll.SetHExpand(true)
	editorScroll.SetVExpand(true)
	editorScroll.SetChild(editor)

	preview := webkit.NewWebView()
	preview.SetHExpand(true)
	preview.SetVExpand(true)

	previewOverlay := gtk.NewOverlay()
	previewOverlay.SetChild(preview)

	menuButton := gtk.NewMenuButton()
	menuButton.SetName("floating-preview-menu")
	menuButton.SetIconName("open-menu-symbolic")
	menuButton.SetTooltipText("App menu")
	menuButton.SetHAlign(gtk.AlignEnd)
	menuButton.SetVAlign(gtk.AlignStart)
	menuButton.SetMarginTop(12)
	menuButton.SetMarginEnd(12)
	menuButton.SetMenuModel(buildPrimaryMenuModel())
	previewOverlay.AddOverlay(menuButton)

	paned.SetStartChild(editorScroll)
	paned.SetEndChild(previewOverlay)

	statusLabel := gtk.NewLabel("")
	statusLabel.SetName("status-line")
	statusLabel.SetXAlign(0.0)
	statusLabel.SetWrap(true)

	setup := loadAppSetup(editor)
	previewBaseURI, mermaidErr := loadMermaidVendorBaseURI()

	editorCSSProvider := gtk.NewCSSProvider()
	if display := gdk.DisplayGetDefault(); display != nil {
		gtk.StyleContextAddProviderForDisplay(display, editorCSSProvider, gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
	}

	root.Append(paned)
	root.Append(statusLabel)
	window.SetChild(root)

	startupErrors := setup.startupErrors
	if mermaidErr != "" {
		startupErrors = append(startupErrors, mermaidErr)
	}

	ui := &UIState{
		core:              core.New(core.DefaultMaxRecentFiles),
		window:            window,
		app:               app,
		buffer:            textBuffer,
		editor:            editor,
		editorCSSProvider: editorCSSProvider,
		preview:           preview,
		status:            statusLabel,
		previewBaseURI:    previewBaseURI,
		availableThemes:   setup.themes,
		availableFonts:    setup.fonts,
		prefsThemeID:      setup.prefsThemeID,
		prefsFontName:     setup.prefsFontName,
		prefsFontSize:     setup.prefsFontSize,
		previewTheme:      setup.previewTheme,
		startupErrors:     startupErrors,
	}

	ui.installWindowActions()

	textBuffer.ConnectChanged(func() {
		ui.onBufferChanged()
	})

	keyController := gtk.NewEventControllerKey()
	keyController.ConnectKeyPressed(func(keyval, _ uint, state gdk.ModifierType) bool {
		if !shouldHandleAutoIndent(keyval, state) {
			return false
		}
		return ui.handleAutoIndentNewline()
	})
	editor.AddController(keyController)

	ui.applyEditorPreferences()
	return ui
}

func (ui *UIState) startup() {
	if ui.started {
		ui.window.Present()
		return
	}
	ui.started = true

	var startupErrors []string
	if errMsg := ensureMermaidBundleExists(); errMsg != "" {
		startupErrors = append(startupErrors, errMsg)
	}

	if err := ui.loadRecentFiles(); err != nil {
		startupErrors = append(startupErrors, fmt.Sprintf("failed to load recent files: %s", err))
	}

	startupErrors = append(startupErrors, ui.startupErrors...)

	switch {
	case len(startupErrors) == 0:
		ui.clearStatus()
	default:
		ui.setError(strings.Join(startupErrors, " | "))
	}

	ui.scheduleRender()
	ui.scheduleHighlight()
	ui.updateTitle()
	ui.window.Present()
}

func (ui *UIState) handleOpenFiles(files []gio.Filer) {
	path := firstOpenablePath(files)
	if path == "" {
		return
	}

	ui.confirmDiscardThen(func() {
		ui.openDocument(path)
		ui.window.Present()
	})
}

func (ui *UIState) installWindowActions() {
	actions := map[string]func(){
		"new":         ui.handleNew,
		"open":        ui.handleOpen,
		"open-recent": ui.handleOpenRecent,
		"save":        ui.handleSave,
		"save-as":     ui.handleSaveAs,
		"export-png":  ui.handleExportPNG,
		"preferences": ui.handlePreferences,
	}

	for name, handler := range actions {
		action := gio.NewSimpleAction(name, nil)
		fn := handler
		action.ConnectActivate(func(_ *glib.Variant) { fn() })
		ui.window.AddAction(action)
	}

	ui.app.SetAccelsForAction("win.new", []string{"<Primary>n"})
	ui.app.SetAccelsForAction("win.open", []string{"<Primary>o"})
	ui.app.SetAccelsForAction("win.open-recent", []string{"<Primary><Shift>o"})
	ui.app.SetAccelsForAction("win.save", []string{"<Primary>s"})
	ui.app.SetAccelsForAction("win.save-as", []string{"<Primary><Shift>s"})
	ui.app.SetAccelsForAction("win.export-png", []string{"<Primary><Shift>e"})
	ui.app.SetAccelsForAction("win.preferences", []string{"<Primary>comma"})
}

func (ui *UIState) onBufferChanged() {
	if ui.suppressDirty {
		return
	}

	ui.core.SetDirty(true)
	ui.updateTitle()
	ui.scheduleRender()
	ui.scheduleHighlight()
}

func (ui *UIState) handleNew() {
	ui.confirmDiscardThen(func() {
		ui.core.NewDocument()
		ui.setEditorContent(core.DefaultDocumentContent())
		ui.clearStatus()
		ui.updateTitle()
		ui.scheduleRender()
	})
}

func (ui *UIState) handleOpen() {
	ui.confirmDiscardThen(func() {
		ui.showOpenDialog()
	})
}

func (ui *UIState) handleOpenRecent() {
	ui.confirmDiscardThen(func() {
		recentFiles := ui.core.RecentFiles()
		if len(recentFiles) == 0 {
			ui.setError("no recent files available")
			return
		}
		ui.showRecentDialog(recentFiles)
	})
}

func (ui *UIState) handleSave() {
	content := ui.bufferText()
	if ui.core.CurrentFile() != "" {
		_, err := ui.core.Save(content)
		if err != nil {
			ui.setError(fmt.Sprintf("save failed: %s", err))
			return
		}
		ui.clearStatus()
		ui.updateTitle()
		if err := ui.persistRecentFiles(); err != nil {
			ui.setError(fmt.Sprintf("failed to persist recent files: %s", err))
		}
		return
	}

	ui.showSaveDialog(ui.core.SuggestedDocumentName(), content)
}

func (ui *UIState) handleSaveAs() {
	content := ui.bufferText()
	ui.showSaveDialog(ui.core.SuggestedDocumentName(), content)
}

func (ui *UIState) handleExportPNG() {
	suggested := ui.core.SuggestedExportName()
	ui.showExportDialog(suggested)
}

func (ui *UIState) openDocument(path string) {
	content, err := ui.core.OpenFile(path)
	if err != nil {
		ui.setError(fmt.Sprintf("open failed: %s", err))
		return
	}
	ui.setEditorContent(content)
	ui.clearStatus()
	ui.updateTitle()
	ui.scheduleRender()
	if err := ui.persistRecentFiles(); err != nil {
		ui.setError(fmt.Sprintf("failed to persist recent files: %s", err))
	}
}

// confirmDiscardThen shows a discard-changes dialog if dirty, then calls proceed.
// If not dirty, proceed is called immediately.
func (ui *UIState) confirmDiscardThen(proceed func()) {
	if !ui.core.IsDirty() {
		proceed()
		return
	}

	alert := gtk.NewAlertDialog("Discard unsaved changes?")
	alert.SetDetail("Your current changes will be lost.")
	alert.SetButtons([]string{"Cancel", "Discard"})
	alert.SetCancelButton(0)
	alert.SetDefaultButton(1)

	alert.Choose(&ui.window.Window, nil, func(result gio.AsyncResulter) {
		choice, err := alert.ChooseFinish(result)
		if err != nil {
			return
		}
		if choice == 1 {
			proceed()
		}
	})
}

func (ui *UIState) showOpenDialog() {
	dialog := gtk.NewFileDialog()
	dialog.SetTitle("Open Mermaid Diagram")

	filter := gtk.NewFileFilter()
	filter.SetName("Mermaid (*.mmd, *.mermaid)")
	filter.AddPattern("*.mmd")
	filter.AddPattern("*.mermaid")
	dialog.SetDefaultFilter(filter)

	dialog.Open(&ui.window.Window, nil, func(result gio.AsyncResulter) {
		file, err := dialog.OpenFinish(result)
		if err != nil {
			return
		}
		path := file.Path()
		if path != "" {
			ui.openDocument(path)
		}
	})
}

func (ui *UIState) showRecentDialog(recentFiles []string) {
	recentWin := gtk.NewWindow()
	recentWin.SetTitle("Open Recent")
	recentWin.SetTransientFor(&ui.window.Window)
	recentWin.SetModal(true)
	recentWin.SetDefaultSize(500, -1)

	vbox := gtk.NewBox(gtk.OrientationVertical, 12)
	vbox.SetMarginTop(16)
	vbox.SetMarginBottom(16)
	vbox.SetMarginStart(16)
	vbox.SetMarginEnd(16)

	prompt := gtk.NewLabel("Choose a recent Mermaid diagram")
	prompt.SetXAlign(0.0)
	vbox.Append(prompt)

	combo := gtk.NewComboBoxText()
	combo.SetHExpand(true)
	for _, path := range recentFiles {
		combo.AppendText(path)
	}
	combo.SetActive(0)
	vbox.Append(combo)

	buttonBox := gtk.NewBox(gtk.OrientationHorizontal, 8)
	buttonBox.SetHAlign(gtk.AlignEnd)

	cancelBtn := gtk.NewButtonWithLabel("Cancel")
	cancelBtn.ConnectClicked(func() { recentWin.Close() })
	buttonBox.Append(cancelBtn)

	openBtn := gtk.NewButtonWithLabel("Open")
	openBtn.AddCSSClass("suggested-action")
	openBtn.ConnectClicked(func() {
		active := combo.Active()
		if active >= 0 && active < len(recentFiles) {
			recentWin.Close()
			ui.openDocument(recentFiles[active])
		}
	})
	buttonBox.Append(openBtn)

	vbox.Append(buttonBox)
	recentWin.SetChild(vbox)
	recentWin.Present()
}

func (ui *UIState) showSaveDialog(suggested, content string) {
	dialog := gtk.NewFileDialog()
	dialog.SetTitle("Save Mermaid Diagram")
	dialog.SetInitialName(suggested)

	filter := gtk.NewFileFilter()
	filter.SetName("Mermaid (*.mmd)")
	filter.AddPattern("*.mmd")
	dialog.SetDefaultFilter(filter)

	dialog.Save(&ui.window.Window, nil, func(result gio.AsyncResulter) {
		file, err := dialog.SaveFinish(result)
		if err != nil {
			return
		}
		path := file.Path()
		if path == "" {
			return
		}

		finalPath := core.EnsureDocumentExtension(path)
		_, err = ui.core.SaveAs(finalPath, content)
		if err != nil {
			ui.setError(fmt.Sprintf("save as failed: %s", err))
			return
		}
		ui.clearStatus()
		ui.updateTitle()
		if err := ui.persistRecentFiles(); err != nil {
			ui.setError(fmt.Sprintf("failed to persist recent files: %s", err))
		}
	})
}

func (ui *UIState) showExportDialog(suggested string) {
	dialog := gtk.NewFileDialog()
	dialog.SetTitle("Export PNG")
	dialog.SetInitialName(suggested)

	filter := gtk.NewFileFilter()
	filter.SetName("PNG image (*.png)")
	filter.AddPattern("*.png")
	dialog.SetDefaultFilter(filter)

	dialog.Save(&ui.window.Window, nil, func(result gio.AsyncResulter) {
		file, err := dialog.SaveFinish(result)
		if err != nil {
			return
		}
		path := file.Path()
		if path == "" {
			return
		}

		finalPath := core.EnsureExportExtension(path)
		ui.preview.Snapshot(
			webkit.SnapshotRegionVisible,
			webkit.SnapshotOptionsNone,
			nil,
			func(snapResult gio.AsyncResulter) {
				texture, err := ui.preview.SnapshotFinish(snapResult)
				if err != nil {
					ui.setError(fmt.Sprintf("export failed: %s", err))
					return
				}
				if err := texture.SaveToPng(finalPath); err != nil {
					ui.setError(fmt.Sprintf("export failed: %s", err))
					return
				}
				ui.clearStatus()
			},
		)
	})
}

func (ui *UIState) setEditorContent(text string) {
	ui.suppressDirty = true
	ui.buffer.SetText(text)
	ui.suppressDirty = false
	ui.scheduleHighlight()
}

func (ui *UIState) bufferText() string {
	start := ui.buffer.StartIter()
	end := ui.buffer.EndIter()
	return ui.buffer.Text(start, end, false)
}

func (ui *UIState) handleAutoIndentNewline() bool {
	ui.buffer.DeleteSelection(true, true)

	insertMark := ui.buffer.Mark("insert")
	if insertMark == nil {
		return false
	}

	insertIter := ui.buffer.IterAtMark(insertMark)
	lineStart := ui.buffer.IterAtLine(insertIter.Line())
	if lineStart == nil {
		return false
	}

	prefix := ui.buffer.Text(lineStart, insertIter, false)
	insertText := syntax.AutoIndentInsertion(prefix)

	insertIter = ui.buffer.IterAtMark(insertMark)
	ui.buffer.Insert(insertIter, insertText)
	return true
}

func (ui *UIState) handlePreferences() {
	currentThemeID := ui.prefsThemeID
	currentFontName := ui.prefsFontName
	currentFontSize := ui.prefsFontSize

	prefsWin := gtk.NewWindow()
	prefsWin.SetTitle("Preferences")
	prefsWin.SetTransientFor(&ui.window.Window)
	prefsWin.SetModal(true)

	grid := gtk.NewGrid()
	grid.SetColumnSpacing(12)
	grid.SetRowSpacing(12)
	grid.SetMarginTop(16)
	grid.SetMarginBottom(16)
	grid.SetMarginStart(16)
	grid.SetMarginEnd(16)

	fontLabel := gtk.NewLabel("Editor Font")
	fontLabel.SetXAlign(0.0)
	fontCombo := gtk.NewComboBoxText()
	fontCombo.SetHExpand(true)
	for _, opt := range ui.availableFonts {
		fontCombo.Append(opt.Family, opt.Label)
	}
	fontCombo.SetActiveID(currentFontName)

	sizeLabel := gtk.NewLabel("Font Size")
	sizeLabel.SetXAlign(0.0)
	sizeAdj := gtk.NewAdjustment(currentFontSize, preferences.MinFontSize, preferences.MaxFontSize, 1.0, 2.0, 0.0)
	sizeSpin := gtk.NewSpinButton(sizeAdj, 1.0, 0)
	sizeSpin.SetHExpand(true)

	themeLabel := gtk.NewLabel("Default Theme")
	themeLabel.SetXAlign(0.0)
	themeCombo := gtk.NewComboBoxText()
	themeCombo.SetHExpand(true)
	for _, t := range ui.availableThemes {
		themeCombo.Append(t.ID, t.Label)
	}
	themeCombo.SetActiveID(currentThemeID)

	grid.Attach(fontLabel, 0, 0, 1, 1)
	grid.Attach(fontCombo, 1, 0, 1, 1)
	grid.Attach(sizeLabel, 0, 1, 1, 1)
	grid.Attach(sizeSpin, 1, 1, 1, 1)
	grid.Attach(themeLabel, 0, 2, 1, 1)
	grid.Attach(themeCombo, 1, 2, 1, 1)

	buttonBox := gtk.NewBox(gtk.OrientationHorizontal, 8)
	buttonBox.SetHAlign(gtk.AlignEnd)
	buttonBox.SetMarginTop(12)

	cancelBtn := gtk.NewButtonWithLabel("Cancel")
	cancelBtn.ConnectClicked(func() { prefsWin.Close() })
	buttonBox.Append(cancelBtn)

	saveBtn := gtk.NewButtonWithLabel("Save")
	saveBtn.AddCSSClass("suggested-action")
	saveBtn.ConnectClicked(func() {
		nextThemeID := themeCombo.ActiveID()
		if nextThemeID == "" {
			nextThemeID = currentThemeID
		}
		nextFontName := fontCombo.ActiveID()
		if nextFontName == "" {
			nextFontName = currentFontName
		}
		nextFontSize := sizeSpin.Value()

		prefsWin.Close()
		ui.applyPreferencesUpdate(nextThemeID, nextFontName, nextFontSize)
	})
	buttonBox.Append(saveBtn)

	grid.Attach(buttonBox, 0, 3, 2, 1)

	prefsWin.SetChild(grid)
	prefsWin.Present()
}

func (ui *UIState) applyPreferencesUpdate(nextThemeID, nextFontName string, nextFontSize float64) {
	normalizedThemeID := theme.NormalizeThemeID(nextThemeID)
	resolvedFontName := resolveEditorFontName(ui.availableFonts, nextFontName)
	resolvedFontSize := preferences.ClampFontSize(nextFontSize)

	themeChanged := ui.prefsThemeID != normalizedThemeID

	if themeChanged {
		pt := previewThemeForID(ui.availableThemes, normalizedThemeID)
		if pt == nil {
			ui.setError(fmt.Sprintf("theme '%s' is unavailable in the shared catalog", normalizedThemeID))
			return
		}
		ui.previewTheme = pt
	}

	ui.prefsThemeID = normalizedThemeID
	ui.prefsFontName = resolvedFontName
	ui.prefsFontSize = resolvedFontSize
	ui.applyEditorPreferences()

	if themeChanged {
		ui.scheduleRender()
	}

	p := &preferences.Preferences{
		DefaultThemeID: normalizedThemeID,
		EditorFontName: resolvedFontName,
		EditorFontSize: resolvedFontSize,
	}
	prefsPath, err := preferences.DefaultPath()
	if err != nil {
		ui.setError(fmt.Sprintf("failed to save preferences: %s", err))
		return
	}
	if err := p.Save(prefsPath); err != nil {
		ui.setError(fmt.Sprintf("failed to save preferences: %s", err))
		return
	}
	ui.clearStatus()
}

func (ui *UIState) applyEditorPreferences() {
	css := buildEditorCSS(ui.prefsFontName, ui.prefsFontSize)
	ui.editorCSSProvider.LoadFromString(css)
	ui.editor.QueueDraw()
}

func (ui *UIState) scheduleRender() {
	cancelTimer(&ui.renderTimer)

	source := ui.bufferText()
	pt := ui.previewTheme
	preview := ui.preview
	baseURI := ui.previewBaseURI

	ui.renderTimer = glib.TimeoutAdd(renderDebounceMs, func() {
		html := diagramHTML(source, pt)
		preview.LoadHTML(html, baseURI)
	})
}

func (ui *UIState) scheduleHighlight() {
	cancelTimer(&ui.highlightTimer)

	buffer := ui.buffer
	ui.highlightTimer = glib.TimeoutAdd(highlightDebounceMs, func() {
		applyMermaidHighlighting(buffer)
	})
}

func (ui *UIState) updateTitle() {
	name := ui.core.DisplayName()
	dirtySuffix := ""
	if ui.core.IsDirty() {
		dirtySuffix = " *"
	}
	ui.window.SetTitle(fmt.Sprintf("dia (GTK) - %s%s", name, dirtySuffix))
}

func (ui *UIState) setError(message string) {
	ui.status.SetText(message)
}

func (ui *UIState) clearStatus() {
	ui.status.SetText("")
}

func (ui *UIState) loadRecentFiles() error {
	path, err := recentFilesPath()
	if err != nil {
		return err
	}
	return ui.core.LoadRecentFiles(path)
}

func (ui *UIState) persistRecentFiles() error {
	path, err := recentFilesPath()
	if err != nil {
		return err
	}
	return ui.core.SaveRecentFiles(path)
}

// --- helpers ---

func recentFilesPath() (string, error) {
	configDir, err := os.UserConfigDir()
	if err != nil {
		return "", fmt.Errorf("could not resolve user config directory: %w", err)
	}
	return filepath.Join(configDir, "dia", "recent-files.json"), nil
}

func firstOpenablePath(files []gio.Filer) string {
	for _, f := range files {
		if path := f.Path(); path != "" {
			return path
		}
	}
	return ""
}

func buildPrimaryMenuModel() gio.MenuModeller {
	root := gio.NewMenu()

	openSection := gio.NewMenu()
	openSection.Append("New diagram", "win.new")
	openSection.Append("Open...", "win.open")
	openSection.Append("Open recent...", "win.open-recent")
	root.AppendSection("", openSection)

	saveSection := gio.NewMenu()
	saveSection.Append("Save", "win.save")
	saveSection.Append("Save as...", "win.save-as")
	saveSection.Append("Export PNG", "win.export-png")
	root.AppendSection("", saveSection)

	settingsSection := gio.NewMenu()
	settingsSection.Append("Preferences", "win.preferences")
	root.AppendSection("", settingsSection)

	return root
}

func installAppChromeCSS() {
	provider := gtk.NewCSSProvider()
	provider.LoadFromString(appChromeCSS)

	if display := gdk.DisplayGetDefault(); display != nil {
		gtk.StyleContextAddProviderForDisplay(display, provider, gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
	}
}

func buildEditorCSS(fontName string, fontSize float64) string {
	fontFamily := cssFontFamilyValue(fontName)
	clamped := preferences.ClampFontSize(fontSize)
	return fmt.Sprintf(`
textview#diagram-editor,
textview#diagram-editor text {
  font-family: %s;
  font-size: %gpt;
}
`, fontFamily, clamped)
}

func cssFontFamilyValue(value string) string {
	if strings.EqualFold(value, "monospace") {
		return "monospace"
	}
	escaped := strings.ReplaceAll(value, `\`, `\\`)
	escaped = strings.ReplaceAll(escaped, `"`, `\"`)
	return fmt.Sprintf(`"%s"`, escaped)
}

func shouldHandleAutoIndent(keyval uint, state gdk.ModifierType) bool {
	if keyval != gdk.KEY_Return && keyval != gdk.KEY_KP_Enter {
		return false
	}
	blocked := gdk.ControlMask | gdk.AltMask | gdk.SuperMask | gdk.MetaMask
	return state&blocked == 0
}

func installEditorTags(buffer *gtk.TextBuffer) {
	kwTag := gtk.NewTextTag(tagKeyword)
	kwTag.SetObjectProperty("foreground", "#0f766e")
	kwTag.SetObjectProperty("weight", pango.WeightBold)
	buffer.TagTable().Add(kwTag)

	opTag := gtk.NewTextTag(tagOperator)
	opTag.SetObjectProperty("foreground", "#b45309")
	opTag.SetObjectProperty("weight", pango.WeightBold)
	buffer.TagTable().Add(opTag)

	cmTag := gtk.NewTextTag(tagComment)
	cmTag.SetObjectProperty("foreground", "#64748b")
	cmTag.SetObjectProperty("style", pango.StyleItalic)
	buffer.TagTable().Add(cmTag)

	lbTag := gtk.NewTextTag(tagLabel)
	lbTag.SetObjectProperty("foreground", "#9333ea")
	buffer.TagTable().Add(lbTag)
}

func applyMermaidHighlighting(buffer *gtk.TextBuffer) {
	clearMermaidHighlighting(buffer)

	start := buffer.StartIter()
	end := buffer.EndIter()
	text := buffer.Text(start, end, false)

	for _, span := range syntax.HighlightSpans(text) {
		tagName := tagNameForKind(span.Kind)
		tag := buffer.TagTable().Lookup(tagName)
		if tag == nil {
			continue
		}

		startIter := buffer.IterAtOffset(span.Start)
		endIter := buffer.IterAtOffset(span.End)
		buffer.ApplyTag(tag, startIter, endIter)
	}
}

func clearMermaidHighlighting(buffer *gtk.TextBuffer) {
	start := buffer.StartIter()
	end := buffer.EndIter()

	for _, tagName := range []string{tagKeyword, tagOperator, tagComment, tagLabel} {
		tag := buffer.TagTable().Lookup(tagName)
		if tag != nil {
			buffer.RemoveTag(tag, start, end)
		}
	}
}

func tagNameForKind(kind syntax.HighlightKind) string {
	switch kind {
	case syntax.Keyword:
		return tagKeyword
	case syntax.Operator:
		return tagOperator
	case syntax.Comment:
		return tagComment
	case syntax.Label:
		return tagLabel
	default:
		return ""
	}
}

func cancelTimer(handle *glib.SourceHandle) {
	if *handle == 0 {
		return
	}
	glib.SourceRemove(*handle)
	*handle = 0
}

func mermaidVendorDirCandidates() []string {
	var candidates []string

	exe, err := os.Executable()
	if err == nil {
		exeDir := filepath.Dir(exe)
		candidates = append(candidates, filepath.Join(exeDir, "vendor-js"))
		prefixDir := filepath.Dir(exeDir)
		candidates = append(candidates, filepath.Join(prefixDir, "share", "dia", "vendor"))
	}

	if wd, err := os.Getwd(); err == nil {
		candidates = append(candidates, filepath.Join(wd, "vendor-js"))
	}

	return candidates
}

func mermaidVendorDir() (string, error) {
	candidates := mermaidVendorDirCandidates()
	for _, candidate := range candidates {
		bundlePath := filepath.Join(candidate, mermaidBundleName)
		if _, err := os.Stat(bundlePath); err == nil {
			return candidate, nil
		}
	}

	paths := strings.Join(candidates, ", ")
	return "", fmt.Errorf("missing Mermaid bundle '%s' in searched paths: %s", mermaidBundleName, paths)
}

func loadMermaidVendorBaseURI() (string, string) {
	vendorDir, err := mermaidVendorDir()
	if err != nil {
		candidates := mermaidVendorDirCandidates()
		if len(candidates) > 0 {
			vendorDir = candidates[0]
		}
	}

	var mermaidErr string
	if errMsg := ensureMermaidBundleExists(); errMsg != "" {
		mermaidErr = errMsg
	}

	uri := "file://" + vendorDir + "/"
	return uri, mermaidErr
}

func ensureMermaidBundleExists() string {
	_, err := mermaidVendorDir()
	if err != nil {
		return err.Error()
	}
	return ""
}

type appSetup struct {
	themes        []theme.ThemeInfo
	fonts         []EditorFontOption
	prefsThemeID  string
	prefsFontName string
	prefsFontSize float64
	previewTheme  *PreviewTheme
	startupErrors []string
}

func loadAppSetup(editor *gtk.TextView) *appSetup {
	themeID := theme.NormalizeThemeID(theme.DefaultThemeID)
	var startupErrors []string

	fonts := loadEditorFontOptions(editor)
	fallbackFontName := defaultEditorFontName(fonts)
	themes := theme.Themes()

	storedPrefs, err := loadStoredPreferences()
	if err != nil {
		startupErrors = append(startupErrors, err.Error())
	}

	preferredThemeID := themeID
	if storedPrefs != nil && strings.TrimSpace(storedPrefs.DefaultThemeID) != "" {
		preferredThemeID = storedPrefs.DefaultThemeID
	}
	normalizedThemeID := theme.NormalizeThemeID(preferredThemeID)

	themeKnown := false
	for _, t := range themes {
		if t.ID == normalizedThemeID {
			themeKnown = true
			break
		}
	}
	if !themeKnown {
		startupErrors = append(startupErrors, fmt.Sprintf("shared theme catalog is missing theme '%s'", normalizedThemeID))
		normalizedThemeID = themeID
	}

	editorFontName := fallbackFontName
	if storedPrefs != nil && strings.TrimSpace(storedPrefs.EditorFontName) != "" {
		resolved := resolveEditorFontName(fonts, storedPrefs.EditorFontName)
		switch {
		case resolved != fallbackFontName:
			editorFontName = resolved
		case strings.EqualFold(storedPrefs.EditorFontName, fallbackFontName):
			editorFontName = resolved
		default:
			startupErrors = append(startupErrors, fmt.Sprintf("saved editor font '%s' is unavailable; using '%s'", storedPrefs.EditorFontName, fallbackFontName))
		}
	}

	editorFontSize := preferences.DefaultFontSize
	if storedPrefs != nil && storedPrefs.EditorFontSize > 0 {
		editorFontSize = preferences.ClampFontSize(storedPrefs.EditorFontSize)
	}

	pt := previewThemeForID(themes, normalizedThemeID)
	if pt == nil {
		startupErrors = append(startupErrors, fmt.Sprintf("failed to build preview theme for '%s'", normalizedThemeID))
		pt = &PreviewTheme{
			ID:                normalizedThemeID,
			PreviewBackground: "#ffffff",
			ErrorColor:        "#b91c1c",
			MermaidConfigJS:   theme.MermaidConfigJS(normalizedThemeID),
		}
	}

	return &appSetup{
		themes:        themes,
		fonts:         fonts,
		prefsThemeID:  normalizedThemeID,
		prefsFontName: editorFontName,
		prefsFontSize: editorFontSize,
		previewTheme:  pt,
		startupErrors: startupErrors,
	}
}

func loadStoredPreferences() (*preferences.Preferences, error) {
	path, err := preferences.DefaultPath()
	if err != nil {
		return nil, err
	}
	return preferences.Load(path)
}

func loadEditorFontOptions(editor *gtk.TextView) []EditorFontOption {
	ctx := editor.PangoContext()
	families := ctx.ListFamilies()

	var monoFamilies []string
	for _, family := range families {
		if family.IsMonospace() {
			monoFamilies = append(monoFamilies, family.Name())
		}
	}

	slices.Sort(monoFamilies)
	monoFamilies = slices.Compact(monoFamilies)

	options := []EditorFontOption{{
		Family: "monospace",
		Label:  "System Monospace",
	}}

	for _, name := range monoFamilies {
		if strings.EqualFold(name, "monospace") {
			continue
		}
		options = append(options, EditorFontOption{Family: name, Label: name})
	}

	return options
}

func defaultEditorFontName(options []EditorFontOption) string {
	if len(options) > 0 {
		return options[0].Family
	}
	return "Monospace"
}

func resolveEditorFontName(options []EditorFontOption, fontName string) string {
	trimmed := strings.TrimSpace(fontName)
	for _, opt := range options {
		if strings.EqualFold(opt.Family, trimmed) {
			return opt.Family
		}
	}
	return defaultEditorFontName(options)
}

func previewThemeForID(themes []theme.ThemeInfo, themeID string) *PreviewTheme {
	for _, t := range themes {
		if t.ID == themeID {
			return &PreviewTheme{
				ID:                t.ID,
				PreviewBackground: t.PreviewBackground,
				ErrorColor:        t.ErrorColor,
				MermaidConfigJS:   theme.MermaidConfigJS(themeID),
			}
		}
	}
	return nil
}

